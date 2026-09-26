import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = ROOT / "dist" / "pack" / "script" / "memreader_plus" / "bin.lua"
MODULE = "twwh3-memreader_plus"
ESCAPES = {0x0A: b"\\n", 0x0D: b"\\r", 0x22: b'\\"', 0x5C: b"\\\\"}


def lua_string(data: bytes) -> bytes:
    out = bytearray(b'"')
    for byte in data:
        if byte in ESCAPES:
            out += ESCAPES[byte]
        elif byte <= 127:
            out.append(byte)
        else:
            out += b"\\%d" % byte
    out += b'"'
    return bytes(out)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Embed the DLL into bin.lua for the loader.")
    parser.add_argument("dll", type=Path, help="the built memreader_plus.dll")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="bin.lua to write")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    data = args.dll.read_bytes()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(b'return { module = "' + MODULE.encode() + b'", data = ' + lua_string(data) + b" }\n")
    print(f"{args.out}: {MODULE}, {len(data)} bytes")


if __name__ == "__main__":
    main()
