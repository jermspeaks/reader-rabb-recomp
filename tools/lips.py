#!/usr/bin/env python3
"""Parse LIPS (lip-sync track) resources from GRAPHIC.DAT (read-only).

Usage: lips.py RRPDATA_DIR      (validates every LIPS against the WAVE files)

Layout (little-endian, 6-byte records; RRPW32.EXE FUN_00434f25 / FUN_00435051):
  record 0 (header)  s16 magic = 0x0101, s16 actor_aseq_id, s16 count
  record i, 1..count s16 mouth, u16 t_hi, u16 t_lo
The engine copies (count-1)*6+12 bytes and, once per engine tick, returns
`mouth` of the next record; the talking actor is drawn at ASEQ step mouth+1
(FUN_0041103a). Index 1 also starts the WAVE with the same resource ID
(FUN_00434f25 -> FUN_00435150). At index == count the track ends.
`actor_aseq_id` and the 32-bit t = (t_hi << 16) | t_lo are not read at
runtime. In the data t == (i-1) * L, where L is usually the byte length of the
matching WAVE's data chunk (authoring artifact; word order shows the Mac
big-endian u32 was swapped as two 16-bit words).
"""
import os
import struct
import sys


def parse_lips(buf):
    magic, actor, count = struct.unpack_from("<3h", buf, 0)
    if magic != 0x0101:
        raise ValueError(f"bad magic {magic:#x}")
    recs = [struct.unpack_from("<hHH", buf, 6 * i) for i in range(1, count + 1)]
    return {"actor": actor, "count": count,
            "mouth": [r[0] for r in recs],
            "t": [(r[1] << 16) | r[2] for r in recs]}


def wave_data_len(w):
    p = 12
    while p + 8 <= len(w):
        tag, n = w[p:p + 4], struct.unpack_from("<I", w, p + 4)[0]
        if tag == b"data":
            return n
        p += 8 + n + (n & 1)
    return None


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import ne_resources
    from collections import Counter
    root = sys.argv[1]
    waves = {}
    for name in ("SPEECH", "SOUNDS", "MUSIC"):
        data = open(os.path.join(root, name + ".DAT"), "rb").read()
        for t, rid, o, l, _ in ne_resources.parse(data):
            waves.setdefault(rid, (name, data[o:o + l]))
    data = open(os.path.join(root, "GRAPHIC.DAT"), "rb").read()
    ok = bad = 0
    where, tlin, tlen, actors = Counter(), Counter(), Counter(), Counter()
    for t, rid, o, l, _ in ne_resources.parse(data):
        if t != "32515":
            continue
        try:
            lp = parse_lips(data[o:o + l])
            assert 6 * lp["count"] + 6 <= l, "records overrun resource"
            step = lp["t"][1] if lp["count"] > 1 else 0
            tlin[all(v == (i * step) & 0xFFFFFFFF for i, v in enumerate(lp["t"]))] += 1
            actors[lp["actor"]] += 1
            if rid in waves:
                where[waves[rid][0]] += 1
                tlen[step == wave_data_len(waves[rid][1])] += 1
            else:
                where["none"] += 1
            ok += 1
        except Exception as e:
            bad += 1
            print("FAIL", rid, e)
    print(f"ok={ok} bad={bad}")
    print("matching WAVE id in:", dict(where))
    print("t linear in index:", dict(tlin), " step == WAVE data length:", dict(tlen))
    print("actor ASEQ ids:", dict(actors))
