#!/usr/bin/env python3
"""Run widget snapshot regressions without launching an app or Simulator."""
from pathlib import Path
import subprocess
import tempfile
import random
import struct
import zlib


def sixteen_bit_sheet():
    width, height = 1536, 2288
    random_bytes = random.Random(7)
    rows = []
    for row in range(height):
        if row < 208:
            frame = bytearray(random_bytes.randbytes(192 * 8))
            if row == 0:
                # Opaque red, half-transparent green, then fully transparent.
                frame[:24] = struct.pack(">12H", 65535, 0, 0, 65535, 0, 65535, 0, 32768, 65535, 65535, 65535, 0)
            rows.append(b"\0" + frame + bytes((width - 192) * 8))
        else:
            rows.append(b"\0" + bytes(width * 8))

    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 16, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b""))


def main():
    repo = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="doboo-widget-tests-") as temporary:
        executable = Path(temporary) / "widget-tests"
        fixture = Path(temporary) / "rgba16.png"
        fixture.write_bytes(sixteen_bit_sheet())
        command = ["swiftc", "-swift-version", "6", "-parse-as-library",
                   "Sources/Core/CharacterPack.swift", "Sources/Core/SpriteFrame.swift",
                   "Shared/WatchWidgetSnapshot.swift", "Widgets/Tests/WatchWidgetSnapshotTests.swift",
                   "-o", str(executable)]
        try:
            subprocess.run(command, cwd=repo, check=True)
            subprocess.run([str(executable), str(fixture)], cwd=repo, check=True)
        except subprocess.CalledProcessError as error:
            return error.returncode if error.returncode > 0 else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
