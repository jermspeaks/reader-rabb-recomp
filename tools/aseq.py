#!/usr/bin/env python3
"""Parse ASEQ (animation sequence) resources from GRAPHIC.DAT (read-only).

Layout (little-endian, derived from RRPW32.EXE FUN_0043462a / FUN_004379c3):
  header   5 x s16: seq_count, frame_count, version, unk3, unk4
           (version > 0xFE means byte-swapped big-endian data; shipped data:
           seq_count=1, version 8 or 30, unk3=15, unk4=1 -- none read at runtime)
  u32[frame_count]  frame offsets, relative to frame base
  u32[seq_count]    pointer slots (unused on disk)
  seq_count x { s16 n; n x 4 x s16 steps }
  frame base: frames, each { s16 unk0 (always 4, unused); s16 width;
                             s16 height; RLE rows }
Step = (x, y, frame, tag). The engine only uses sequence 0 (object+0x1a).
  frame >= 0: draw frame `frame` at actor origin + (x, y)   (FUN_00433c49)
              tag: per-frame 16-bit value, identical for identical frame data,
              often 0; never read by the engine (authoring checksum?)
  frame < 0:  control marker, see STEP_OPS (FUN_00433d23, FUN_0041e2xx).
One step is consumed per engine tick (FUN_00433a00: 1000/8-9 = 116 ms by
default; some activities request 60 fps via FUN_004339a4(0x3c)).
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


STEP_OPS = {
    -1: "END",      # end of script; generic advance treats like -4
    -2: "LOOP",     # restart at step 0 (or 1 if step 0 is a marker)
    -4: "REST",     # idle point: actor stops here until triggered
    -5: "BRANCH",   # goto x (default) or y (alternate state); generic
                    # player shifts origin so a walk cycle stays continuous
    -7: "IFSPEECH", # goto x if speech still playing for this actor, else y
    -500: "TRIGGER",  # start actor whose ASEQ id == y (x=1, tag=2 in data)
}


def describe_step(step):
    """Return a short human-readable description of one 4 x s16 step."""
    x, y, frame, tag = step
    if frame >= 0:
        return f"FRAME {frame} @({x},{y})"
    op = STEP_OPS.get(frame, f"OP{frame}")
    if frame in (-5, -7):
        return f"{op} {x}/{y}"
    if frame == -500:
        return f"{op} aseq {y}"
    return op


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
    from collections import Counter
    ops = Counter()
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
            n_steps = len(a["sequences"][0])
            for x, y, fr, tag in a["sequences"][0]:
                ops[STEP_OPS.get(fr, "FRAME" if fr >= 0 else fr)] += 1
                assert fr < len(a["frames"]), "frame index out of range"
                assert fr >= 0 or fr in STEP_OPS, f"unknown op {fr}"
                if fr in (-5, -7):
                    assert 0 <= x < n_steps and 0 <= y < n_steps, "bad branch"
            assert a["sequences"][0][-1][2] == -1, "script does not end with END"
            ok += 1
        except Exception as e:
            bad += 1
            if bad <= 5:
                print("FAIL", rid, e, buf[:16].hex())
    print(f"ok={ok} bad={bad} frames={frames}")
    print("steps:", dict(ops))
