#!/usr/bin/env python3
"""Parse NFNT bitmap fonts from GRAPHIC.DAT (read-only).

Usage: nfnt.py GRAPHIC.DAT [FONT_ID TEXT]   (validate all; optionally print
                                             TEXT as ASCII art in FONT_ID)

Classic Macintosh FontRec with every 16-bit header field little-endian
(RRPW32.EXE FUN_0043558c, FUN_00435725/3b/73, FUN_004358a5, FUN_0043595e):
  0x00 fontType (0x9000)   0x02 firstChar   0x04 lastChar   0x06 widMax
  0x08 kernMax             0x0A nDescent    0x0C fRectWidth 0x0E fRectHeight
  0x10 owTLoc (words from 0x10 to the offset/width table)
  0x12 ascent  0x14 descent  0x16 leading  0x18 rowWords
  0x1A bit image: fRectHeight rows x rowWords*2 bytes, MSB = leftmost pixel
  then locTable: u16[lastChar-firstChar+3] bit offsets (LE), ending where
  owTable begins: 0x10 + 2*owTLoc; owTable: (lastChar-firstChar+3) entries of
  2 bytes, byte0 = image offset (added to kernMax), byte1 = advance width;
  ff ff = missing glyph. Quirks of the shipped data (Observed): the owTable
  bytes are left in Mac (big-endian word) order, and the final locTable entry
  (end of the missing glyph) was not byte-swapped; parse_nfnt fixes it up.
The engine indexes loc/ow tables by raw char code (all fonts have
firstChar = 0) and draws glyph c at pen.x + kernMax + offset, top at
pen.y - ascent, height ascent+descent. Its missing-glyph test compares the
OW word with 0x00ff, so the ff ff entries never trigger the fallback.
"""
import os
import struct
import sys

FIELDS = ("fontType", "firstChar", "lastChar", "widMax", "kernMax", "nDescent",
          "fRectWidth", "fRectHeight", "owTLoc", "ascent", "descent",
          "leading", "rowWords")


def parse_nfnt(buf):
    h = dict(zip(FIELDS, struct.unpack_from("<13h", buf, 0)))
    n = h["lastChar"] - h["firstChar"] + 3
    ow_off = 0x10 + 2 * h["owTLoc"]
    loc_off = ow_off - 2 * n
    bmp_len = h["rowWords"] * 2 * h["fRectHeight"]
    if h["fontType"] & 0xFFFF != 0x9000 or loc_off != 0x1A + bmp_len:
        raise ValueError("unexpected NFNT layout")
    loc = list(struct.unpack_from(f"<{n - 1}H", buf, loc_off))
    loc.append(struct.unpack_from(">H", buf, loc_off + 2 * (n - 1))[0])
    ow = [(buf[ow_off + 2 * i], buf[ow_off + 2 * i + 1]) for i in range(n)]
    return {"header": h, "loc": loc, "ow": ow, "bitmap": buf[0x1A:loc_off],
            "end": ow_off + 2 * n}


def glyph(font, ch):
    """Return (offset, advance, rows) for char code ch, or None if missing."""
    h = font["header"]
    i = ch - h["firstChar"]
    if not 0 <= i < len(font["ow"]) - 1 or font["ow"][i] == (255, 255):
        return None
    x0, x1 = font["loc"][i], font["loc"][i + 1]
    stride = h["rowWords"] * 2
    rows = []
    for r in range(h["fRectHeight"]):
        row = font["bitmap"][r * stride:(r + 1) * stride]
        rows.append([(row[b >> 3] >> (7 - (b & 7))) & 1 for b in range(x0, x1)])
    off, adv = font["ow"][i]
    return off, adv, rows


def render_text(font, text):
    h = font["header"]
    width = sum((glyph(font, ord(c)) or (0, 0, []))[1] for c in text) + 32
    canvas = [[0] * width for _ in range(h["fRectHeight"])]
    pen = 0
    for c in text:
        g = glyph(font, ord(c))
        if not g:
            continue
        off, adv, rows = g
        for y, row in enumerate(rows):
            for x, v in enumerate(row):
                px = pen + h["kernMax"] + off + x
                if v and 0 <= px < width:
                    canvas[y][px] = 1
        pen += adv
    return "\n".join("".join("#" if v else "." for v in r) for r in canvas)


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import ne_resources
    data = open(sys.argv[1], "rb").read()
    fonts = {rid: data[o:o + l] for t, rid, o, l, _ in ne_resources.parse(data)
             if t == "32516"}
    ok = bad = 0
    for rid, buf in sorted(fonts.items()):
        try:
            f = parse_nfnt(buf)
            h, loc = f["header"], f["loc"]
            assert f["end"] <= len(buf)
            assert all(a <= b for a, b in zip(loc, loc[1:])), "locTable not monotonic"
            assert loc[-1] <= h["rowWords"] * 16, "glyph past image width"
            present = [i for i, e in enumerate(f["ow"][:-1]) if e != (255, 255)]
            assert all(f["ow"][i][1] <= h["widMax"] for i in present)
            print(f"NFNT {rid}: chars {h['firstChar']}-{h['lastChar']} "
                  f"height {h['fRectHeight']} (asc {h['ascent']} desc {h['descent']}) "
                  f"widMax {h['widMax']} kernMax {h['kernMax']} glyphs {len(present)}")
            ok += 1
        except Exception as e:
            bad += 1
            print("FAIL", rid, e)
    print(f"ok={ok} bad={bad}")
    if len(sys.argv) > 3:
        print(render_text(parse_nfnt(fonts[int(sys.argv[2])]), sys.argv[3]))
