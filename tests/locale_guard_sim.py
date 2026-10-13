"""Offline sim of locale_guard.lua: the save side and the load side of a campaign manager under a decimal comma.

Run: python locale_guard_sim.py
The fake campaign manager writes tables the way CA's table.tostring does (bracketed keys, numbers through tostring)
and reads them back with the real loadstring of Lua 5.1, so a comma in a number really splits the table.
The fake locale only changes how tostring writes a number.
"""

import locale
import sys
from pathlib import Path

from lupa.lua51 import LuaRuntime

GUARD = (Path(__file__).resolve().parent.parent / "script" / "memreader_plus" / "locale_guard.lua").read_text(
    encoding="utf-8"
)

WORLD = r"""
local locale = 'C'
local real_tostring = tostring
tostring = function(value)
	local text = real_tostring(value)
	if type(value) == 'number' and locale ~= 'C' then return (text:gsub('%.', ',')) end
	return text
end
os = { setlocale = function(name, category)
	if name ~= nil then locale = name end
	return locale
end }

local function dump(value)
	if type(value) == 'table' then
		local parts = {}
		for key, item in pairs(value) do
			local label = type(key) == 'string' and ('["' .. key .. '"]') or ('[' .. tostring(key) .. ']')
			parts[#parts + 1] = label .. '=' .. dump(item)
		end
		return '{' .. table.concat(parts, ',') .. '}'
	end
	if type(value) == 'string' then return '"' .. value .. '"' end
	return tostring(value)
end

stored = {}
fail_save = false
cm = {}
function cm:process_table_save(tab)
	return 'return ' .. dump(tab)
end
function cm:saving_game(context)
	if fail_save then error('save failed') end
	stored.table = self:process_table_save(context.table)
	stored.text = context.text
end
function cm:load_named_string(name, default, context)
	return stored[name] or default
end
function cm:load_named_value(name, default, context)
	if type(default) == 'table' then
		local text = self:load_named_string(name, '', context)
		local chunk = loadstring(text)
		if not chunk then error('bad table text') end
		return chunk()
	end
	return self:load_named_string(name, default, context)
end

function set_locale(name) locale = name end
function current_locale() return locale end
"""

passed = []
failed = []


def check(name, condition, detail=""):
    (passed if condition else failed).append(name)
    print(("  ok   " if condition else "  FAIL ") + name + ("" if condition else f" {detail}"))


def runtime():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(WORLD)
    guard = lua.eval("function(src) return assert(loadstring(src))() end")(GUARD)
    return lua, guard


def case_save_under_comma():
    lua, guard = runtime()
    lua.eval("function(guard) return guard.install(cm) end")(guard)
    lua.execute("set_locale('Polish_Poland.1250')")
    lua.execute("options = { size = { setting = 1.75 }, cap = { setting = 0.25, is_locked = true } }")
    lua.execute("cm:saving_game({ table = { saved_mods = { mod = { options = options } } }, text = 'x' })")
    text = lua.eval("stored.table")
    check(
        "save: numbers are written with a dot under a comma locale",
        "1.75" in text and "0.25" in text and "," + "75" not in text,
        text,
    )
    check(
        "save: the locale is back to the player's after the save", lua.eval("current_locale()") == "Polish_Poland.1250"
    )
    values = lua.eval("(loadstring(stored.table))().saved_mods.mod.options")
    check(
        "save: the table reads back exactly",
        values["size"]["setting"] == 1.75 and values["cap"]["setting"] == 0.25 and values["cap"]["is_locked"] is True,
    )


def case_unguarded_baseline():
    lua, _ = runtime()
    lua.execute("set_locale('Polish_Poland.1250')")
    lua.execute("cm:saving_game({ table = { options = { size = { setting = 1.75 } } }, text = 'x' })")
    size = lua.eval("(loadstring(stored.table))().options.size.setting")
    check("baseline: without the guard 1.75 loads as 1", size == 1, size)


def case_save_error_restores_locale():
    lua, guard = runtime()
    lua.eval("function(guard) return guard.install(cm) end")(guard)
    lua.execute("set_locale('Polish_Poland.1250'); fail_save = true")
    ok = lua.eval("(pcall(cm.saving_game, cm, { table = {}, text = 'x' }))")
    check(
        "save: an error is passed on and the locale still restored",
        ok is False and lua.eval("current_locale()") == "Polish_Poland.1250",
    )


def case_load_old_save():
    lua, guard = runtime()
    lua.eval("function(guard) return guard.install(cm) end")(guard)
    old = (
        'return {["saved_mods"]={["mod"]={["options"]={["size"]={["setting"]=1,75},'
        '["cap"]={["setting"]=0,25,["is_locked"]=true,["lock_reason"]="x=9,5,["},'
        '["big"]={["setting"]=-2,5e+20},["whole"]={["setting"]=3}}}}}'
    )
    lua.eval("function(text) stored.mct = text end")(old)
    options = lua.eval("cm:load_named_value('mct', {}, nil).saved_mods.mod.options")
    check(
        "load: a comma number from an old save is repaired",
        options["size"]["setting"] == 1.75 and options["cap"]["setting"] == 0.25,
    )
    check(
        "load: exponent, negative and whole numbers survive",
        options["big"]["setting"] == -2.5e20 and options["whole"]["setting"] == 3,
    )
    check("load: text inside a string is left alone", options["cap"]["lock_reason"] == "x=9,5,[")
    check("load: no stray list entries are left", options["size"][1] is None)


def case_string_values_untouched():
    lua, guard = runtime()
    lua.eval("function(guard) return guard.install(cm) end")(guard)
    lua.execute("stored.note = 'a=1,75,[b'")
    note = lua.eval("cm:load_named_value('note', '', nil)")
    check("load: a plain string value is not repaired", note == "a=1,75,[b", note)
    lua.execute("stored.mct = 'return {'")
    ok = lua.eval("(pcall(cm.load_named_value, cm, 'mct', {}, nil))")
    note = lua.eval("cm:load_named_value('note', '', nil)")
    check("load: a failed table load does not leave the repair armed", ok is False and note == "a=1,75,[b", note)


def case_install_once():
    lua, guard = runtime()
    install = lua.eval("function(guard) return guard.install(cm) end")
    first = install(guard)
    lua.execute("wrapped = cm.saving_game")
    second = install(guard)
    same = lua.eval("wrapped == cm.saving_game")
    check("install: the second copy does nothing", first is True and second is False and same is True)
    check("install: no manager, no error", lua.eval("function(guard) return guard.install(nil) end")(guard) is False)


def case_repair_is_anchored():
    lua, guard = runtime()
    repair = lua.eval("function(guard, text) return guard.repair(text) end")
    unchanged = (
        "return {n=1,2,3}",
        "return {n=1,2}",
        "return {[1]=1,2,3}",
        'return {["a"]=1,75 ,["b"]=2}',
        'return {["a"]=1,7x}',
    )
    check("repair: hand-written lists are left unchanged", all(repair(guard, text) == text for text in unchanged))
    fixed = repair(guard, 'return {["a"]=1,75,["b"]=2,5}')
    check("repair: CA shaped values are repaired", fixed == 'return {["a"]=1.75,["b"]=2.5}', fixed)
    fixed = repair(guard, "return {[1,5]=3,[2,25]=4,[-1,5]=5}")
    check("repair: comma numeric keys are repaired", fixed == "return {[1.5]=3,[2.25]=4,[-1.5]=5}", fixed)
    check("repair: the text keeps its length", len(fixed) == len("return {[1,5]=3,[2,25]=4,[-1,5]=5}"))


def case_load_real_comma_output():
    lua, guard = runtime()
    lua.execute("set_locale('Polish_Poland.1250')")
    lua.execute(
        "cm:saving_game({ table = { saved_mods = { mod = { list = { 1.5, 2.25, 3 }, "
        "options = { size = { setting = 1.75 }, tiny = { setting = 0.25 }, big = { setting = -2.5e-05 }, "
        "note = 'a=1.5,[b', [2.5] = 'x' } } } }, text = 'x' })"
    )
    written = lua.eval("stored.table")
    lua.execute("set_locale('C')")
    lua.eval("function(guard) return guard.install(cm) end")(guard)
    lua.execute("stored.mct = stored.table")
    data = lua.eval("cm:load_named_value('mct', {}, nil).saved_mods.mod")
    options = data["options"]
    check("load: the written text really holds commas", "1,75" in written and "2,5" in written, written)
    check(
        "load: every comma number of real output comes back exact",
        options["size"]["setting"] == 1.75
        and options["tiny"]["setting"] == 0.25
        and options["big"]["setting"] == -2.5e-05
        and options[2.5] == "x",
    )
    check(
        "load: positional list and string value are exact",
        data["list"][1] == 1.5 and data["list"][2] == 2.25 and data["list"][3] == 3 and options["note"] == "a=1.5,[b",
    )


def case_serialise_outside_save():
    lua, guard = runtime()
    lua.execute("set_locale('Polish_Poland.1250')")
    broken = lua.eval("(loadstring(cm:process_table_save({ x = 1.75 })))().x")
    lua.eval("function(guard) return guard.install(cm) end")(guard)
    text = lua.eval("cm:process_table_save({ x = 1.75, y = 0.25 })")
    values = lua.eval("function(t) return loadstring(t)() end")(text)
    check("sync: without the guard a payload splits", broken == 1, broken)
    check("sync: the payload is written with a dot", "1.75" in text and "0.25" in text, text)
    check("sync: the payload reads back exact", values["x"] == 1.75 and values["y"] == 0.25)
    check("sync: the locale is back after the payload", lua.eval("current_locale()") == "Polish_Poland.1250")
    lua.execute("set_locale('C')")
    check(
        "sync: under the C locale nothing changes", lua.eval("cm:process_table_save({ x = 2 })") == 'return {["x"]=2}'
    )


def case_serialise_error_restores_locale():
    lua, guard = runtime()
    lua.execute("function cm:process_table_save(tab) error('boom') end")
    lua.eval("function(guard) return guard.install(cm) end")(guard)
    lua.execute("set_locale('Polish_Poland.1250')")
    ok = lua.eval("(pcall(cm.process_table_save, cm, {}))")
    check(
        "sync: a serialiser error is passed on and the locale restored",
        ok is False and lua.eval("current_locale()") == "Polish_Poland.1250",
    )


def case_missing_setlocale():
    lua, guard = runtime()
    lua.execute("saved_os = os; os = nil")
    refused = lua.eval("function(guard) return guard.install(cm) end")(guard)
    check("setlocale: no os table, install refuses", refused is False)
    lua.execute("os = { }")
    refused = lua.eval("function(guard) return guard.install(cm) end")(guard)
    check("setlocale: no os.setlocale, install refuses", refused is False)
    lua.execute("os = saved_os")
    check("setlocale: a refused install leaves the marker unset", lua.eval("cm.numeric_locale_safe") is None)


def case_setlocale_breaks_after_install():
    for name, body in (
        ("removed", "os = nil"),
        ("replaced by one that errors", "os = { setlocale = function() error('nope') end }"),
        ("replaced by one that returns nil", "os = { setlocale = function() return nil end }"),
    ):
        lua, guard = runtime()
        lua.eval("function(guard) return guard.install(cm) end")(guard)
        lua.execute("set_locale('Polish_Poland.1250'); saved_os = os; " + body)
        lua.execute("cm:saving_game({ table = { x = 1 }, text = 'saved' })")
        saved = lua.eval("stored.text")
        lua.execute("local t = cm:process_table_save({ x = 1 }); stored.sync = t")
        sync = lua.eval("stored.sync")
        check(f"setlocale {name}: the save still runs and the sync still returns", saved == "saved" and "x" in sync)


def case_receive_dot_payload_under_real_comma_locale():
    try:
        locale.setlocale(locale.LC_NUMERIC, "Polish_Poland.1250")
    except locale.Error:
        print("  skip receive: the Polish locale is not installed here")
        return
    try:
        lua = LuaRuntime()
        mark = lua.eval("tostring(1.75)")
        plain = lua.eval("tonumber('1.75')")
        x = lua.eval("(loadstring('return {x=1.75, y=0.25, z=-2.5e-05}'))().x")
        z = lua.eval("(loadstring('return {x=1.75, y=0.25, z=-2.5e-05}'))().z")
        check("receive: the real Lua 5.1 is in a comma locale", mark == "1,75" and plain is None, mark)
        check("receive: loadstring of a dot payload still reads fractions", x == 1.75 and z == -2.5e-05, x)
    finally:
        locale.setlocale(locale.LC_NUMERIC, "C")


def main():
    for case in (
        case_save_under_comma,
        case_unguarded_baseline,
        case_save_error_restores_locale,
        case_load_old_save,
        case_string_values_untouched,
        case_install_once,
        case_repair_is_anchored,
        case_load_real_comma_output,
        case_serialise_outside_save,
        case_serialise_error_restores_locale,
        case_missing_setlocale,
        case_setlocale_breaks_after_install,
        case_receive_dot_payload_under_real_comma_locale,
    ):
        case()
    print(f"\nlocale_guard_sim: {len(passed)} passed, {len(failed)} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
