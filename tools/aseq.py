#!/usr/bin/env python3
"""Parse ASEQ (animation sequence) resources from GRAPHIC.DAT (read-only).

Layout (little-endian, derived from RRPW32.EXE FUN_0043462a / FUN_004379c3):
  header   5 x s16: seq_count, frame_count, version, unk3, unk4
           (version > 0xFE means byte-swapped big-endian data)
  u32[frame_count]  frame offsets, relative to frame base
  u32[seq_count]    pointer slots (unused on disk)
  seq_count x { s16 n; n x 4 x s16 steps }
  frame base: frames, each { s16 unk0; s16 width; s16 height; RLE rows }
Row RLE, repeated until `width` pixels are consumed:
  00 n      skip n transparent pixels
  FF c n    n pixels of colour c
  k         k literal colour bytes follow (1..254)
"""
import struct
import sys


def parse_aseq(buf):
    seq_count, frame_count, version, u3, u4 = struct.unpack_from("<5h", buf, 0)
    if version > 0xFE:
        raise ValueError("big-endian ASEQ not supported")
    pos = 10
    offsets = struct.unpack_from(f"<{frame_count}I", buf, pos)
    pos += 4 * frame_count
    pos += 4 * seq_count  # per-sequence pointer slots, filled in at load time
    seqs = []
    for _ in range(seq_count):
        n = struct.unpack_from("<h", buf, pos)[0]
        pos += 2
        seqs.append([struct.unpack_from("<4h", buf, pos + 8 * i) for i in range(n)])
        pos += 8 * n
    base = pos
    return {"header": (seq_count, frame_count, version, u3, u4),
            "sequences": seqs, "frame_base": base,
            "frames": [base + o for o in offsets]}


def decode_frame(buf, off):
    """Return (unk0, width, height, pixels, end); pixels: list of rows, None = transparent."""
    unk0, w, h = struct.unpack_from("<3h", buf, off)
    p = off + 6
    rows = []
    for _ in range(h):
        row = []
        while len(row) < w:
            b = buf[p]
            if b == 0:
                row.extend([None] * buf[p + 1])
                p += 2
            elif b == 0xFF:
                row.extend([buf[p + 1]] * buf[p + 2])
                p += 3
            else:
                row.extend(buf[p + 1:p + 1 + b])
                p += 1 + b
        if len(row) != w:
            raise ValueError(f"row overrun {len(row)} != {w}")
        rows.append(row)
    return unk0, w, h, rows, p


if __name__ == "__main__":
    sys.path.insert(0, __file__.rsplit("/", 1)[0])
    import ne_resources
    data = open(sys.argv[1], "rb").read()
    ok = bad = frames = 0
    for t, rid, o, l, _ in ne_resources.parse(data):
        if t != "32513":
            continue
        buf = data[o:o + l]
        try:
            a = parse_aseq(buf)
            ends = []
            for fo in a["frames"]:
                *_, end = decode_frame(buf, fo)
                ends.append(end)
                frames += 1
            # every frame should end at or before the next one starts
            nxt = sorted(a["frames"])[1:] + [l]
            assert all(e <= n for e, n in zip(sorted(ends), nxt)), "frame overlap"
            ok += 1
        except Exception as e:
            bad += 1
            if bad <= 5:
                print("FAIL", rid, e, buf[:16].hex())
    print(f"ok={ok} bad={bad} frames={frames}")
