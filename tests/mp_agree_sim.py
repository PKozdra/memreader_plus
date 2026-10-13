"""Offline sim of Plus's agree.lua: N machines on one command stream, with the real agree.lua and sites.lua (lupa).

Run: python mp_agree_sim.py [--seeds 1000] [--build 9.0.3.0]
Each machine has its own Lua state with the game's poisoned string functions. A message sent at tick t reaches every
machine, the sender too, in one global order. Game-time timers stop while a machine loads unless a scenario says
otherwise. The sim prints one line per needle at the end.
"""

import argparse
import importlib
import random
import sys
import time
import types
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SCRIPTS = ROOT / "script" / "memreader_plus"
SHARED = ROOT.parent / "_shared" / "site_installer"
MOCK = (HERE / "mp_agree_mock.lua").read_text(encoding="utf-8")
LOADER_WORLD = (HERE / "mp_agree_loader_world.lua").read_text(encoding="utf-8")
AGREE = (SCRIPTS / "agree.lua").read_bytes()
MOD_FOLDERS = [ROOT / "script" / part / "mod" for part in ("_lib", "campaign", "frontend", "battle")]
LOADER = (SCRIPTS / "loader.lua").read_bytes()
SITES = SCRIPTS / "sites.lua"


def load_shared():
    sys.path.insert(0, str(SHARED))
    names = ("fake_patcher", "fake_plus", "lint_sites", "site_installer_sim")
    return types.SimpleNamespace(**{name: importlib.import_module(name) for name in names})


S = load_shared()
FIXTURE = (S.site_installer_sim.FIXTURES / "army_size_sites.lua").read_bytes()
LINK_FIXTURE = (S.site_installer_sim.FIXTURES / "link_sites.lua").read_bytes()
SPLIT = "function(src) local chunk = assert(loadstring(src, '@mock')) setfenv(chunk, GAME) chunk() end"
LIMIT = 255
ROUND_TICKS = 220
BIG_TICKS = 1500
PACKET_ROOM = 16377
COMMAND_OVERHEAD = 7
BACKGROUND_BYTES = 1000
HALF_PACKET = PACKET_ROOM // 2 + BACKGROUND_BYTES
BUDGET = "tick budget: no tick carries more than half of the packet, whatever the traffic"
IMAGES = {}

MOD = {
    "owner": "mod_alpha",
    "features": {"caps": "same", "armies": "same", "heroes": "same", "panel": "local", "bits": "load"},
    "options": {"player_cap": 30, "ai_cap": 30, "overrides": "", "ratio": 1.5, "follow": False},
    "format": 3,
    "title": "Alpha Mod",
}
SECOND = {
    "owner": "mod_beta",
    "features": {"ticks": "same", "regen": "same"},
    "options": {"scale": 2.0},
    "format": 1,
    "title": "Beta Mod",
}
LINKS_MOD = {
    "owner": "mod_links",
    "features": {"count_links": "same"},
    "options": {},
    "format": 1,
    "title": "Links Mod",
    "fixture": LINK_FIXTURE,
    "prepare": ["count_links"],
}
LOCALISED = {
    "factions_screen_name_fac_a": "Reikland",
    "factions_screen_name_fac_b": "Eataine",
    "factions_screen_name_fac_c": "Karaz-a-Karak",
    "forename_a": "Karl",
    "surname_a": "Franz",
}
LEADERS = {"fac_a": ["forename_a", "surname_a"]}

failures = []
passed = {}


def expect(needle, condition, message):
    passed.setdefault(needle, True)
    if not condition:
        passed[needle] = False
        failures.append(f"{needle}: {message}")
        print(f"  FAIL {needle}: {message}")
    return bool(condition)


def to_lua(lua, value):
    if isinstance(value, str):
        return value.encode()
    if isinstance(value, dict):
        return lua.table_from(
            {(key.encode() if isinstance(key, str) else key): to_lua(lua, item) for key, item in value.items()}
        )
    if isinstance(value, list | tuple):
        return lua.table_from({index: to_lua(lua, item) for index, item in enumerate(value, 1)})
    return value


def plain(value):
    if isinstance(value, bytes):
        return value.decode()
    if hasattr(value, "keys"):
        return {plain(key): plain(item) for key, item in value.items()}
    return value


def image(build):
    if build not in IMAGES:
        IMAGES[build] = S.fake_plus.Image(build)
    return IMAGES[build]


@dataclass
class Setup:
    delay: int = 0
    agree_delay: int = 0
    mode: str = "campaign"
    host: bool = False
    synced: bool = True
    has_mct: bool = True
    values: dict = field(default_factory=dict)
    mods: list | None = None
    plus: bool = True
    states: dict = field(default_factory=dict)
    fail: list = field(default_factory=list)
    silent: bool = False
    mp: bool = True
    hide: str | None = None
    entries: tuple | None = None
    install: bool = False
    before: object = None
    split: bool = False
    global_cm: bool = False
    comma: bool = False


class Real:
    def __init__(self, lua, build, internals, hide):
        self.lua = lua
        self.mr = S.fake_plus.FakeMr(image(build), lua)
        self.patcher = S.fake_patcher.FakePatcher(self.mr)
        self.mr.attach_patcher(self.patcher)
        self.plus = self.mr.table()
        self.module = S.lint_sites.load_module(lua, SITES, "sites", self.plus, internals)
        self.module[b"attach"]()
        self.open = lua.eval("function(plus, owner, entries, log) return plus.patcher(owner):sites(entries, log) end")
        self.logs = []
        if hide:
            self.mr.hidden.add(hide)

    def sites(self, owner, source):
        entries = self.lua.eval(S.lint_sites.DATA_LOADER)(source, b"entries")
        return self.open(self.plus, owner.encode(), entries, self.logs.append)


def pattern_of(name):
    entries = S.site_installer_sim.World(image("9.0.3.0")).python_entries("army_size_sites")
    return entries[name]["pattern"]


class Machine:
    def __init__(self, cluster, index, setup):
        self.cluster = cluster
        self.index = index
        self.setup = setup
        self.name = f"fac_{chr(97 + index)}"
        self.cqi = index + 1
        self.delay = setup.delay
        self.loaded = False
        self.started = False
        self.mods = [MOD] if setup.mods is None else setup.mods
        self.outbox = []
        self.cursor = 0
        self.apply_ticks = []
        self.peak = 0
        self.lua = S.lint_sites.new_runtime(True)
        if setup.split:
            self.lua.execute("GAME = setmetatable({}, { __index = _G })")
            self.lua.eval(SPLIT)(MOCK.encode())
            self.H = self.lua.eval("GAME.H")
        else:
            self.lua.execute(MOCK)
            self.H = self.lua.globals()[b"H"]
        self.configure(setup.values)
        if setup.comma:
            self.lua.execute("H.comma_numbers()")
        if setup.global_cm:
            self.lua.execute("cm = GAME.cm")
        self.internals = self.H[b"load_agree"](AGREE)
        self.real = None
        if cluster.real:
            hide = pattern_of("player_cap") if setup.hide == "caps" else None
            self.real = Real(self.lua, cluster.build, self.internals, hide)

    def configure(self, values):
        config = {
            "mp": self.setup.mp,
            "mode": self.setup.mode,
            "me": self.name,
            "cqi": self.cqi,
            "humans": self.cluster.humans,
            "names": self.cluster.names,
            "host": self.setup.host,
            "synced": self.setup.synced,
            "values": values,
            "has_mct": self.setup.has_mct,
            "leaders": LEADERS,
            "localised": LOCALISED,
        }
        self.H[b"configure"](to_lua(self.lua, config))

    def set_values(self, values):
        self.H[b"mct_values"] = to_lua(self.lua, values)

    def set_synced(self, value):
        self.H[b"synced"] = value

    def load(self):
        self.loaded = True
        self.H[b"listen_at_load"]()

    def begin(self):
        self.started = True
        for mod in self.mods:
            self.start_mod(mod)

    def start_mod(self, mod):
        spec = {key: mod[key] for key in ("features", "options", "format", "title")}
        spec["sites"] = False if not self.setup.plus else ("real" if self.real else "fake")
        if self.real:
            source = mod.get("fixture", FIXTURE)
            if self.setup.entries and "fixture" not in mod:
                source = source.replace(*(part.encode() for part in self.setup.entries))
            owner = mod["owner"]
            sites = self.real.sites(owner, source)
            if self.setup.before:
                sites = self.setup.before(self, lambda: self.real.sites(owner, source), sites) or sites
            self.H[b"real_sites"][owner.encode()] = sites
            if mod.get("early"):
                self.H[b"attach_early"](owner.encode(), to_lua(self.lua, mod["early"]))
            if self.setup.install and "fixture" not in mod:
                self.H[b"install_on_apply"](mod["owner"].encode(), to_lua(self.lua, ["caps", "armies", "heroes"]))
        self.H[b"fail"][mod["owner"].encode()] = to_lua(self.lua, self.setup.fail)
        states = self.setup.states.get(mod["owner"], {})
        prepare = to_lua(self.lua, mod["prepare"]) if "prepare" in mod else None
        return self.H[b"start"](mod["owner"].encode(), to_lua(self.lua, spec), to_lua(self.lua, states), prepare)

    def deliver(self, seq, cqi, text):
        self.H[b"deliver"](cqi, text, seq)
        self.collect()

    def collect(self):
        taken = self.H[b"take_out"]()
        for _, item in sorted(taken.items()):
            self.outbox.append((item[1], item[2]))

    def step(self, tick, game_time):
        if not self.loaded and tick >= self.delay:
            self.load()
        if not self.loaded:
            return
        if not self.started and tick >= self.delay + self.setup.agree_delay:
            self.begin()
            self.collect()
        for seq, cqi, text in self.cluster.pending(self, tick):
            self.deliver(seq, cqi, text)
        if game_time:
            self.H[b"advance"](1)
        self.H[b"advance_real"](1000)
        self.collect()
        counts = sum(len(self.records(mod["owner"])) for mod in self.mods)
        if counts > len(self.apply_ticks):
            self.apply_ticks.extend([tick] * (counts - len(self.apply_ticks)))

    def records(self, owner):
        found = []
        for _, item in sorted(self.H[b"applies"].items()):
            record = plain(item)
            if record["owner"] == owner:
                found.append(record)
        return found

    def log(self, owner=MOD["owner"], positions=True):
        return [
            (
                r["seq"] if positions else 0,
                frozenset(r["values"].items()),
                frozenset(r["on"]) - LOCAL,
                frozenset(r["why"].items()),
                r["order"],
            )
            for r in self.records(owner)
        ]

    def trace(self, owner):
        return [line for line in self.logs() if "message " in line and f": {owner} " in line]

    def logs(self):
        return [line.decode() for _, line in sorted(self.H[b"logs"].items())]

    def popups(self):
        return [text.decode() for _, text in sorted(self.H[b"popups"].items())]

    def listening(self, event):
        return self.H[b"listening"](event.encode())

    def last(self, owner=MOD["owner"]):
        records = self.records(owner)
        return records[-1] if records else None

    def call(self, source, *args):
        return self.lua.eval(source)(*args)


class Cluster:
    def __init__(
        self,
        setups,
        *,
        latency=1,
        lockstep=True,
        seed=0,
        shuffle_inside=False,
        drop=0.0,
        real=False,
        build="9.0.3.0",
    ):
        self.latency = latency
        self.lockstep = lockstep
        self.rng = random.Random(seed)
        self.shuffle_inside = shuffle_inside
        self.drop = drop
        self.real = real
        self.build = build
        self.tick = 0
        self.worst = 0
        self.frozen = False
        self.stream = []
        self.events = {}
        self.humans = [f"fac_{chr(97 + index)}" for index in range(len(setups))]
        self.names = {index + 1: name for index, name in enumerate(self.humans)}
        self.machines = [Machine(self, index, setup) for index, setup in enumerate(setups)]

    def at(self, tick, action):
        self.events.setdefault(tick, []).append(action)

    def pending(self, machine, tick):
        found = []
        if self.frozen:
            return found
        while machine.cursor < len(self.stream) and self.stream[machine.cursor][3] <= tick:
            found.append(self.stream[machine.cursor][:3])
            machine.cursor += 1
        if self.shuffle_inside:
            found = self.interleave(found)
        return found

    def interleave(self, found):
        queues = {}
        for item in found:
            queues.setdefault(item[1], []).append(item)
        result = []
        while queues:
            key = self.rng.choice(sorted(queues))
            result.append(queues[key].pop(0))
            if not queues[key]:
                del queues[key]
        return result

    def append(self, cqi, text):
        if self.rng.random() < self.drop:
            return
        due = max(self.stream[-1][3] if self.stream else 0, self.tick + self.latency)
        self.stream.append((len(self.stream) + 1, cqi, text, due))

    def step(self):
        self.tick += 1
        for action in self.events.pop(self.tick, []):
            action()
        loaded = all(m.delay <= self.tick for m in self.machines)
        for machine in self.machines:
            machine.step(self.tick, loaded if self.lockstep else True)
        order = list(self.machines)
        self.rng.shuffle(order)
        tick_bytes = BACKGROUND_BYTES
        for machine in order:
            sent, machine.outbox = machine.outbox, []
            machine.peak = max(machine.peak, len(sent))
            if not machine.setup.silent:
                for cqi, text in sent:
                    self.append(cqi, text)
                    tick_bytes += len(text) + COMMAND_OVERHEAD
        self.worst = max(self.worst, tick_bytes)

    def run(self, ticks):
        for _ in range(ticks):
            self.step()

    def inject(self, cqi, text):
        self.append(cqi, text if isinstance(text, bytes) else text.encode())

    def participants(self, owner=MOD["owner"]):
        return [m for m in self.machines if any(mod["owner"] == owner for mod in m.mods)]


def machines_of(count, **common):
    return [Setup(**common) for _ in range(count)]


def settle(cluster, needle=None, ticks=ROUND_TICKS, owner=MOD["owner"], compare=True):
    cluster.run(ticks)
    positions = all(m.setup.agree_delay == 0 for m in cluster.machines)
    logs = [m.log(owner, positions) for m in cluster.participants(owner)]
    same = all(log == logs[0] for log in logs)
    traces = [m.trace(owner) for m in cluster.participants(owner)]
    if compare:
        expect("same apply everywhere", all(trace == traces[0] for trace in traces), "message traces differ")
        expect(BUDGET, cluster.worst <= HALF_PACKET, f"a tick carried {cluster.worst} bytes")
    if compare:
        expect("same apply everywhere", same, f"{owner} apply logs differ: {[len(log) for log in logs]}")
    if needle:
        expect(needle, same, "apply logs differ")
    return cluster


def shared(record):
    return set(record["on"]) - LOCAL


def on_of(machine, owner=MOD["owner"]):
    record = machine.last(owner)
    return shared(record) if record else None


def why_of(machine, owner=MOD["owner"]):
    record = machine.last(owner)
    return record["why"] if record else None


def values_of(machine, owner=MOD["owner"]):
    record = machine.last(owner)
    return record["values"] if record else None


def final_state(machine, owner=MOD["owner"]):
    record = machine.last(owner)
    return (
        None
        if record is None
        else (frozenset(record["values"].items()), frozenset(record["on"]) - LOCAL, frozenset(record["why"].items()))
    )


HEADLINE_ALL = "the mod is off for everyone in this campaign."
HEADLINE_PART = "part of the mod is off for everyone in this campaign."
ALL_SAME = {"caps", "armies", "heroes", "bits"}
LOCAL = frozenset({"panel"})


def scenario_comma_locale():
    needle = "comma decimal mark: fractions agreed"
    cases = {
        "host": [Setup(values={"ratio": 1.75}, host=True, comma=True), Setup(), Setup()],
        "client": [Setup(values={"ratio": 1.75}, host=True), Setup(comma=True), Setup()],
        "all": [Setup(values={"ratio": 0.25}, host=True, comma=True), Setup(comma=True), Setup(comma=True)],
    }
    for name, setups in cases.items():
        cluster = settle(Cluster(setups))
        want = setups[0].values["ratio"]
        for machine in cluster.machines:
            got = (values_of(machine) or {}).get("ratio")
            expect(needle, got == want, f"{name}: {machine.name} agreed {got}, wanted {want}")
            expect(needle, on_of(machine) == ALL_SAME, f"{name}: {machine.name} on {on_of(machine)}")


def scenario_values():
    cluster = Cluster(
        [Setup(values={"player_cap": 10}), Setup(values={"player_cap": 77}, host=True), Setup(values={"player_cap": 5})]
    )
    settle(cluster)
    needle = "host values win"
    for machine in cluster.machines:
        expect(needle, values_of(machine)["player_cap"] == 77, f"{machine.name}: {values_of(machine)}")
        expect(needle, on_of(machine) == ALL_SAME, f"on {on_of(machine)}")

    cluster = settle(
        Cluster([Setup(values={"player_cap": 10}), Setup(values={"player_cap": 77}), Setup(values={"player_cap": 5})])
    )
    needle = "no host: first human"
    expect(needle, all(values_of(m)["player_cap"] == 10 for m in cluster.machines), "not the first human's values")

    cluster = settle(
        Cluster(
            [
                Setup(values={"player_cap": 10}),
                Setup(values={"player_cap": 77}, host=True),
                Setup(values={"player_cap": 5}, host=True),
            ]
        )
    )
    needle = "two host claims: first in order"
    expect(needle, all(values_of(m)["player_cap"] == 77 for m in cluster.machines), "not the first claimant's values")


FLAGS_MOD = {
    "owner": "mod_flags",
    "features": {"caps": "same"},
    "options": {"enabled": True, "count": 5, "label": "x"},
    "format": 1,
    "title": "Flags Mod",
}


def scenario_false_values():
    needle = "false, zero and empty options reach every machine"
    host_values = {"enabled": False, "count": 0, "label": ""}
    cluster = Cluster(
        [
            Setup(mods=[FLAGS_MOD], host=True, values=host_values),
            Setup(mods=[FLAGS_MOD], values={"enabled": True, "count": 9, "label": "y"}),
        ]
    )
    settle(cluster, owner="mod_flags")
    for machine in cluster.machines:
        found = values_of(machine, "mod_flags")
        expect(needle, found["enabled"] is False and found["count"] == 0 and found["label"] == "", f"{found}")

    machine = Cluster([Setup(mp=False, mods=[FLAGS_MOD], values=host_values)]).machines[0]
    machine.load()
    machine.begin()
    found = values_of(machine, "mod_flags")
    expect(needle, found["enabled"] is False and found["count"] == 0 and found["label"] == "", f"single player {found}")


def scenario_no_early_apply():
    needle = "no apply before all reports"
    cluster = Cluster([Setup(), Setup(), Setup(delay=30)])
    cluster.run(28)
    expect(
        needle,
        all(not m.records(MOD["owner"]) for m in cluster.machines if m.started),
        "applied before the third report",
    )
    settle(cluster)
    expect(needle, all(len(m.records(MOD["owner"])) == 1 for m in cluster.machines), "not exactly one apply")
    expect(
        needle, all(m.apply_ticks[0] >= 30 for m in cluster.machines), f"{[m.apply_ticks for m in cluster.machines]}"
    )


def scenario_synced():
    needle = "synced: host waits for s"
    cluster = Cluster([Setup(synced=False, values={"player_cap": 11}), Setup(values={"player_cap": 44})])
    cluster.at(20, lambda: cluster.machines[0].set_synced(True))
    cluster.at(20, lambda: cluster.machines[0].set_values({"player_cap": 99}))
    cluster.run(15)
    expect(needle, all(not m.records(MOD["owner"]) for m in cluster.machines), "applied before the sender was synced")
    settle(cluster)
    expect(
        needle,
        all(values_of(m)["player_cap"] == 99 for m in cluster.machines),
        f"{[values_of(m) for m in cluster.machines]}",
    )
    expect(
        needle, all(m.apply_ticks[0] >= 20 for m in cluster.machines), f"{[m.apply_ticks for m in cluster.machines]}"
    )

    needle = "stale host claim: synced values used"
    cluster = Cluster([Setup(values={"player_cap": 44}), Setup(host=True, synced=False, values={"player_cap": 11})])
    cluster.at(25, lambda: cluster.machines[1].set_synced(True))
    cluster.at(25, lambda: cluster.machines[1].set_values({"player_cap": 99}))
    settle(cluster)
    seen = {r["values"]["player_cap"] for m in cluster.machines for r in m.records(MOD["owner"])}
    expect(needle, seen == {99}, f"values used {seen}")

    needle = "mct missing on host, client first: off m"
    cluster = Cluster([Setup(synced=False), Setup(has_mct=False)])
    settle(cluster)
    for machine in cluster.machines:
        expect(needle, on_of(machine) == set(), f"{machine.name} on {on_of(machine)}")
        expect(needle, why_of(machine)["caps"] == "m", f"why {why_of(machine)}")
        expect(needle, machine.apply_ticks[0] >= 60, f"decided at {machine.apply_ticks}")
        expect(needle, "The host's mod settings did not arrive." in machine.popups()[0], machine.popups())


def scenario_plus_blocked():
    needle = "plus blocked: off at once"
    cluster = Cluster([Setup(), Setup(plus=False)])
    cluster.run(4)
    for machine in cluster.machines:
        expect(needle, machine.apply_ticks and machine.apply_ticks[0] <= 4, f"{machine.name} {machine.apply_ticks}")
        expect(needle, on_of(machine) == set(), f"{machine.name} on {on_of(machine)}")
        expect(needle, why_of(machine)["caps"] == "p:fac_b", f"why {why_of(machine)}")
    settle(cluster)
    needle = "popup: lines per player and reason, shown on the blocked machine, not for a transient round"
    first, second = (m.popups() for m in cluster.machines)
    expect(needle, len(first) == 1 and len(second) == 1, f"popups {first} {second}")
    expect(needle, first[0].splitlines()[0] == f"Alpha Mod: {HEADLINE_ALL}", first[0])
    expect(needle, "Eataine: memreader Plus could not start." in first[0], first[0])
    expect(
        needle,
        "The player named above should close every copy of the game, allow memreader Plus in their antivirus"
        in first[0],
        first[0],
    )
    expect(needle, "Your game: memreader Plus could not start." in second[0], second[0])
    expect(
        needle,
        "Close every copy of the game, allow memreader Plus in your antivirus if it blocked it, and load this campaign"
        in second[0],
        second[0],
    )
    expect(needle, "lua_mod_log.txt in the game folder shows the reason" in second[0], second[0])
    expect(needle, "lua_mod_log.txt" not in first[0], first[0])
    expect(needle, "by Windows Smart App Control" in first[0], first[0])
    expect(needle, "turn off" not in first[0] and "Smart App Control, close" not in first[0], first[0])
    expect(needle, cluster.machines[0].apply_ticks[0] + 5 <= 10, "timing")


def scenario_popup_lines():
    needle = "popup: lines per player and reason, shown on the blocked machine, not for a transient round"
    cluster = Cluster(
        [Setup(), Setup(plus=False), Setup(states={MOD["owner"]: {"caps": "s", "bits": "r"}}), Setup(mods=[])],
        lockstep=True,
    )
    settle(cluster)
    text = cluster.machines[0].popups()[0]
    for line in (
        "Eataine: memreader Plus could not start.",
        "Karaz-a-Karak: the mod could not find the game code it needs.",
        "fac_d: their game did not answer.",
    ):
        expect(needle, line in text, f"{line!r} not in {text!r}")
    expect(needle, text.count("Eataine") == 1, "a player listed twice for two features")
    mine = cluster.machines[0].popups()[0]
    expect(needle, mine.splitlines()[0] == f"Alpha Mod: {HEADLINE_ALL}", mine)
    for explanation in (
        "may have been stopped by an antivirus",
        "A game update, or another mod",
        "A script error",
    ):
        expect(needle, text.count(explanation) == 1, f"{explanation!r} not once in {text!r}")

    cluster = settle(Cluster([Setup(), Setup(plus=False), Setup(plus=False)]))
    text = cluster.machines[0].popups()[0]
    expect(needle, "Each player named above should close every copy of the game" in text, text)
    expect(needle, "Eataine: memreader Plus could not start." in text and "Karaz-a-Karak: memreader" in text, text)

    cluster = Cluster([Setup(), Setup(), Setup(delay=64)], lockstep=False)
    settle(cluster)
    expect(needle, all(m.popups() == [] for m in cluster.machines), [m.popups() for m in cluster.machines])
    expect(needle, all(len(m.records(MOD["owner"])) == 2 for m in cluster.machines), "no transient round happened")

    cluster = Cluster([Setup(), Setup(), Setup(delay=90)], lockstep=False)
    settle(cluster)
    expect(
        needle,
        [len(m.popups()) for m in cluster.machines] == [1, 1, 0],
        "a settled false alarm shows on the ones that waited",
    )


def scenario_site_missing():
    needle = "site missing: one feature off"
    cluster = Cluster([Setup(), Setup(hide="caps")], real=True)
    settle(cluster)
    for machine in cluster.machines:
        expect(
            needle,
            "caps" not in on_of(machine) and {"armies", "heroes"} <= on_of(machine),
            f"{machine.name} {on_of(machine)}",
        )
        expect(needle, why_of(machine)["caps"] == "s:fac_b", why_of(machine))
    text = cluster.machines[0].popups()[0]
    expect(needle, text.splitlines()[0] == f"Alpha Mod: {HEADLINE_PART}", text)
    expect(needle, "Eataine: the mod could not find the game code it needs." in text, text)


def scenario_versions():
    needle = "schema mismatch: all off"
    other = {**MOD, "format": 4}
    cluster = settle(Cluster([Setup(), Setup(mods=[other])]))
    for machine in cluster.machines:
        expect(
            needle,
            on_of(machine) == set() and why_of(machine)["caps"] == "v:fac_b",
            f"{on_of(machine)} {why_of(machine)}",
        )
    needle = "differing option keys: same values and why everywhere"
    other = {**MOD, "options": {**MOD["options"], "extra": 1}}
    cluster = settle(Cluster([Setup(), Setup(mods=[other])]))
    states = {final_state(m) for m in cluster.machines}
    expect(needle, len(states) == 1, f"{states}")
    expect(
        needle, all(on_of(m) == set() and why_of(m)["caps"] == "v:fac_b" for m in cluster.machines), "not off for all"
    )
    smaller = {**MOD, "options": {"player_cap": 30}}
    cluster = settle(Cluster([Setup(mods=[smaller]), Setup(), Setup()]))
    states = {final_state(m) for m in cluster.machines}
    expect(needle, len(states) == 1, f"{states}")
    expect(needle, all(why_of(m)["caps"] == "v:fac_b,v:fac_c" for m in cluster.machines), why_of(cluster.machines[0]))


def scenario_game_environment():
    needle = "agree finds the game environment of its caller"
    cluster = settle(Cluster([Setup(split=True), Setup(split=True)]))
    for machine in cluster.machines:
        expect(needle, machine.lua.eval("rawget(_G, 'cm') == nil"), "the game globals leaked into the real globals")
        expect(needle, on_of(machine) == ALL_SAME, f"{machine.name}: {machine.last()}")
        expect(needle, any("mod_alpha round 1:" in line for line in machine.logs()), "no decision line through out()")


def scenario_majority():
    needle = "schema mismatch: all off"
    odd = {**MOD, "format": 4}
    cluster = settle(Cluster([Setup(mods=[odd]), Setup(), Setup()]))
    for machine in cluster.machines:
        expect(needle, on_of(machine) == set() and why_of(machine)["caps"] == "v:fac_b,v:fac_c", f"{why_of(machine)}")
    cluster = settle(Cluster([Setup(), Setup(mods=[odd]), Setup(mods=[odd])]))
    for machine in cluster.machines:
        expect(needle, why_of(machine)["caps"] == "v:fac_b,v:fac_c", f"{why_of(machine)}")


def scenario_missing_mod():
    needle = "mod missing: off after t"
    cluster = settle(Cluster([Setup(), Setup(), Setup(mods=[])]))
    for machine in cluster.machines[:2]:
        expect(
            needle,
            on_of(machine) == set() and why_of(machine)["caps"] == "n:fac_c",
            f"{on_of(machine)} {why_of(machine)}",
        )
        expect(needle, 60 <= machine.apply_ticks[0] <= 70, f"{machine.apply_ticks}")

    needle = "foreign protocol: off at once"
    cluster = Cluster([Setup(), Setup(mods=[])])
    cluster.run(3)
    cluster.inject(2, "mrp|2|r|mod_alpha|1|1/1|whatever")
    cluster.run(5)
    machine = cluster.machines[0]
    expect(needle, machine.apply_ticks and machine.apply_ticks[0] <= 10, f"{machine.apply_ticks}")
    expect(
        needle, on_of(machine) == set() and why_of(machine)["caps"] == "v:fac_b", f"{on_of(machine)} {why_of(machine)}"
    )

    needle = "garbled piece: off at once"
    for garbled in (
        "mrp|1|r|mod_alpha|1|5/2|zzz",
        "mrp|1|r|mod_alpha|1|2/2|zzz",
        "mrp|1|r|mod_alpha|1|1/1|not a report",
        "mrp|1|z|mod_alpha|1|1/1|",
    ):
        cluster = Cluster([Setup(), Setup(mods=[])])
        cluster.run(3)
        cluster.inject(2, garbled)
        cluster.run(5)
        machine = cluster.machines[0]
        expect(needle, machine.apply_ticks and machine.apply_ticks[0] <= 10, f"{garbled}: {machine.apply_ticks}")
        expect(
            needle, on_of(machine) == set() and why_of(machine)["caps"] == "v:fac_b", f"{garbled}: {why_of(machine)}"
        )
    probe = Cluster([Setup(), Setup()])
    probe.run(3)
    report = next(text for _, cqi, text, _ in probe.stream if cqi == 2).decode().split("|", 6)[6]
    cut = [report[:12], report[12:24], report[24:]]
    for pieces in ([0, 1, 1, 2], [0, 2]):
        cluster = Cluster([Setup(), Setup(mods=[])])
        cluster.run(3)
        for number in pieces:
            cluster.inject(2, f"mrp|1|r|mod_alpha|1|{number + 1}/3|{cut[number]}")
        cluster.run(5)
        machine = cluster.machines[0]
        expect(needle, machine.apply_ticks and machine.apply_ticks[0] <= 10, f"pieces {pieces}: {machine.apply_ticks}")
        expect(needle, why_of(machine) and why_of(machine)["caps"] == "v:fac_b", f"pieces {pieces}: {why_of(machine)}")
    cluster = Cluster([Setup(), Setup(mods=[])])
    cluster.run(3)
    cluster.inject(2, "mrp|junk")
    cluster.run(5)
    expect(needle, why_of(cluster.machines[0]) and why_of(cluster.machines[0])["caps"] == "v:fac_b", "unreadable owner")


def scenario_late():
    needle = "late report opens round 2"
    cluster = settle(Cluster([Setup(), Setup(), Setup(delay=80)], lockstep=False))
    for machine in cluster.machines:
        records = machine.records(MOD["owner"])
        expect(needle, len(records) == 2, f"{machine.name} applied {len(records)} times")
        expect(needle, shared(records[0]) == set() and shared(records[1]) == ALL_SAME, f"{records}")
        expect(needle, records[0]["why"]["caps"] == "n:fac_c", records[0]["why"])

    needle = "t then report: converges"
    for delay in range(56, 68):
        cluster = settle(Cluster([Setup(), Setup(), Setup(delay=delay)], lockstep=False))
        finals = {final_state(m) for m in cluster.machines}
        expect(needle, len(finals) == 1 and on_of(cluster.machines[0]) == ALL_SAME, f"delay {delay}: {finals}")

    needle = "timer runs while loading: converges"
    for delay in (45, 59, 61, 75, 130):
        cluster = settle(Cluster([Setup(), Setup(), Setup(delay=delay)], lockstep=False))
        expect(needle, all(on_of(m) == ALL_SAME for m in cluster.machines), f"delay {delay}")
    cluster = settle(Cluster([Setup(), Setup(), Setup(delay=100)], lockstep=True))
    expect(needle, all(len(m.records(MOD["owner"])) == 1 for m in cluster.machines), "lockstep timers fired early")


def scenario_shuffle():
    needle = "intra-tick shuffle"
    worst = 0
    for seed in range(1, 41):
        delays = [random.Random(seed).choice([0, 5, 62]), 0, random.Random(seed + 1).choice([0, 3, 63])]
        cluster = Cluster(
            [Setup(delay=d, agree_delay=a) for d, a in zip(delays, (0, 4, 9), strict=True)],
            seed=seed,
            shuffle_inside=True,
            lockstep=False,
        )
        cluster.run(ROUND_TICKS)
        finals = {final_state(m) for m in cluster.machines}
        expect(needle, len(finals) == 1, f"seed {seed}: {finals}")
        worst = max(worst, max(len(m.records(MOD["owner"])) for m in cluster.machines))
    print(f"    intra-tick shuffle: most applies on one machine {worst}")


def scenario_apply_failures():
    needle = "apply inside a hooked call: off for all"
    cluster = Cluster([Setup(install=True), Setup(install=True)], real=True)
    cluster.at(1, lambda: cluster.machines[1].real.mr.frames.append([1, 0, [], False, None]))
    cluster.at(3, lambda: cluster.machines[1].real.mr.frames.clear())
    cluster.machines[1].delay = 0
    settle(cluster)
    for machine in cluster.machines:
        records = machine.records(MOD["owner"])
        expect(needle, len(records) == 2, f"{machine.name} applied {len(records)} times")
        expect(needle, shared(records[-1]) == {"bits"}, f"final on {shared(records[-1])}")
        expect(needle, "r:fac_b" in records[-1]["why"]["caps"], records[-1]["why"])

    needle = "apply failure: round 2 without it"
    cluster = settle(Cluster([Setup(), Setup(fail=[{"caps": "install refused"}])]))
    for machine in cluster.machines:
        records = machine.records(MOD["owner"])
        expect(needle, len(records) == 2, f"{machine.name} {len(records)}")
        expect(needle, shared(records[0]) == ALL_SAME and shared(records[1]) == ALL_SAME - {"caps"}, f"{records}")
        expect(needle, records[1]["why"]["caps"] == "r:fac_b", records[1]["why"])
    expect(
        needle, any("caps failed here: install refused" in line for line in cluster.machines[1].logs()), "no log line"
    )

    needle = "apply raises: all off"
    cluster = settle(Cluster([Setup(), Setup(fail=["raise"])]))
    for machine in cluster.machines:
        records = machine.records(MOD["owner"])
        expect(needle, len(records) == 2 and shared(records[1]) == set(), f"{machine.name} {records}")
        expect(needle, records[1]["why"]["caps"] == "r:fac_b", records[1]["why"])
    expect(needle, any("apply exploded" in line for line in cluster.machines[1].logs()), cluster.machines[1].logs())

    needle = "8 rounds cap"
    many = {
        "owner": "mod_many",
        "features": {f"f{i}": "same" for i in range(1, 11)},
        "options": {},
        "format": 1,
        "title": "Many",
    }
    plan = [{f"f{i}": "again"} for i in range(1, 11)]
    cluster = Cluster([Setup(mods=[many]), Setup(mods=[many], fail=plan)])
    settle(cluster, owner="mod_many")
    for machine in cluster.machines:
        records = machine.records("mod_many")
        expect(needle, len(records) == 9, f"{machine.name} applied {len(records)} times")
        expect(needle, shared(records[-1]) == set() and records[-1]["why"]["f1"] == "rounds", records[-1]["why"])
    expect(needle, any("no agreement after 8 rounds" in line for line in cluster.machines[0].logs()), "no log line")


def scenario_updates():
    needle = "host change: v only when values change"
    cluster = Cluster([Setup(values={"player_cap": 10}), Setup(host=True, values={"player_cap": 77})])
    settle(cluster)
    before = len(cluster.stream)

    def finalize(values):
        for machine in cluster.machines:
            machine.set_values(values)
            machine.H[b"finalize"]()
            machine.collect()
        cluster.run(6)

    finalize({"player_cap": 77})
    expect(needle, len(cluster.stream) == before, "a finalize without a change sent a message")
    finalize({"player_cap": 55})
    expect(needle, len(cluster.stream) == before + 1, f"{len(cluster.stream) - before} messages for one change")
    expect(
        needle,
        all(values_of(m)["player_cap"] == 55 and len(m.records(MOD["owner"])) == 2 for m in cluster.machines),
        "not applied once",
    )
    settle(cluster)

    needle = "client finalize ignored"
    count = len(cluster.stream)
    client = cluster.machines[0]
    client.set_values({"player_cap": 12})
    client.H[b"finalize"]()
    client.collect()
    cluster.run(6)
    expect(needle, len(cluster.stream) == count, "a client finalize sent a message")
    expect(needle, all(values_of(m)["player_cap"] == 55 for m in cluster.machines), "client values applied")

    needle = "load: fresh round 1"
    fresh = settle(Cluster([Setup(), Setup()]))
    expect(
        needle,
        all(any("mod_alpha round 1:" in line for line in m.logs()) for m in fresh.machines),
        "no round 1 decision line",
    )
    expect(needle, all(len(m.records(MOD["owner"])) == 1 for m in fresh.machines), "state carried over")


def scenario_chunks():
    needle = "chunks: every message <= 255, pieces in order"
    text = "".join(chr(33 + (i * 7) % 90) for i in range(600)) + "|,%\n\té中" * 40
    cluster = Cluster([Setup(values={"overrides": text}), Setup()], seed=3)
    settle(cluster)
    expect(
        needle,
        max(len(item[2]) for item in cluster.stream) <= LIMIT,
        f"longest {max(len(i[2]) for i in cluster.stream)}",
    )
    expect(needle, len(cluster.stream) > 8, "too few pieces to show chunking")
    expect(needle, all(values_of(m)["overrides"] == text for m in cluster.machines), "text changed on the way")

    needle = "overrides store from a real races page"
    parts = (
        ["v1"]
        + [f"f.faction_key_{i}.army=f{31 + i}" for i in range(60)]
        + ["r.skaven.h.garr=0.40.250.30.150", "r.skaven.a.own=1"]
    )
    store = ";".join(parts) + ";f.note=a,b|c%d\nüber"
    cluster = settle(Cluster([Setup(values={"overrides": store}), Setup()], seed=5))
    expect(needle, max(len(item[2]) for item in cluster.stream) <= LIMIT, "message too long")
    expect(needle, all(values_of(m)["overrides"] == store for m in cluster.machines), "store changed on the way")

    needle = "8 machines: messages per round <= 8 + value parts"
    cluster = settle(Cluster([Setup(delay=i % 3) for i in range(8)], latency=2))
    extra = len(cluster.stream) - 8
    expect(needle, all(on_of(m) == ALL_SAME for m in cluster.machines), "not all on")
    expect(needle, 0 <= extra <= 1, f"{len(cluster.stream)} messages for 8 machines")
    cluster = settle(Cluster([Setup(values={"overrides": text}) if i == 0 else Setup() for i in range(8)], latency=2))
    parts = sum(1 for item in cluster.stream if item[2].split(b"|")[2] == b"r") - 8
    expect(
        needle, len(cluster.stream) <= 8 + parts and parts > 0, f"{len(cluster.stream)} messages, value parts {parts}"
    )


WINDOW_OF_TWO = 15


def big_text(size, seed=1):
    rng = random.Random(seed)
    pool = [chr(code) for code in range(33, 127)] + ["|", ",", "%", " ", "é", "中"]
    return "".join(rng.choice(pool) for _ in range(size))


def scenario_big_bodies():
    needle = "big body: 150 KB intact on 2 and 4 machines, interleaved with another owner"
    text = big_text(150_000)
    for count in (2, 4):
        for seed in (1, 2):
            setups = [
                Setup(mods=[MOD, SECOND], host=index == 0, values={"overrides": text if index == 0 else "other"})
                for index in range(count)
            ]
            cluster = Cluster(setups, seed=seed, shuffle_inside=True, latency=1 + seed)
            cluster.run(BIG_TICKS)
            expect(BUDGET, cluster.worst <= HALF_PACKET, f"a tick carried {cluster.worst} bytes")
            for owner in (MOD["owner"], SECOND["owner"]):
                finals = {final_state(m, owner) for m in cluster.machines}
                expect(
                    needle, len(finals) == 1 and None not in finals, f"{count} machines, {owner}: {len(finals)} states"
                )
            for machine in cluster.machines:
                expect(needle, values_of(machine)["overrides"] == text, f"{count} machines: the text changed")
                expect(needle, on_of(machine) == ALL_SAME, f"{count} machines: on {on_of(machine)}")
                expect(needle, on_of(machine, SECOND["owner"]) == {"ticks", "regen"}, "the second owner")
            expect(needle, max(len(item[2]) for item in cluster.stream) <= LIMIT, "a message is too long")
            expect(needle, len(cluster.stream) > 700, f"only {len(cluster.stream)} messages")

    needle = "big body: sending is paced"
    cluster = Cluster([Setup(host=True, values={"overrides": text}), Setup()])
    cluster.run(BIG_TICKS)
    host = cluster.machines[0]
    expect(needle, host.peak == WINDOW_OF_TWO, f"peak {host.peak} messages in one tick")
    expect(needle, host.apply_ticks[0] >= len(cluster.stream) // (2 * WINDOW_OF_TWO), f"decided at {host.apply_ticks}")
    expect(needle, all(m.peak <= WINDOW_OF_TWO for m in cluster.machines), [m.peak for m in cluster.machines])

    needle = "big body: progress extends the timeout"
    slow = big_text(350_000, 3)
    cluster = Cluster([Setup(host=True, values={"overrides": slow}), Setup()])
    cluster.run(BIG_TICKS)
    for machine in cluster.machines:
        records = machine.records(MOD["owner"])
        expect(needle, len(records) == 1 and shared(records[0]) == ALL_SAME, f"{machine.name}: {len(records)} applies")
        expect(needle, records[0]["values"]["overrides"] == slow, "text changed")
        expect(
            needle, machine.apply_ticks[0] > 60, f"decided at {machine.apply_ticks}, before the first 60 s were over"
        )

    needle = "stalled big body: times out without progress"
    cluster = Cluster([Setup(host=True, values={"overrides": slow}), Setup()])
    cluster.at(30, lambda: setattr(cluster.machines[0].setup, "silent", True))
    cluster.run(ROUND_TICKS)
    for machine in cluster.machines:
        expect(needle, why_of(machine)["caps"] == "n:fac_a" and on_of(machine) == set(), f"{why_of(machine)}")
        expect(needle, 100 < machine.apply_ticks[0] < 135, f"decided at {machine.apply_ticks}")


def budget_run(count, size, seed=1):
    text = big_text(size, seed)
    setups = [
        Setup(mods=[MOD, SECOND], host=index == 0, values={"overrides": text if index == 0 else "other"})
        for index in range(count)
    ]
    cluster = Cluster(setups, seed=seed, shuffle_inside=True, latency=2)
    cluster.run(BIG_TICKS)
    return cluster, text


def with_agree(source, run):
    global AGREE
    saved = AGREE
    AGREE = source
    try:
        return run()
    finally:
        AGREE = saved


def scenario_tick_budget():
    needle = "tick budget: bodies of 13 KB and 150 KB arrive intact within the budget"
    for count in (2, 3, 4, 8):
        for size in (13_000, 150_000):
            cluster, text = budget_run(count, size)
            expect(BUDGET, cluster.worst <= HALF_PACKET, f"{count} machines, {size}: {cluster.worst} bytes in a tick")
            expect(needle, cluster.worst <= PACKET_ROOM, f"{count} machines, {size}: the packet overflowed")
            for machine in cluster.machines:
                expect(needle, values_of(machine) and values_of(machine)["overrides"] == text, f"{count}, {size}")
                expect(needle, on_of(machine) == ALL_SAME, f"{count} machines, {size}: on {on_of(machine)}")
            decided = max(m.apply_ticks[-1] for m in cluster.machines)
            print(f"    {count} machines, {size} chars: {len(cluster.stream)} messages, decided at tick {decided}")

    needle = "tick budget: a burst without a window overflows the packet"
    unbounded = AGREE.replace(b"local TICK_BUDGET = 8192", b"local TICK_BUDGET = 8192000")
    expect(needle, unbounded != AGREE, "the mutation did not apply")
    for count, size in ((2, 13_000), (4, 150_000)):
        cluster, _ = with_agree(unbounded, lambda count=count, size=size: budget_run(count, size))
        expect(needle, cluster.worst > PACKET_ROOM, f"{count} machines, {size}: only {cluster.worst} bytes in a tick")

    needle = "tick budget: a stall of any length never puts more than the window in flight"
    text = big_text(40_000)
    for stall in (20, 400):
        cluster = Cluster([Setup(host=True, values={"overrides": text}), Setup()], latency=1)
        host = cluster.machines[0]
        cluster.run(4)
        base = sum(1 for item in cluster.stream if item[1] == host.cqi)
        cluster.frozen = True
        cluster.run(stall)
        held_items = [item for item in cluster.stream if item[1] == host.cqi][base:]
        held_bytes = sum(len(item[2]) + COMMAND_OVERHEAD for item in held_items) + BACKGROUND_BYTES
        expect(needle, len(held_items) <= WINDOW_OF_TWO, f"stall {stall}: {len(held_items)} messages sent")
        expect(needle, held_bytes <= HALF_PACKET, f"stall {stall}: {held_bytes} bytes queued for the next tick")
        cluster.frozen = False
        cluster.run(BIG_TICKS)
        expect(needle, cluster.worst <= HALF_PACKET, f"stall {stall}: a tick carried {cluster.worst} bytes")
        for machine in cluster.machines:
            expect(needle, values_of(machine) and values_of(machine)["overrides"] == text, f"stall {stall}: body")

    needle = "tick budget: lost pieces end in the timeout for everyone, never in a burst"
    cluster = Cluster([Setup(host=True, values={"overrides": text}), Setup()], latency=1)
    cluster.at(3, lambda: setattr(cluster, "drop", 1.0))
    cluster.at(5, lambda: setattr(cluster, "drop", 0.0))
    cluster.run(400)
    expect(needle, cluster.worst <= HALF_PACKET, f"a tick carried {cluster.worst} bytes")
    finals = {final_state(m) for m in cluster.machines}
    expect(needle, len(finals) == 1 and None not in finals, f"{len(finals)} states")
    expect(needle, all(on_of(m) == set() for m in cluster.machines), "the mod stayed on after lost pieces")


def scenario_over_maximum():
    needle = "over the maximum: z on every machine"
    huge = "x" * 1_050_000
    for synced in (True, False):
        cluster = Cluster([Setup(host=True, synced=synced, values={"overrides": huge}), Setup(), Setup()])
        if not synced:
            cluster.at(10, lambda c=cluster: c.machines[0].set_synced(True))
        settle(cluster)
        for machine in cluster.machines:
            expect(needle, on_of(machine) == set(), f"synced {synced}: {machine.name} on {on_of(machine)}")
            expect(needle, why_of(machine)["caps"] == "z:fac_a", why_of(machine))
            expect(needle, len(machine.records(MOD["owner"])) == 1, f"{machine.name} applied twice")
        expect(needle, max(len(item[2]) for item in cluster.stream) <= LIMIT, "a message is too long")
        expect(needle, len(cluster.stream) < 40, f"{len(cluster.stream)} messages: the huge body was sent")
        first, second = cluster.machines[0].popups()[0], cluster.machines[1].popups()[0]
        expect(needle, "Your game: the mod settings are too large to send." in first, first)
        expect(needle, "Reikland: the mod settings are too large to send." in second, second)
        expect(needle, "should reset some of the mod's settings to their defaults" in second, second)
        expect(needle, "did not answer" not in second, second)
        expect(needle, "MB" not in first and "MB" not in second, "the size is named in a popup")

    needle = "too-large update: the host gets one popup, the others keep the settings"
    cluster = settle(Cluster([Setup(host=True, values={"overrides": "small"}), Setup(), Setup()]))
    before = len(cluster.stream)
    host = cluster.machines[0]
    for size in (1_050_000, 1_060_000):
        host.set_values({"overrides": "y" * size})
        host.H[b"finalize"]()
        host.collect()
        cluster.run(10)
    expect(
        needle,
        len(cluster.stream) == before,
        f"{len(cluster.stream) - before} messages for a change that cannot be sent",
    )
    popups = host.popups()
    expect(needle, len(popups) == 1, f"{len(popups)} popups on the host")
    expect(needle, popups[0].startswith("Alpha Mod: your change to the mod settings was too large to send."), popups)
    expect(needle, "Everyone keeps the previous settings." in popups[0] and "MB" not in popups[0], popups)
    expect(needle, all(m.popups() == [] for m in cluster.machines[1:]), "a client got a popup")
    expect(needle, all(values_of(m)["overrides"] == "small" for m in cluster.machines), "the old settings did not stay")
    expect(needle, any("more than the" in line for line in host.logs()), "no log line with the size")

    needle = "too many pieces announced: off at once"
    cluster = Cluster([Setup(), Setup(mods=[])])
    cluster.run(3)
    cluster.inject(2, "mrp|1|r|mod_alpha|1|1/6001|x")
    cluster.run(5)
    machine = cluster.machines[0]
    expect(
        needle, machine.apply_ticks and why_of(machine)["caps"] == "v:fac_b", f"{machine.apply_ticks} {why_of(machine)}"
    )


def scenario_single_player():
    needle = "sp: no UITrigger listener, no message, apply on finalize"
    cluster = Cluster([Setup(mp=False, values={"player_cap": 10})])
    cluster.run(5)
    machine = cluster.machines[0]
    expect(needle, machine.listening("MctFinalized") and not machine.listening("UITrigger"), "listeners")
    expect(needle, not cluster.stream and not machine.outbox, "a message was sent")
    expect(
        needle,
        len(machine.records(MOD["owner"])) == 1 and values_of(machine)["player_cap"] == 10,
        machine.records(MOD["owner"]),
    )
    expect(needle, set(machine.last()["on"]) == ALL_SAME | {"panel"}, f"on {machine.last()}")
    expect(needle, len(machine.H[b"timers"]) == 0, "a timer was set")
    machine.H[b"finalize"]()
    expect(needle, len(machine.records(MOD["owner"])) == 1, "applied without a change")
    machine.set_values({"player_cap": 12})
    machine.H[b"finalize"]()
    expect(
        needle,
        len(machine.records(MOD["owner"])) == 2 and values_of(machine)["player_cap"] == 12,
        "no apply on finalize",
    )
    expect(needle, machine.H[b"gate"](b"mod_alpha", b"caps") is None, "gate in single player")

    needle = "single player: one decision line in the mod log"
    mod_lines = [line.decode() for _, line in sorted(machine.H[b"mod_lines"].items())]
    decisions = [line for line in mod_lines if "mod_alpha single player: on=" in line]
    expect(needle, len(decisions) == 1 and "caps" in decisions[0], mod_lines)
    expect(needle, len(machine.H[b"script_lines"]) == 0, "Plus wrote to the script log instead of the mod log")
    expect(needle, any("MCT settings finalized, checking 1 owner" in line for line in mod_lines), mod_lines)
    expect(needle, any("the shared settings changed, applying them again" in line for line in mod_lines), mod_lines)
    machine.H[b"finalize"]()
    mod_lines = [line.decode() for _, line in sorted(machine.H[b"mod_lines"].items())]
    expect(needle, any("the shared settings did not change" in line for line in mod_lines), mod_lines)


def entry_address(machine, name):
    entry = S.site_installer_sim.lua_to_python(machine.real.lua.eval(S.lint_sites.DATA_LOADER)(FIXTURE, b"e"))
    entry = {e["name"]: e for e in entry}[name]
    return S.site_installer_sim.site_of(machine.real.mr.image, entry)


def scenario_gate():
    needle = "gate: set before agreement refused, entry still found"
    cluster = Cluster([Setup(), Setup(delay=40)], real=True)
    cluster.run(3)
    machine = cluster.machines[0]
    site = machine.H[b"real_sites"][b"mod_alpha"]
    before = len(machine.real.mr.writes)
    refused = site.set(b"player_cap", 40)
    expect(needle, refused == (False, b"waiting for the multiplayer agreement"), refused)
    install = site.install_feature(b"caps")
    expect(needle, install == (False, b"waiting for the multiplayer agreement"), install)
    expect(needle, site.found(b"player_cap") and site.why(b"player_cap") is None, "the entry was marked missing")
    expect(needle, site.found(b"player_cap") and len(machine.real.mr.writes) == before, "bytes were written")
    expect(needle, site.remove_feature(b"caps") is True, "remove_feature is gated")

    needle = "gate: off feature refused"
    cluster = Cluster([Setup(), Setup(hide="caps")], real=True)
    settle(cluster)
    machine = cluster.machines[0]
    site = machine.H[b"real_sites"][b"mod_alpha"]
    refused = site.set(b"player_cap", 40)
    expect(needle, refused == (False, b"off in this multiplayer campaign"), refused)
    expect(needle, site.found(b"player_cap"), "the refusal marked the entry missing")
    allowed = site.set(b"armies_count_first", 8)
    expect(needle, allowed is True, f"an on feature was refused: {allowed}")
    expect(
        needle,
        site.install_feature(b"caps") == (False, b"off in this multiplayer campaign"),
        "install_feature not gated",
    )


def leftover_before(machine, make, sites):
    sites.set(b"player_cap", 60)
    machine.earlier = machine.real.mr.read_bytes(entry_address(machine, "player_cap"), 4, False)
    fresh = make()
    fresh.set(b"ai_cap", 200)
    return fresh


def scenario_leftovers():
    needle = "leftover from earlier campaign removed"
    cluster = Cluster([Setup(before=leftover_before), Setup()], real=True)
    machine = cluster.machines[0]
    cluster.run(1)
    address = entry_address(machine, "player_cap")
    original = machine.real.mr.read_bytes(address, 4, True)
    expect(needle, machine.earlier == (60).to_bytes(4, "little"), "the earlier campaign wrote nothing")
    cluster.run(ROUND_TICKS)
    expect(needle, machine.real.mr.read_bytes(address, 4, False) == original, "the leftover is still written")
    rows = {plain(row)["name"] for row in machine.real.patcher.patch_list(b"mod_alpha").values()}
    expect(needle, "player_cap" not in rows, f"rows {rows}")

    needle = "load-time write kept"
    other = entry_address(machine, "ai_cap")
    expect(
        needle,
        machine.real.mr.read_bytes(other, 4, False) == (200).to_bytes(4, "little"),
        "the load-time write was removed",
    )
    expect(needle, "ai_cap" in rows, f"rows {rows}")


def scenario_ready_and_remove():
    needle = "ready: read-only, no mark_missing"
    cluster = Cluster([Setup(delay=50), Setup(delay=50)], real=True)
    machine = cluster.machines[0]
    site = machine.real.sites("mod_alpha", FIXTURE)
    address = entry_address(machine, "armies_count_first")
    expect(needle, site.ready(b"armies") is True, "a fresh feature is not ready")
    machine.real.mr.foreign_patch(address, b"\x00")
    result = site.ready(b"armies")
    expect(needle, result[0] is False and result[1] == b"r", result)
    expect(
        needle,
        site.found(b"armies_count_first") and site.why(b"armies_count_first") is None,
        "ready marked the entry missing",
    )
    expect(needle, not machine.real.logs, machine.real.logs)
    expect(needle, site.ready(b"armies", True)[0] is False, "installed=true accepted an uninstalled value")
    machine.real.mr.overlay.clear()
    expect(needle, site.ready(b"armies") is True, "ready did not recover")
    expect(needle, site.ready(b"no_such_feature") is True, "a feature without entries is not ready")

    needle = "remove_feature restores held bytes"
    hold = machine.real.mr.read_bytes(address, 1, True)
    expect(needle, site.set(b"armies_count_first", 8) is True, "set failed")
    expect(needle, site.set(b"armies_count_second", 8) is True, "second set failed")
    expect(needle, site.ready(b"armies", True) is not True, "armies are not all installed")
    expect(needle, machine.real.mr.read_bytes(address, 1, False) == (8).to_bytes(1, "little"), "not written")
    expect(needle, site.remove_feature(b"armies") is True, "remove_feature failed")
    expect(needle, machine.real.mr.read_bytes(address, 1, False) == hold, "bytes not restored")
    expect(needle, site.found(b"armies_count_first"), "remove_feature marked the entry missing")
    expect(needle, site.set(b"armies_count_first", 8) is True, "set after remove_feature failed")


def scenario_api():
    needle = "api errors: wrong types raise"
    cluster = Cluster([Setup()])
    machine = cluster.machines[0]
    agree = machine.lua.eval("function(...) return pcall(memreader_plus_agree, ...) end")
    good = to_lua(
        machine.lua,
        {"features": {"a": "same"}, "options": {}, "format": 1, "apply": machine.lua.eval("function() end")},
    )
    for bad in (
        (b"bad name", good),
        (b"x", None),
        (b"x", to_lua(machine.lua, {"features": {"a": "weird"}, "format": 1})),
        (
            b"x",
            to_lua(machine.lua, {"features": {"a": "same"}, "format": 0, "apply": machine.lua.eval("function() end")}),
        ),
        (b"x", to_lua(machine.lua, {"features": {"a": "same"}, "format": 1})),
        (
            b"x",
            to_lua(
                machine.lua,
                {"features": {"a": "same"}, "format": 1, "prepare": 5, "apply": machine.lua.eval("function() end")},
            ),
        ),
    ):
        expect(needle, agree(*bad)[0] is False, f"{bad[0]} did not raise")
    needle = "campaign only and one call per owner"
    first = machine.call("function(owner, spec) return memreader_plus_agree(owner, spec) end", b"x", good)
    second = machine.call("function(owner, spec) return memreader_plus_agree(owner, spec) end", b"x", good)
    expect(needle, first is True and second == (None, b"already called"), f"{first} {second}")
    machine.lua.execute("cm = nil")
    nothing = machine.call("function(owner, spec) return memreader_plus_agree(owner, spec) end", b"y", good)
    expect(needle, nothing == (None, b"campaign only"), nothing)


def loader_world(agree_source, dll_works=True):
    lua = S.lint_sites.new_runtime(False)
    lua.execute(LOADER_WORLD)
    lua.globals()[b"AGREE_SOURCE"] = agree_source
    if not dll_works:
        lua.execute("package.preload.fake_plus = function() error('blocked') end")
    return lua


def run_loader(lua):
    return lua.eval("function(source) local result = loadstring(source, '@loader')(mod_log) return result end")(LOADER)


def scenario_loader():
    needle = "loader twice: one agree instance, state kept"
    lua = loader_world(AGREE, dll_works=False)
    expect(needle, run_loader(lua) is None, "the loader returned a module without the DLL")
    lua.execute("first_agree = memreader_plus_agree")
    second_run = run_loader(lua)
    expect(needle, second_run is None and lua.eval("memreader_plus_agree == first_agree"), "a second instance was made")
    expect(needle, lua.eval("memreader_plus_load_error ~= nil and memreader_plus == nil"), "load error or global wrong")
    machine = Cluster([Setup()]).machines[0]
    again = machine.H[b"rerun_agree"](AGREE)
    expect(needle, again == (True, True), f"rerun {again}")
    spec = to_lua(
        machine.lua,
        {"features": {"a": "same"}, "options": {}, "format": 1, "apply": machine.lua.eval("function() end")},
    )
    call = "function(owner, spec) return memreader_plus_agree(owner, spec) end"
    expect(needle, machine.call(call, b"x", spec) is True, "first call")
    machine.H[b"rerun_agree"](AGREE)
    expect(needle, machine.call(call, b"x", spec) == (None, b"already called"), "state lost after a second load")

    needle = "dll blocked: the loader asks for the one Plus popup"
    lua = loader_world(AGREE, dll_works=False)
    lua.execute(MOCK)
    lua.execute(
        "memreader_plus = nil H.configure({ mp = false, me = 'fac_a', cqi = 1, humans = { 'fac_a' },"
        " names = { 'fac_a' }, host = false, synced = true, values = {} })"
    )
    expect(needle, run_loader(lua) is None, "the loader returned a module without the DLL")
    expect(needle, lua.eval("#H.first_ticks") == 1, "no popup was scheduled for the campaign")
    run_loader(lua)
    expect(needle, lua.eval("#H.first_ticks") == 1, "a second loader run scheduled a second popup")
    lua.execute("H.run_load_callbacks() H.advance_real(500)")
    shown = [text.decode() for _, text in sorted(lua.eval("H.popups").items())]
    expect(needle, shown == [BLOCKED_TEXT], shown)
    logs = " ".join(line.decode() for line in lua.eval("log_lines").values())
    expect(needle, "not loaded:" in logs, "the reason did not reach the log")

    needle = "mod files load: no Plus global or package key shares a name with one"
    names = sorted({path.stem for folder in MOD_FOLDERS if folder.exists() for path in folder.glob("*.lua")})
    lua = loader_world(AGREE)
    lua.execute(MOCK)
    lua.execute("memreader_plus = nil")
    run_loader(lua)
    expect(needle, len(names) >= 4, f"no mod files found: {names}")
    load_mod = lua.eval("H.load_mod_script")
    for name in names:
        loaded = load_mod(f"script/campaign/mod/{name}.lua".encode(), b"return true")
        expect(
            needle, loaded is True, f"the game's mod loader would skip {name}.lua because package.loaded.{name} is set"
        )
        expect(needle, lua.eval(f"type(_G['{name}']) ~= 'function'"), f"execute_mods would call the global {name}()")
    expect(
        needle,
        load_mod(b"script/campaign/mod/memreader_plus_agree_state.lua", b"return true") is False,
        "the emulation skips nothing",
    )

    needle = "agree.lua error: DLL still loads"
    for broken in (b"this is not lua (", b"error('boom')"):
        lua = loader_world(broken)
        result = run_loader(lua)
        expect(needle, result is not None and lua.eval("memreader_plus == fake"), "the DLL did not load")
        expect(needle, lua.eval("memreader_plus_agree == nil and fake.agree == nil"), "an agree function exists")
        expect(needle, lua.eval("sites_args[2] == nil"), "sites got a gate")
        logs = " ".join(line.decode() for line in lua.eval("log_lines").values())
        expect(needle, "agreement module not loaded" in logs, logs)
    lua = loader_world(AGREE)
    run_loader(lua)
    expect(
        needle, lua.eval("type(memreader_plus_agree) == 'function' and fake.agree == memreader_plus_agree"), "wiring"
    )
    expect(needle, lua.eval("type(sites_args[2].gate) == 'function'"), "sites got no gate")


BLOCKED_TEXT = (
    "memreader Plus could not start, so mods that use it do nothing.\n\n"
    "memreader Plus may have been stopped by an antivirus, by Windows Smart App Control, or by a second copy of "
    "Total War: WARHAMMER III that is still open. Close every copy of the game, allow memreader Plus in your "
    "antivirus if it blocked it, and start the game again. "
    "The file lua_mod_log.txt in the game folder shows the reason."
)
BLOCKED_FLAG = b"memreader_plus_blocked_shown"


def warn_blocked(machine):
    done = machine.internals[b"warn_blocked"](machine.lua.globals())
    machine.H[b"run_load_callbacks"]()
    machine.H[b"advance_real"](500)
    return done


def scenario_blocked_popup():
    needle = "blocked: one Plus popup per session, none in multiplayer"
    machine = Cluster([Setup(mp=False)]).machines[0]
    expect(needle, warn_blocked(machine) is True, "the first call did nothing")
    expect(needle, machine.popups() == [BLOCKED_TEXT], machine.popups())
    expect(needle, machine.H[b"svr"][BLOCKED_FLAG] is True, "the session flag was not set")
    expect(needle, warn_blocked(machine) is False and len(machine.popups()) == 1, "a second popup")

    machine = Cluster([Setup(mp=False, mode="frontend")]).machines[0]
    warn_blocked(machine)
    expect(needle, machine.popups() == [BLOCKED_TEXT], f"frontend: {machine.popups()}")

    machine = Cluster([Setup(mp=False)]).machines[0]
    machine.H[b"svr"][BLOCKED_FLAG] = True
    warn_blocked(machine)
    expect(needle, machine.popups() == [], "shown again in the same session")

    machine = Cluster([Setup(mp=True)]).machines[0]
    warn_blocked(machine)
    expect(needle, machine.popups() == [] and machine.H[b"svr"][BLOCKED_FLAG] is None, "shown in multiplayer")

    cluster = Cluster([Setup(), Setup(plus=False)])
    cluster.at(2, lambda: warn_blocked(cluster.machines[1]))
    settle(cluster)
    popups = cluster.machines[1].popups()
    expect(needle, len(popups) == 1 and popups[0].startswith("Alpha Mod:"), f"both popups on one machine: {popups}")

    machine = Cluster([Setup(mp=False, mode="battle")]).machines[0]
    expect(needle, warn_blocked(machine) is True and machine.popups() == [], "battle showed a popup")

    machine = Cluster([Setup(mp=False)]).machines[0]
    expect(needle, machine.internals[b"warn_blocked"](machine.lua.eval("{}")) is False, "an env without core")

    machine = Cluster([Setup(mp=False)]).machines[0]
    early = machine.lua.eval("function() return { core = core } end")()
    expect(needle, machine.internals[b"warn_blocked"](early) is False, "an env with core but no cm was accepted")
    expect(needle, warn_blocked(machine) is True and machine.popups() == [BLOCKED_TEXT], "no retry once cm exists")


def scenario_early_messages():
    needle = "message before agree is replayed: one decision"
    cluster = Cluster([Setup(), Setup(agree_delay=8)], lockstep=False)
    cluster.run(6)
    late = cluster.machines[1]
    expect(needle, late.loaded and not late.started, "the late machine did not wait")
    expect(needle, late.listening("UITrigger"), "no listener before agree")
    expect(needle, all(not m.records(MOD["owner"]) for m in cluster.machines), "applied before the late agree")
    settle(cluster)
    for machine in cluster.machines:
        expect(needle, on_of(machine) == ALL_SAME, f"{machine.name} on {on_of(machine)}")
        expect(needle, len(machine.records(MOD["owner"])) == 1, f"{machine.name} applied twice")
        expect(needle, machine.apply_ticks[0] >= 8, f"{machine.name} applied at {machine.apply_ticks}")

    needle = "late agree: a round decided while replaying is logged"
    cluster = settle(Cluster([Setup(), Setup(agree_delay=70)], lockstep=False), ticks=ROUND_TICKS + 20, compare=False)
    late = cluster.machines[1]
    expect(needle, any("decided while replaying" in line for line in late.logs()), late.logs())
    expect(needle, not any("decided while replaying" in line for line in cluster.machines[0].logs()), "wrong machine")

    needle = "foreign message before agree: replayed as another version"
    cluster = Cluster([Setup(), Setup(agree_delay=8), Setup(mods=[])], lockstep=False)
    cluster.run(3)
    cluster.inject(3, "mrp|2|r|mod_alpha|1|1/1|whatever")
    settle(cluster, compare=False)
    for machine in cluster.machines[:2]:
        expect(needle, why_of(machine)["caps"] == "v:fac_c" and on_of(machine) == set(), f"{why_of(machine)}")
    expect(needle, not any("failed" in line for line in cluster.machines[2].logs()), cluster.machines[2].logs())

    needle = "load listener: one listener, removed in single player"
    machine = Cluster([Setup(mp=False, agree_delay=3)]).machines[0]
    machine.load()
    machine.H[b"listen_at_load"]()
    count = (
        "function() local n = 0 for _, l in ipairs(H.listeners) do"
        " if l.name == 'mrp_messages' then n = n + 1 end end return n end"
    )
    expect(needle, machine.call(count) == 1, "the load step registered the listener twice")
    machine.begin()
    expect(needle, machine.call(count) == 0 and not machine.listening("UITrigger"), "single player kept the listener")


def scenario_listen_env():
    needle = "load listener: only where core exists and the mode is a campaign"
    machine = Cluster([Setup(mp=True)]).machines[0]
    listen = machine.internals[b"listen"]
    expect(needle, listen(machine.lua.eval("{}")) is False, "an env without core registered a listener")
    expect(needle, listen(None) is False, "nil registered a listener")
    machine.H[b"mode"] = b"frontend"
    expect(needle, listen(machine.lua.globals()) is False, "the frontend registered a listener")
    machine.H[b"mode"] = b"campaign"
    expect(needle, not machine.listening("UITrigger"), "a listener exists after the refusals")
    expect(
        needle, listen(machine.lua.globals()) is True and machine.listening("UITrigger"), "no listener in a campaign"
    )
    machine.begin()
    expect(needle, machine.listening("UITrigger"), "a multiplayer owner lost the listener")


def scenario_host_kept():
    needle = "agree after a failed host search keeps the old host"
    cluster = Cluster([Setup(split=True), Setup(split=True, agree_delay=4)])
    call = (
        "function(agree, spec) local chunk = function() local a, b = agree('stray', spec) return a, b end"
        " setfenv(chunk, {}) return chunk() end"
    )
    spec_source = (
        "function() return { features = { a = 'same' }, options = {}, format = 1, apply = function() end } end"
    )

    def stray():
        machine = cluster.machines[0]
        failed = machine.lua.eval(call)(machine.lua.eval("GAME.memreader_plus_agree"), machine.lua.eval(spec_source)())
        expect(needle, failed == (None, b"campaign only"), failed)

    cluster.at(1, stray)
    settle(cluster)
    for machine in cluster.machines:
        expect(needle, on_of(machine) == ALL_SAME, f"{machine.name}: {machine.last()}")


PROBE = {"features": {"probe": "same"}, "options": {"text": "x"}, "format": 1, "title": "Probe", "sites": "fake"}
PROBE_OWNER = "mod_probe"


def kit_call(machine, depth):
    spec = to_lua(machine.lua, PROBE)
    result = machine.H[b"start_kit"](PROBE_OWNER.encode(), spec, to_lua(machine.lua, {}), depth)
    machine.collect()
    return tuple(result[-2:])


def chain_call(machine, depth):
    spec = machine.H[b"spec_for"](PROBE_OWNER.encode(), to_lua(machine.lua, PROBE), to_lua(machine.lua, {}))
    result = machine.H[b"poor_chain"](depth)(PROBE_OWNER.encode(), spec)
    machine.collect()
    return result


def probe_ok(machine):
    return on_of(machine, PROBE_OWNER) == {"probe"}


def scenario_caller_levels():
    needle = "agree: pcall and wrapper levels find the env with core"
    for depth in (0, 1, 3, 6):
        cluster = Cluster([Setup(split=True, global_cm=True), Setup(split=True, global_cm=True)])
        cluster.run(2)
        for machine in cluster.machines:
            machine.mods = [MOD, {**PROBE, "owner": PROBE_OWNER}]
            result = kit_call(machine, depth)
            expect(needle, result == (True, True), f"depth {depth}: {result}")
        settle(cluster, owner=PROBE_OWNER)
        for machine in cluster.machines:
            expect(needle, probe_ok(machine), f"depth {depth}: {machine.name} {machine.last(PROBE_OWNER)}")
            expect(needle, any("mod_probe round 1:" in line for line in machine.logs()), f"depth {depth}: no log")

    needle = "agree: the loader env is the last resort"
    cluster = Cluster([Setup(split=True, global_cm=True), Setup(split=True, global_cm=True)])
    cluster.run(2)
    for machine in cluster.machines:
        machine.mods = [MOD, {**PROBE, "owner": PROBE_OWNER}]
        result = chain_call(machine, 2)
        expect(needle, result[-1] is True, f"{result}")
    settle(cluster, owner=PROBE_OWNER)
    for machine in cluster.machines:
        expect(needle, probe_ok(machine), f"{machine.name}: {machine.last(PROBE_OWNER)}")


def scenario_failed_probe():
    needle = "failed probe: logging, listeners and live updates survive"
    for lane in ("a", "b"):
        cluster = Cluster(
            [
                Setup(split=True, global_cm=True, agree_delay=6 if lane == "a" else 0),
                Setup(split=True, global_cm=True, host=True, agree_delay=6 if lane == "a" else 0),
            ],
            real=False,
        )
        cluster.run(3 if lane == "a" else 2)
        for machine in cluster.machines:
            kit_call(machine, 1)
        settle(cluster)
        for machine in cluster.machines:
            lines = machine.logs()
            expect(needle, any("mod_alpha round 1:" in line for line in lines), f"lane {lane}: {machine.name} silent")
            expect(needle, any("message " in line for line in lines), f"lane {lane}: {machine.name} no message line")
            expect(needle, machine.listening("MctFinalized") and machine.listening("UITrigger"), "listeners")
        before = len(cluster.stream)
        for machine in cluster.machines:
            machine.set_values({"player_cap": 61})
            machine.H[b"finalize"]()
            machine.collect()
        cluster.run(8)
        expect(needle, len(cluster.stream) == before + 1, f"lane {lane}: {len(cluster.stream) - before} v messages")
        for machine in cluster.machines:
            expect(needle, values_of(machine)["player_cap"] == 61, f"lane {lane}: {machine.name} not applied")
            expect(needle, any("MCT settings finalized" in line for line in machine.logs()), "no finalize line")

    needle = "add_listener failure does not block the later listener"
    cluster = Cluster([Setup(agree_delay=5), Setup(agree_delay=5)])
    cluster.run(2)
    for machine in cluster.machines:
        machine.H[b"broken_listeners"] = 1
        machine.mods = [MOD, {**PROBE, "owner": PROBE_OWNER}]
        result = kit_call(machine, 0)
        expect(needle, result[0] is False and b"add_listener exploded" in result[1], f"{result}")
        expect(needle, not machine.listening("MctFinalized"), "a listener exists after the failure")
    settle(cluster)
    for machine in cluster.machines:
        expect(needle, machine.listening("MctFinalized") and on_of(machine) == ALL_SAME, f"{machine.name}")


def scenario_mct_order():
    needle = "host MCT change in the real MP order: one v, applied once everywhere"
    for host_gap, client_gap in ((0, 0), (0, 3), (0, 40), (3, 0), (30, 0)):
        cluster = Cluster([Setup(values={"player_cap": 10}), Setup(host=True, values={"player_cap": 77})])
        settle(cluster)
        before = len(cluster.stream)
        client, host = cluster.machines
        base = cluster.tick + 2

        def change(machine):
            machine.set_values({"player_cap": 55})
            machine.H[b"finalize"]()
            machine.collect()

        cluster.at(base + host_gap, lambda host=host: change(host))
        cluster.at(base + client_gap, lambda client=client: change(client))
        cluster.run(base + max(host_gap, client_gap) + 12 - cluster.tick)
        label = f"host +{host_gap} client +{client_gap}"
        expect(needle, len(cluster.stream) == before + 1, f"{label}: {len(cluster.stream) - before} messages")
        for machine in cluster.machines:
            records = machine.records(MOD["owner"])
            expect(needle, values_of(machine)["player_cap"] == 55, f"{label}: {machine.name} {values_of(machine)}")
            expect(needle, len(records) == 2, f"{label}: {machine.name} applied {len(records)} times")


def link_pointer(machine):
    entry = S.site_installer_sim.World(image("9.0.3.0")).python_entries("link_sites")["count_pre_high"]
    pointer = machine.real.mr.ptr(S.site_installer_sim.site_of(machine.real.mr.image, entry))
    machine.real.mr.game[pointer.address] = lambda *args: 7
    return pointer


def link_hits(machine):
    hits = machine.H[b"hits"][b"mod_links"]
    return int(hits) if hits else 0


def spoil_link(machine, make, sites):
    entry = S.site_installer_sim.World(image("9.0.3.0")).python_entries("link_sites")["count_pre_high"]
    machine.real.mr.foreign_write(S.site_installer_sim.site_of(machine.real.mr.image, entry), b"\x00")


def scenario_prepare_links():
    needle = "prepare: links attached before the first report, inert until on"
    cluster = Cluster([Setup(mods=[LINKS_MOD]), Setup(mods=[LINKS_MOD], agree_delay=20)], real=True, lockstep=False)
    pointers = [link_pointer(m) for m in cluster.machines]
    cluster.run(3)
    first = cluster.machines[0]
    prepared = plain(first.H[b"prepared"][1])
    expect(needle, prepared["done"] is True and not first.records("mod_links"), f"{prepared}")
    expect(needle, first.real.mr.game_call(pointers[0], 1, 2) == 7 and link_hits(first) == 0, "a link ran before on")
    settle(cluster, owner="mod_links")
    for machine, pointer in zip(cluster.machines, pointers, strict=True):
        expect(needle, on_of(machine, "mod_links") == {"count_links"}, f"{machine.name} {why_of(machine, 'mod_links')}")
        expect(needle, machine.real.mr.game_call(pointer, 1, 2) == 7, "the original result changed")
        expect(needle, link_hits(machine) == 5, f"{machine.name}: {link_hits(machine)} link runs")

    needle = "refused attach: r in round 1, links inert everywhere"
    cluster = Cluster([Setup(mods=[LINKS_MOD]), Setup(mods=[LINKS_MOD], before=spoil_link)], real=True)
    pointers = [link_pointer(m) for m in cluster.machines]
    settle(cluster, owner="mod_links")
    for machine, pointer in zip(cluster.machines, pointers, strict=True):
        records = machine.records("mod_links")
        expect(needle, len(records) == 1, f"{machine.name} applied {len(records)} times")
        expect(needle, why_of(machine, "mod_links")["count_links"] == "r:fac_b", why_of(machine, "mod_links"))
        machine.real.mr.game_call(pointer, 1, 2)
        expect(needle, link_hits(machine) == 0, f"{machine.name}: a link ran")

    needle = "single player: a linked shared feature is ready and live"
    for mod in (LINKS_MOD, {key: value for key, value in LINKS_MOD.items() if key != "prepare"}):
        cluster = Cluster([Setup(mp=False, mods=[mod])], real=True)
        pointer = link_pointer(cluster.machines[0])
        cluster.run(3)
        machine = cluster.machines[0]
        expect(needle, on_of(machine, "mod_links") == {"count_links"}, f"{why_of(machine, 'mod_links')}")
        if "prepare" in mod:
            machine.real.mr.game_call(pointer, 1, 2)
            expect(needle, link_hits(machine) == 5, f"{link_hits(machine)} link runs")

    needle = "links not attached by prepare: r in round 1"
    bare = {key: value for key, value in LINKS_MOD.items() if key != "prepare"}
    cluster = settle(Cluster([Setup(mods=[bare]), Setup(mods=[bare])], real=True), owner="mod_links")
    for machine in cluster.machines:
        expect(needle, why_of(machine, "mod_links")["count_links"] == "r:fac_a,r:fac_b", why_of(machine, "mod_links"))

    needle = "link attached before agree: r in round 1, never live"
    early = {key: value for key, value in bare.items()} | {"early": ["count_links"]}
    cluster = Cluster([Setup(mods=[early]), Setup(mods=[early])], real=True)
    pointers = [link_pointer(m) for m in cluster.machines]
    settle(cluster, owner="mod_links")
    for machine, pointer in zip(cluster.machines, pointers, strict=True):
        expect(needle, why_of(machine, "mod_links")["count_links"] == "r:fac_a,r:fac_b", why_of(machine, "mod_links"))
        machine.real.mr.game_call(pointer, 1, 2)
    expect(needle, all(link_hits(m) == 5 for m in cluster.machines), "the early links were expected to be live")

    needle = "missing peer: attached links stay inert"
    cluster = Cluster([Setup(mods=[LINKS_MOD]), Setup(mods=[])], real=True)
    pointer = link_pointer(cluster.machines[0])
    settle(cluster, owner="mod_links")
    first = cluster.machines[0]
    expect(needle, why_of(first, "mod_links")["count_links"] == "n:fac_b", why_of(first, "mod_links"))
    first.real.mr.game_call(pointer, 1, 2)
    expect(needle, link_hits(first) == 0, "a link ran with its feature off")


def scenario_host_change_in_round():
    needle = "host change inside an open round: v after the decision"
    cluster = Cluster([Setup(host=True, values={"player_cap": 77}), Setup(delay=30)], lockstep=False)

    def change():
        host = cluster.machines[0]
        host.set_values({"player_cap": 55})
        host.H[b"finalize"]()
        host.collect()

    cluster.at(10, change)
    settle(cluster)
    for machine in cluster.machines:
        records = machine.records(MOD["owner"])
        expect(needle, len(records) == 2, f"{machine.name} applied {len(records)} times")
        expect(
            needle,
            records[0]["values"]["player_cap"] == 77 and records[1]["values"]["player_cap"] == 55,
            f"{[r['values']['player_cap'] for r in records]}",
        )
        expect(needle, shared(records[1]) == ALL_SAME, f"on {shared(records[1])}")


def scenario_popup_close():
    needle = "popup closes only on its own tick button"
    cluster = settle(Cluster([Setup(), Setup(plus=False)]))
    machine = cluster.machines[0]
    name = b"mrp_mod_alpha_message"
    expect(needle, machine.H[b"boxes"][name] is not None, "no popup box")
    machine.call("function() core:get_ui_root():CreateComponent('other_dialog') end")
    machine.H[b"click"](b"other_dialog", b"button_tick")
    expect(needle, machine.H[b"boxes"][name] is not None and len(machine.H[b"destroyed"]) == 0, "closed by another box")
    machine.H[b"click"](name, b"button_cancel")
    expect(needle, machine.H[b"boxes"][name] is not None, "closed by another button")
    machine.H[b"click"](name, b"button_tick")
    expect(
        needle, machine.H[b"boxes"][name] is None and len(machine.H[b"destroyed"]) == 1, "its own tick did not close it"
    )

    needle = "load feature alone: out of sync text"
    cluster = settle(Cluster([Setup(), Setup(states={MOD["owner"]: {"bits": "r"}})]))
    text = cluster.machines[0].popups()[0]
    expect(needle, text.splitlines()[0] == "Alpha Mod: this campaign may go out of sync.", text)
    expect(needle, "Eataine: memreader Plus could not change the game code." in text, text)
    expect(needle, "off for everyone" not in text, text)

    needle = "on reaches apply for every feature, in one order"
    cluster = settle(Cluster([Setup(), Setup(states={MOD["owner"]: {"panel": "r"}}), Setup()]))
    orders = {r["order"] for m in cluster.machines for r in m.records(MOD["owner"])}
    expect(needle, len(orders) == 1 and set(next(iter(orders)).split(",")) == set(MOD["features"]), f"{orders}")
    expect(needle, [m.last()["on"].get("panel") for m in cluster.machines] == [True, None, True], "local panel")


def random_setup(rng, count):
    return [
        Setup(
            delay=rng.choice([0, 0, 3, 12, 40, 62, 75]),
            agree_delay=rng.choice([0, 0, 0, 2, 9, 30]),
            host=rng.random() < 0.3,
            synced=rng.random() < 0.8,
            values={
                "player_cap": rng.randint(1, 200),
                "follow": rng.random() < 0.5,
                "overrides": big_text(rng.choice([0, 0, 0, 900, 6000]), rng.randint(1, 99)),
            },
            mods=[] if rng.random() < 0.05 else None,
            plus=rng.random() > 0.04,
            states={MOD["owner"]: {"caps": rng.choice([True] * 8 + ["s", "r"])}},
            fail=[rng.choice([{}] * 6 + [{"caps": "no"}, "raise"]) for _ in range(2)],
            silent=rng.random() < 0.03,
        )
        for _ in range(count)
    ]


def scenario_random(seeds):
    needle = "randomised seeds: identical apply logs"
    started = time.perf_counter()
    for seed in range(seeds):
        rng = random.Random(seed)
        setups = random_setup(rng, rng.choice([2, 3, 4]))
        cluster = Cluster(
            setups,
            latency=rng.randint(1, 3),
            lockstep=rng.random() < 0.6,
            seed=seed,
            drop=rng.choice([0, 0, 0.04]),
        )
        for index, setup in enumerate(setups):
            if not setup.synced:
                cluster.at(rng.randint(5, 50), lambda m=cluster.machines[index]: m.set_synced(True))
        cluster.run(ROUND_TICKS + 60)
        positions = all(m.setup.agree_delay == 0 for m in cluster.machines)
        logs = [m.log(positions=positions) for m in cluster.participants()]
        if not expect(
            needle, all(log == logs[0] for log in logs), f"seed {seed}: logs differ {[len(x) for x in logs]}"
        ):
            break
    print(f"    {seeds} seeds in {time.perf_counter() - started:.0f} s")


NEEDLES = """
same apply everywhere
no apply before all reports
host values win
no host: first human
two host claims: first in order
comma decimal mark: fractions agreed
synced: host waits for s
stale host claim: synced values used
mct missing on host, client first: off m
plus blocked: off at once
site missing: one feature off
schema mismatch: all off
differing option keys: same values and why everywhere
mod missing: off after t
foreign protocol: off at once
garbled piece: off at once
late report opens round 2
t then report: converges
timer runs while loading: converges
intra-tick shuffle
apply inside a hooked call: off for all
apply failure: round 2 without it
apply raises: all off
8 rounds cap
host change: v only when values change
client finalize ignored
load: fresh round 1
leftover from earlier campaign removed
load-time write kept
chunks: every message <= 255, pieces in order
overrides store from a real races page
8 machines: messages per round <= 8 + value parts
big body: 150 KB intact on 2 and 4 machines, interleaved with another owner
big body: sending is paced
big body: progress extends the timeout
tick budget: bodies of 13 KB and 150 KB arrive intact within the budget
tick budget: a burst without a window overflows the packet
tick budget: a stall of any length never puts more than the window in flight
tick budget: lost pieces end in the timeout for everyone, never in a burst
tick budget: no tick carries more than half of the packet, whatever the traffic
stalled big body: times out without progress
over the maximum: z on every machine
too many pieces announced: off at once
too-large update: the host gets one popup, the others keep the settings
sp: no UITrigger listener, no message, apply on finalize
gate: set before agreement refused, entry still found
gate: off feature refused
ready: read-only, no mark_missing
remove_feature restores held bytes
popup: lines per player and reason, shown on the blocked machine, not for a transient round
popup closes only on its own tick button
load feature alone: out of sync text
on reaches apply for every feature, in one order
message before agree is replayed: one decision
foreign message before agree: replayed as another version
load listener: one listener, removed in single player
load listener: only where core exists and the mode is a campaign
single player: one decision line in the mod log
mod files load: no Plus global or package key shares a name with one
agree after a failed host search keeps the old host
agree: pcall and wrapper levels find the env with core
agree: the loader env is the last resort
failed probe: logging, listeners and live updates survive
add_listener failure does not block the later listener
host MCT change in the real MP order: one v, applied once everywhere
prepare: links attached before the first report, inert until on
refused attach: r in round 1, links inert everywhere
links not attached by prepare: r in round 1
link attached before agree: r in round 1, never live
late agree: a round decided while replaying is logged
missing peer: attached links stay inert
host change inside an open round: v after the decision
false, zero and empty options reach every machine
single player: a linked shared feature is ready and live
loader twice: one agree instance, state kept
dll blocked: the loader asks for the one Plus popup
blocked: one Plus popup per session, none in multiplayer
agree.lua error: DLL still loads
api errors: wrong types raise
campaign only and one call per owner
agree finds the game environment of its caller
randomised seeds: identical apply logs
""".strip().splitlines()

SCENARIOS = [
    scenario_values,
    scenario_comma_locale,
    scenario_false_values,
    scenario_no_early_apply,
    scenario_synced,
    scenario_plus_blocked,
    scenario_popup_lines,
    scenario_site_missing,
    scenario_versions,
    scenario_game_environment,
    scenario_majority,
    scenario_missing_mod,
    scenario_late,
    scenario_shuffle,
    scenario_apply_failures,
    scenario_updates,
    scenario_chunks,
    scenario_big_bodies,
    scenario_tick_budget,
    scenario_over_maximum,
    scenario_single_player,
    scenario_gate,
    scenario_leftovers,
    scenario_ready_and_remove,
    scenario_api,
    scenario_loader,
    scenario_blocked_popup,
    scenario_listen_env,
    scenario_early_messages,
    scenario_host_kept,
    scenario_caller_levels,
    scenario_failed_probe,
    scenario_mct_order,
    scenario_prepare_links,
    scenario_host_change_in_round,
    scenario_popup_close,
]


def main():
    parser = argparse.ArgumentParser(description="Offline sim of Plus's agree.lua.")
    parser.add_argument("--seeds", type=int, default=1000)
    parser.add_argument("--only", help="part of a scenario name")
    args = parser.parse_args()
    for scenario in SCENARIOS:
        if args.only and args.only not in scenario.__name__:
            continue
        started = time.perf_counter()
        scenario()
        print(f"  {scenario.__name__}: {time.perf_counter() - started:.1f} s")
    if not args.only:
        scenario_random(args.seeds)
    print()
    for needle in NEEDLES:
        if args.only and needle not in passed:
            continue
        print(needle if passed.get(needle) else f"FAILED: {needle}")
    if failures or (not args.only and not all(passed.get(needle) for needle in NEEDLES)):
        print(f"\n{len(failures)} checks failed")
        sys.exit(1)
    print("\nmp_agree_sim: all needles printed")


if __name__ == "__main__":
    main()
