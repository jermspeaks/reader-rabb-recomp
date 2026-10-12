#!/usr/bin/env python3
"""Look for common graphics/container signatures in the start of GRAPHIC.DAT."""

import argparse
from pathlib import Path


# (display name, byte signature)
SIGNATURES = (
    ("DOS/Windows executable (MZ)", b"MZ"),
    ("PNG", b"\x89PNG\r\n\x1a\n"),
    ("JPEG", b"\xff\xd8\xff"),
    ("GIF87a", b"GIF87a"),
    ("GIF89a", b"GIF89a"),
    ("BMP", b"BM"),
    ("TIFF (little-endian)", b"II*\x00"),
    ("TIFF (big-endian)", b"MM\x00*"),

    ("JPEG 2000", b"\x00\x00\x00\x0cjP  \r\n\x87\n"),
    ("RIFF container", b"RIFF"),
    ("Photoshop PSD", b"8BPS"),
)

RIFF_TYPES = {
    b"WEBP": "WebP image",
    b"WAVE": "WAV audio",
    b"AVI ": "AVI video",
}


def find_signatures(data: bytes) -> list[tuple[int, str]]:
    """Return (offset, name) pairs for known signatures at any byte offset."""
    matches = []
    for offset in range(len(data)):
        for name, signature in SIGNATURES:
            if data.startswith(signature, offset):
                if name == "RIFF container" and offset + 12 <= len(data):
                    riff_type = RIFF_TYPES.get(data[offset + 8 : offset + 12])
                    if riff_type:
                        matches.append((offset, f"RIFF/{riff_type}"))
                        continue
                matches.append((offset, name))

        # ICO/CUR starts with reserved=0 and type=1 (icon) or 2 (cursor),
        # followed by a nonzero image count. Check the complete six-byte header
        # so ordinary zero-filled data is not reported as an image.
        if offset + 6 <= len(data) and data[offset : offset + 2] == b"\x00\x00":
            image_type = int.from_bytes(data[offset + 2 : offset + 4], "little")
            image_count = int.from_bytes(data[offset + 4 : offset + 6], "little")
            if image_type in (1, 2) and 0 < image_count <= 256:
                kind = "ICO" if image_type == 1 else "CUR"
                matches.append((offset, f"{kind} directory candidate ({image_count} image(s))"))
    return matches


def main() -> int:
    default_path = Path(__file__).resolve().parent / "RRPDATA" / "GRAPHIC.DAT"
    parser = argparse.ArgumentParser(
        description="Scan the start of a data file for common graphics signatures."
    )
    parser.add_argument(
        "file", nargs="?", type=Path, default=default_path,
        help=f"file to scan (default: {default_path})",
    )
    parser.add_argument(
        "--bytes", type=int, default=1024,
        help="number of initial bytes to scan (default: 1024)",
    )
    args = parser.parse_args()

    if args.bytes <= 0:
        parser.error("--bytes must be a positive integer")
    if not args.file.is_file():
        parser.error(f"file not found: {args.file}")

    with args.file.open("rb") as source:
        data = source.read(args.bytes)

    print(f"File: {args.file}")
    print(f"Read: {len(data)} byte(s) (requested {args.bytes})")
    print("Header (first 64 bytes):")
    for offset in range(0, min(len(data), 64), 16):
        chunk = data[offset : offset + 16]
        hex_bytes = " ".join(f"{byte:02X}" for byte in chunk)
        text = "".join(chr(byte) if 32 <= byte <= 126 else "." for byte in chunk)
        print(f"  {offset:04X}: {hex_bytes:<47}  {text}")

    matches = find_signatures(data)
    print("\nSignature matches:")
    if matches:
        for offset, name in matches:
            print(f"  0x{offset:04X} ({offset:4d}): {name}")
    else:
        print("  No known signatures found in the scanned bytes.")
        print("  The file may use a custom game-specific format or have a later payload.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
