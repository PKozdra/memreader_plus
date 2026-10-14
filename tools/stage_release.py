import argparse
import hashlib
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RELEASE_FILES = ("loader", "agree", "sites", "twui", "locale_guard", "file_edit_switch")
BOOT = Path("script") / "_lib" / "mod" / "!memreader_plus_boot.lua"
BOOT_SHA256 = "383eed03f9c49c61cb7988ded5e14fa0186174deba94817341344f73df2230e0"
PUBLISHED = Path("tools") / "published_releases.txt"
SHIM = Path("tools") / "loader_shim.lua"
VERSION = re.compile(r"project\(memreader_plus VERSION (\S+)")
THREE_INTEGERS = re.compile(r"\d+\.\d+\.\d+")


def release_id(root: Path) -> str:
    match = VERSION.search((root / "CMakeLists.txt").read_text(encoding="utf-8"))
    if not match or not THREE_INTEGERS.fullmatch(match.group(1)):
        raise SystemExit("CMakeLists.txt: the project version must be three integers like 0.12.0")
    return match.group(1).replace(".", "_")


def sha256(path: Path, equal_line_endings: bool = False) -> str:
    data = path.read_bytes()
    if equal_line_endings:
        data = data.replace(b"\r\n", b"\n")
    return hashlib.sha256(data).hexdigest()


def check_boot(staged_boot: Path) -> None:
    if sha256(staged_boot, equal_line_endings=True) != BOOT_SHA256:
        raise SystemExit(
            f"{BOOT} differs from the frozen boot (BOOT_SHA256): to change it, ship a new file name on purpose"
        )


def check_published(root: Path, target: Path) -> None:
    release = release_id(root)
    published = (root / PUBLISHED).read_text(encoding="utf-8").splitlines()
    hashes = dict(line.split() for line in published if line.strip())
    bin_hash = sha256(target / "script" / "memreader_plus" / release / "bin.lua")
    if release in hashes and hashes[release] != bin_hash:
        raise SystemExit(
            f"release {release} was published with other bin.lua bytes: raise the version in CMakeLists.txt"
        )


def stage(root: Path, target: Path) -> str:
    release = release_id(root)
    plus = target / "script" / "memreader_plus"
    shutil.copytree(root / "script", target / "script")
    check_boot(target / BOOT)
    (plus / release).mkdir()
    for name in RELEASE_FILES:
        (plus / f"{name}.lua").replace(plus / release / f"{name}.lua")
    shutil.copyfile(root / SHIM, plus / "loader.lua")
    (plus / "releases").mkdir()
    (plus / "releases" / f"{release}.lua").write_text(f"return '{release}'\n", encoding="utf-8", newline="\n")
    return release


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Stage the pack folder: one folder per release, the shim, the marker and the boot."
    )
    parser.add_argument("target", type=Path, help="empty folder that becomes the pack contents")
    parser.add_argument("--root", type=Path, default=ROOT, help="the memreader_plus source folder")
    parser.add_argument(
        "--check-published", action="store_true", help="check a staged pack that has its bin.lua, stage nothing"
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.check_published:
        check_published(args.root, args.target)
    else:
        print(stage(args.root, args.target))


if __name__ == "__main__":
    main()
