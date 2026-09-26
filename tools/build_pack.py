import argparse
import struct
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SOURCE = ROOT / "dist" / "pack"
DEFAULT_PACK = ROOT.parent / "memreader_plus.pack"
PREAMBLE = b"PFH5"
MOD_PACK = 3
HEADER = struct.Struct("<4s6I")
INDEX_ENTRY = struct.Struct("<IB")

PackFile = tuple[str, bytes]


def collect(source: Path) -> list[PackFile]:
    files = [
        (str(path.relative_to(source)).replace("/", "\\"), path.read_bytes())
        for path in source.rglob("*")
        if path.is_file()
    ]
    return sorted(files, key=lambda file: file[0].lower())


def pack_bytes(files: list[PackFile], timestamp: int) -> bytes:
    index = b"".join(INDEX_ENTRY.pack(len(data), 0) + path.encode("utf-8") + b"\0" for path, data in files)
    header = HEADER.pack(PREAMBLE, MOD_PACK, 0, 0, len(files), len(index), timestamp)
    return header + index + b"".join(data for _, data in files)


def read_pack(pack: bytes) -> list[PackFile]:
    preamble, pack_type, dependency_count, dependency_size, file_count, index_size, _ = HEADER.unpack_from(pack)
    if preamble != PREAMBLE or pack_type != MOD_PACK or dependency_count or dependency_size:
        raise ValueError("not a plain PFH5 mod pack without dependencies")

    position = HEADER.size
    entries = []
    for _ in range(file_count):
        size, compressed = INDEX_ENTRY.unpack_from(pack, position)
        if compressed:
            raise ValueError("compressed files are not supported")
        path_start = position + INDEX_ENTRY.size
        path_end = pack.index(b"\0", path_start)
        entries.append((pack[path_start:path_end].decode("utf-8"), size))
        position = path_end + 1
    if position != HEADER.size + index_size:
        raise ValueError("the index size in the header does not match the index")

    files = []
    for path, size in entries:
        files.append((path, pack[position : position + size]))
        position += size
    if position != len(pack):
        raise ValueError("the pack size does not match its index")
    return files


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build an uncompressed WH3 mod pack (PFH5) from a folder.")
    parser.add_argument("source", nargs="?", type=Path, default=DEFAULT_SOURCE, help="folder with the pack contents")
    parser.add_argument("pack", nargs="?", type=Path, default=DEFAULT_PACK, help="pack file to write")
    parser.add_argument("--timestamp", type=int, default=int(time.time()), help="header timestamp (Unix seconds)")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    files = collect(args.source)
    temporary = args.pack.with_name(args.pack.name + ".tmp")
    temporary.write_bytes(pack_bytes(files, args.timestamp))
    temporary.replace(args.pack)
    if read_pack(args.pack.read_bytes()) != files:
        raise SystemExit(f"{args.pack}: contents read back differ from {args.source}")

    print(f"{args.pack}: {len(files)} files, {args.pack.stat().st_size} bytes, read back identical to {args.source}")
    for path, data in files:
        print(f"  {path} ({len(data)} bytes)")


if __name__ == "__main__":
    main()
