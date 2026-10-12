#!/usr/bin/env python3
"""List the resource table of a Win16 NE module (read-only).

Usage: ne_resources.py FILE [--entries]
Prints a per-type summary, or one line per resource with --entries.
"""
import struct
import sys
from collections import Counter

RT_NAMES = {1: "CURSOR", 2: "BITMAP", 3: "ICON", 4: "MENU", 5: "DIALOG",
            6: "STRING", 7: "FONTDIR", 8: "FONT", 9: "ACCELERATOR",
            10: "RCDATA", 12: "GROUP_CURSOR", 14: "GROUP_ICON", 16: "VERSION"}


def read_name(data, table_off, rel):
    n = data[table_off + rel]
    return data[table_off + rel + 1:table_off + rel + 1 + n].decode("latin-1")


def parse(data):
    ne = struct.unpack_from("<I", data, 0x3C)[0]
    if data[ne:ne + 2] != b"NE":
        raise ValueError("not an NE module")
    rsrc = ne + struct.unpack_from("<H", data, ne + 0x24)[0]
    shift = struct.unpack_from("<H", data, rsrc)[0]
    pos = rsrc + 2
    out = []
    while True:
        type_id, count = struct.unpack_from("<HH", data, pos)
        if type_id == 0:
            break
        tname = (RT_NAMES.get(type_id & 0x7FFF, str(type_id & 0x7FFF))
                 if type_id & 0x8000 else read_name(data, rsrc, type_id))
        pos += 8
        for _ in range(count):
            off, length, flags, rid = struct.unpack_from("<HHHH", data, pos)
            pos += 12
            name = rid & 0x7FFF if rid & 0x8000 else read_name(data, rsrc, rid)
            out.append((tname, name, off << shift, length << shift, flags))
    return out


def main():
    path = sys.argv[1]
    with open(path, "rb") as f:
        data = f.read()
    res = parse(data)
    if "--entries" in sys.argv:
        for t, n, o, l, fl in res:
            print(f"{t}\t{n}\t0x{o:08x}\t{l}\t0x{fl:04x}\t{data[o:o+8].hex()}")
        return
    counts = Counter(t for t, *_ in res)
    sizes = Counter()
    for t, _, _, l, _ in res:
        sizes[t] += l
    print(f"{path}: {len(res)} resources")
    for t in counts:
        print(f"  {t:>14}: {counts[t]:6d} entries, {sizes[t]:>10d} bytes")


if __name__ == "__main__":
    main()
