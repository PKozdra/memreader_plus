import argparse
import struct
import sys
from pathlib import Path

from steam_location import warhammer_3_dir

ROOT = Path(__file__).resolve().parent.parent
DEF = ROOT / "src" / "warhammer3.def"
DEF_HEADER = ("LIBRARY", "Warhammer3.exe", "EXPORTS")

Section = tuple[int, int, int, int]


def u16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def sections(exe: bytes, pe: int) -> list[Section]:
    count = u16(exe, pe + 6)
    first = pe + 24 + u16(exe, pe + 20)
    return [struct.unpack_from("<IIII", exe, first + 40 * i + 8) for i in range(count)]


def file_offset(exe_sections: list[Section], rva: int) -> int:
    for size, address, _, pointer in exe_sections:
        if address <= rva < address + size:
            return rva - address + pointer
    raise ValueError(f"RVA {rva:#x} is outside every section")


def export_names(exe: bytes) -> list[str]:
    pe = u32(exe, 0x3C)
    optional = pe + 24
    directories = optional + (112 if u16(exe, optional) == 0x20B else 96)
    exe_sections = sections(exe, pe)
    exports = file_offset(exe_sections, u32(exe, directories))
    names = file_offset(exe_sections, u32(exe, exports + 32))
    result = []
    for i in range(u32(exe, exports + 24)):
        start = file_offset(exe_sections, u32(exe, names + 4 * i))
        result.append(exe[start : exe.index(b"\0", start)].decode("ascii"))
    return result


def def_text(names: list[str]) -> str:
    return "LIBRARY Warhammer3.exe\nEXPORTS\n" + "".join(f"\t{name}\n" for name in names)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Check or regenerate src/warhammer3.def from Warhammer3.exe.")
    parser.add_argument("exe", nargs="?", type=Path, help="Warhammer3.exe (default: the Steam install)")
    parser.add_argument("--write", action="store_true", help="rewrite src/warhammer3.def when it differs")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    exe_path = args.exe or warhammer_3_dir() / "Warhammer3.exe"
    names = [name for name in export_names(exe_path.read_bytes()) if name.startswith("lua")]
    expected = def_text(names)
    current = DEF.read_text(encoding="ascii") if DEF.exists() else ""
    def_name = DEF.relative_to(ROOT)

    if current == expected:
        print(f"{def_name} matches {exe_path.name}: {len(names)} lua exports")
        return 0
    if args.write:
        DEF.write_text(expected, encoding="ascii", newline="\n")
        print(f"{def_name} written: {len(names)} lua exports from {exe_path}")
        return 0

    old = set(current.split()) - set(DEF_HEADER)
    new = set(names)
    for name in sorted(new - old):
        print(f"+ {name}")
    for name in sorted(old - new):
        print(f"- {name}")
    print(f"{def_name} differs from {exe_path.name}; rerun with --write to update it")
    return 1


if __name__ == "__main__":
    sys.exit(main())
