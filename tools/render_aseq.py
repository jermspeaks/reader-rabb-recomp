#!/usr/bin/env python3
"""Render ASEQ frames to PNG for local verification (output stays outside git).

Usage: render_aseq.py GRAPHIC.DAT OUT_DIR PALETTE_ID ASEQ_ID [ASEQ_ID...]
Transparent pixels are written with alpha 0.
"""
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import aseq
import ne_resources


def load_palette(buf):
    return [(buf[i * 6], buf[i * 6 + 2], buf[i * 6 + 4]) for i in range(256)]


def write_png(path, w, h, rgba_rows):
    raw = b"".join(b"\0" + bytes(r) for r in rgba_rows)
    def chunk(t, d):
        c = t + d
        return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw)))
        f.write(chunk(b"IEND", b""))


def main():
    dat, out, pal_id, *ids = sys.argv[1:]
    data = open(dat, "rb").read()
    res = {(t, str(i)): data[o:o + l] for t, i, o, l, _ in ne_resources.parse(data)}
    pal = load_palette(res[("32517", pal_id)])
    os.makedirs(out, exist_ok=True)
    for rid in ids:
        buf = res[("32513", rid)]
        a = aseq.parse_aseq(buf)
        for n, fo in enumerate(a["frames"]):
            _, w, h, rows, _ = aseq.decode_frame(buf, fo)
            if w <= 0 or h <= 0:
                continue
            rgba = [[v for px in row for v in
                     ((0, 0, 0, 0) if px is None else pal[px] + (255,))] for row in rows]
            write_png(os.path.join(out, f"aseq_{rid}_f{n:03d}.png"), w, h, rgba)


if __name__ == "__main__":
    main()
