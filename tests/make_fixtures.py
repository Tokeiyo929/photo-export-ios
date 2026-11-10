#!/usr/bin/env python3
"""给模拟器相册注入真实测试数据：纯 stdlib 生成两张小 PNG，
CI 里 xcrun simctl addmedia 注入后，-autoSmoke 的 02-export 就有一场真实小导出可跑。
本地可运行验证：python tests/make_fixtures.py [输出目录]"""
import struct
import sys
import zlib
from pathlib import Path


def png_chunk(tag: bytes, data: bytes) -> bytes:
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def write_png(path: Path, width: int, height: int, rgb: tuple) -> None:
    # 每行前置 filter byte 0
    row = b"\x00" + bytes(rgb) * width
    raw = row * height
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(raw, 9))
        + png_chunk(b"IEND", b"")
    )


def main() -> int:
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent / "fixtures"
    out_dir.mkdir(parents=True, exist_ok=True)
    fixtures = [
        ("pe-fixture-red-64.png", 64, 64, (220, 40, 40)),
        ("pe-fixture-blue-48.png", 48, 48, (40, 90, 220)),
    ]
    for name, width, height, rgb in fixtures:
        target = out_dir / name
        write_png(target, width, height, rgb)
        print(f"生成 {target} ({target.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
