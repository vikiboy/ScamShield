#!/usr/bin/env python3
"""Render the ScamShield app icons as opaque PNGs (stdlib only).

    python3 web/dev/make_icons.py

Writes web/icons/icon-{180,192,512}.png and icon-maskable-512.png. The shield
geometry matches web/icons/icon.svg; it stays inside the 80% maskable safe zone.
"""

import math
import os
import struct
import zlib

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "icons")

TOP = (0x34, 0x7A, 0xE8)  # gradient, top of icon
BOTTOM = (0x1D, 0x46, 0xA8)  # gradient, bottom of icon
WHITE = (0xFF, 0xFF, 0xFF)

# Shield outline in unit coordinates: start point, then cubic segments ("C") and lines ("L").
SHIELD = [
    (0.5, 0.18),
    ("C", (0.60, 0.24), (0.70, 0.26), (0.77, 0.26)),
    ("L", (0.77, 0.48)),
    ("C", (0.77, 0.66), (0.66, 0.77), (0.5, 0.84)),
    ("C", (0.34, 0.77), (0.23, 0.66), (0.23, 0.48)),
    ("L", (0.23, 0.26)),
    ("C", (0.30, 0.26), (0.40, 0.24), (0.5, 0.18)),
]
CHECK = [(0.385, 0.515), (0.47, 0.60), (0.625, 0.425)]
CHECK_HALF_WIDTH = 0.03


def flatten(path, steps=32):
    pts = [path[0]]
    for seg in path[1:]:
        if seg[0] == "L":
            pts.append(seg[1])
            continue
        p0, (_, p1, p2, p3) = pts[-1], seg
        for i in range(1, steps + 1):
            t = i / steps
            u = 1 - t
            pts.append(
                tuple(
                    u**3 * a + 3 * u * u * t * b + 3 * u * t * t * c + t**3 * d
                    for a, b, c, d in zip(p0, p1, p2, p3)
                )
            )
    return pts


def polygon_coverage(poly, size, sub=4):
    """Per-pixel area coverage of a polygon: `sub` scanlines per pixel, exact horizontally."""
    cov = [[0.0] * size for _ in range(size)]
    edges = list(zip(poly, poly[1:] + poly[:1]))
    for py in range(size):
        row = cov[py]
        for s in range(sub):
            y = py + (s + 0.5) / sub
            xs = []
            for (x0, y0), (x1, y1) in edges:
                if (y0 <= y < y1) or (y1 <= y < y0):
                    xs.append(x0 + (y - y0) * (x1 - x0) / (y1 - y0))
            xs.sort()
            for a, b in zip(xs[0::2], xs[1::2]):
                for px in range(max(0, int(a)), min(size, int(math.ceil(b)))):
                    overlap = min(b, px + 1) - max(a, px)
                    if overlap > 0:
                        row[px] += overlap / sub
    return cov


def seg_dist(px, py, a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - ax - t * dx, py - ay - t * dy)


def mix(c1, c2, t):
    return tuple(round(a + (b - a) * t) for a, b in zip(c1, c2))


def render(size):
    shield = polygon_coverage([(x * size, y * size) for x, y in flatten(SHIELD)], size)
    check = [(x * size, y * size) for x, y in CHECK]
    radius = CHECK_HALF_WIDTH * size
    rows = []
    for py in range(size):
        bg = mix(TOP, BOTTOM, py / (size - 1))
        line = bytearray([0])  # filter type 0
        for px in range(size):
            colour = mix(bg, WHITE, min(1.0, shield[py][px]))
            cx, cy = px + 0.5, py + 0.5
            d = (
                min(
                    seg_dist(cx, cy, check[0], check[1]),
                    seg_dist(cx, cy, check[1], check[2]),
                )
                - radius
            )
            if d < 1:
                colour = mix(colour, bg, max(0.0, min(1.0, 0.5 - d)))
            line.extend(colour)
        rows.append(bytes(line))
    return png(size, b"".join(rows))


def png(size, raw):
    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)  # 8-bit RGB
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def main():
    os.makedirs(OUT, exist_ok=True)
    rendered = {}
    for name, size in [
        ("icon-180.png", 180),
        ("icon-192.png", 192),
        ("icon-512.png", 512),
        ("icon-maskable-512.png", 512),
    ]:
        data = rendered.setdefault(size, render(size))
        with open(os.path.join(OUT, name), "wb") as f:
            f.write(data)
        print("wrote", os.path.join(OUT, name))


if __name__ == "__main__":
    main()
