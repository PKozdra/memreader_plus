import argparse
import importlib.util
import re
import time
from pathlib import Path

TOOLS = Path(__file__).resolve().parent.parent / "tools"
PLUS = "script\\memreader_plus\\"
MARKER = re.compile(r"script\\memreader_plus\\releases\\(\d+_\d+_\d+)\.lua")
RELEASE_ID = re.compile(r"\d+_\d+_\d+")


def load_build_pack():
    spec = importlib.util.spec_from_file_location("build_pack", TOOLS / "build_pack.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def release_of(files: list[tuple[str, bytes]]) -> str:
    found = [match.group(1) for path, _ in files if (match := MARKER.fullmatch(path))]
    if len(found) != 1:
        raise SystemExit(f"the pack must hold exactly one release marker, found {len(found)}")
    return found[0]


def rename_release(files: list[tuple[str, bytes]], old: str, new: str) -> list[tuple[str, bytes]]:
    folder = f"{PLUS}{old}\\"
    marker = f"{PLUS}releases\\{old}.lua"
    renamed = []
    for path, data in files:
        if path.startswith(folder):
            path = f"{PLUS}{new}\\{path[len(folder) :]}"
        elif path == marker:
            path = f"{PLUS}releases\\{new}.lua"
            data = f"return '{new}'\n".encode()
        renamed.append((path, data))
    return sorted(renamed, key=lambda file: file[0].lower())


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Copy a staged Plus pack under another release id: only the release folder and its marker change."
    )
    parser.add_argument("source", type=Path, help="pack built by build.ps1")
    parser.add_argument("output", type=Path, help="pack to write")
    parser.add_argument("--id", required=True, help="new release id like 0_11_90")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if not RELEASE_ID.fullmatch(args.id):
        raise SystemExit("--id must be three integers joined by underscores, like 0_11_90")
    build_pack = load_build_pack()
    files = build_pack.read_pack(args.source.read_bytes())
    old = release_of(files)
    if old == args.id:
        raise SystemExit(f"the pack already holds release {old}")
    renamed = rename_release(files, old, args.id)
    temporary = args.output.with_name(args.output.name + ".tmp")
    temporary.write_bytes(build_pack.pack_bytes(renamed, int(time.time())))
    temporary.replace(args.output)
    if build_pack.read_pack(args.output.read_bytes()) != renamed:
        raise SystemExit(f"{args.output}: contents read back differ")
    print(f"{args.output}: release {old} -> {args.id}, {len(renamed)} files")


if __name__ == "__main__":
    main()
