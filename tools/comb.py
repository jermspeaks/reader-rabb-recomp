#!/usr/bin/env python3
"""Parse COMB (scene composition) resources from GRAPHIC.DAT (read-only).

Usage: comb.py GRAPHIC.DAT [--dump]

Layout (little-endian; RRPW32.EXE FUN_00418xxx @ line ~6760, FUN_0041d5ea,
FUN_0041e2xx, FUN_00419983, FUN_0041f462):
  header   s16 version (=1), s16 scene_id, s16 count
           scene_id = background ASEQ id and RRGB palette id
           (FUN_00434c7c(scene_id, scene_id))
  count x 12-byte records (engine caps count at 0x45/0x46):
    s16 id      > 0: ASEQ id of an actor; <= 0: plain region (no sprite)
    s16 x1, y1  actor origin (passed to FUN_004340de) / region top-left
    s16 x2, y2  bottom-right of the actor's bounding box / region;
                for regions a negative x2 is negated on load
    s16 cues    0, or byte offset (from resource start) of a cue table:
                  s16 n; n x { s16 sound_id, s16 step }
                when the actor reaches `step`, WAVE `sound_id` is played
                (FUN_004351c2) -- checked in the scene tick, line ~10241
Actors whose step 0 is a REST marker start idle at step 1; otherwise they
start at step 0 and play continuously.
"""
import os
import struct
import sys


def parse_comb(buf):
    version, scene, count = struct.unpack_from("<3h", buf, 0)
    recs = []
    for i in range(count):
        rid, x1, y1, x2, y2, cue_off = struct.unpack_from("<6h", buf, 6 + 12 * i)
        cues = []
        if cue_off:
            n = struct.unpack_from("<h", buf, cue_off)[0]
            v = struct.unpack_from(f"<{2 * n}h", buf, cue_off + 2)
            cues = list(zip(v[0::2], v[1::2]))
        recs.append({"id": rid, "rect": (x1, y1, x2, y2), "cue_off": cue_off,
                     "cues": cues})
    return {"version": version, "scene": scene, "records": recs}


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import ne_resources
    import aseq
    data = open(sys.argv[1], "rb").read()
    res = ne_resources.parse(data)
    by_type = {}
    for t, rid, o, l, _ in res:
        by_type.setdefault(t, {})[rid] = data[o:o + l]
    seqs = by_type["32513"]
    pals = by_type["32517"]
    ok = bad = actors = regions = cues = wmatch = 0
    for rid, buf in sorted(by_type["32514"].items()):
        try:
            c = parse_comb(buf)
            assert c["version"] == 1
            assert c["scene"] in seqs and c["scene"] in pals, "scene not ASEQ+RRGB"
            for r in c["records"]:
                x1, y1, x2, y2 = r["rect"]
                if r["id"] > 0:
                    actors += 1
                    a = aseq.parse_aseq(seqs[r["id"]])
                    steps = a["sequences"][0]
                    first = steps[1] if steps[0][2] < 0 else steps[0]
                    _, w, h, _, _ = aseq.decode_frame(seqs[r["id"]], a["frames"][first[2]])
                    wmatch += (x2 - x1, y2 - y1) == (w, h)
                    for snd, st in r["cues"]:
                        assert 0 <= st < len(steps), "cue step out of range"
                        cues += 1
                else:
                    regions += 1
                if "--dump" in sys.argv:
                    print(rid, r)
            ok += 1
        except Exception as e:
            bad += 1
            print("FAIL", rid, e)
    print(f"ok={ok} bad={bad} actors={actors} regions={regions} cues={cues} "
          f"bbox==first-frame-size={wmatch}/{actors}")
