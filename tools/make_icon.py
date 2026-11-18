#!/usr/bin/env python3
"""Generate the 1024x1024 app icon as a PNG, with no third-party libraries.

The icon is a dark blue gradient with a white Wi-Fi style glyph.
"""
import math
import os
import struct
import zlib

SIZE = 1024
CENTER_X = SIZE / 2
CENTER_Y = 690.0


def smoothstep(edge0: float, edge1: float, value: float) -> float:
    if edge0 == edge1:
        return 0.0
    t = (value - edge0) / (edge1 - edge0)
    t = max(0.0, min(1.0, t))
    return t * t * (3.0 - 2.0 * t)


def glyph_coverage(x: float, y: float) -> float:
    dx = x - CENTER_X
    dy = CENTER_Y - y
    distance = math.hypot(dx, dy)

    coverage = 0.0

    # Center dot.
    dot = 86.0
    coverage = max(coverage, smoothstep(dot + 1.2, dot - 1.2, distance))

    # Three arcs opening upward.
    angle = math.degrees(math.atan2(dy, dx))
    if 30.0 <= angle <= 150.0:
        for radius in (152.0, 272.0, 392.0):
            half = 26.0
            edge = abs(distance - radius)
            coverage = max(coverage, smoothstep(half + 1.2, half - 1.2, edge))

    return coverage


def build_rows():
    rows = []
    for y in range(SIZE):
        row = bytearray()
        for x in range(SIZE):
            # Diagonal gradient with a soft glow toward the top.
            tx = x / (SIZE - 1)
            ty = y / (SIZE - 1)
            mix = min(1.0, max(0.0, 0.65 * tx + 0.35 * ty))
            r = int(8 + 10 * mix)
            g = int(16 + 38 * mix)
            b = int(30 + 74 * mix)

            # Soft radial glow behind the glyph.
            dx = x - CENTER_X
            dy = y - CENTER_Y
            glow = max(0.0, 1.0 - math.hypot(dx, dy) / 470.0)
            glow = glow * glow * 0.22
            r = int(r + (24 - r) * glow)
            g = int(g + (96 - g) * glow)
            b = int(b + (170 - b) * glow)

            coverage = glyph_coverage(x, y)
            if coverage > 0.0:
                r = int(r + (236 - r) * coverage)
                g = int(g + (244 - g) * coverage)
                b = int(b + (255 - b) * coverage)

            row += bytes((min(255, r), min(255, g), min(255, b)))
        rows.append(row)
    return rows


def chunk(tag: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + tag
        + payload
        + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
    )


def write_png(path: str, rows) -> None:
    raw = bytearray()
    for row in rows:
        raw.append(0)
        raw += row

    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)
    data = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as handle:
        handle.write(data)


def main() -> None:
    base = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    output_dir = os.path.join(base, "LocalAPIBridge", "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(output_dir, exist_ok=True)
    output = os.path.join(output_dir, "AppIcon-1024.png")
    write_png(output, build_rows())
    print(f"wrote {output} ({os.path.getsize(output)} bytes)")


if __name__ == "__main__":
    main()