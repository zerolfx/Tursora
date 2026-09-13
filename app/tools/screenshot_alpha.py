#!/usr/bin/env python3
"""Check native screenshot PNG corner transparency without image dependencies."""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import zlib


def inspect(path):
    path = Path(path)
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path}: expected actual PNG bytes")
    offset, payload, header = 8, bytearray(), None
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValueError(f"{path}: truncated PNG chunk")
        size = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4:offset + 8]
        content = data[offset + 8:offset + 8 + size]
        if len(content) != size or offset + size + 12 > len(data):
            raise ValueError(f"{path}: truncated PNG payload")
        crc = struct.unpack_from(">I", data, offset + 8 + size)[0]
        if zlib.crc32(kind + content) & 0xffffffff != crc:
            raise ValueError(f"{path}: invalid PNG CRC")
        if kind == b"IHDR":
            if header is not None or size != 13:
                raise ValueError(f"{path}: invalid PNG header")
            header = struct.unpack(">IIBBBBB", content)
        elif kind == b"IDAT":
            payload.extend(content)
        offset += size + 12
        if kind == b"IEND":
            break
    if header is None:
        raise ValueError(f"{path}: missing PNG header")
    width, height, depth, color, compression, filtering, interlace = header
    if not 1 <= width * height <= 60_000_000:
        raise ValueError(f"{path}: unsupported screenshot dimensions")
    if (depth, color, compression, filtering, interlace) != (8, 6, 0, 0, 0):
        raise ValueError(f"{path}: expected non-interlaced 8-bit RGBA PNG, found color type {color}")
    decoder = zlib.decompressobj()
    expected_size = height * (width * 4 + 1)
    pixels = decoder.decompress(payload, expected_size + 1)
    if len(pixels) != expected_size or not decoder.eof:
        raise ValueError(f"{path}: invalid PNG decoded size")
    prior = bytearray(width)
    transparent = partial = 0
    corners = []
    for y in range(height):
        row_offset = y * (width * 4 + 1)
        filter_type = pixels[row_offset]
        row = bytearray(pixels[row_offset + 4:row_offset + 1 + width * 4:4])
        if filter_type not in range(5):
            raise ValueError(f"{path}: invalid PNG row filter")
        for x in range(width):
            left = row[x - 1] if x else 0
            above = prior[x]
            upper_left = prior[x - 1] if x else 0
            if filter_type == 1: predictor = left
            elif filter_type == 2: predictor = above
            elif filter_type == 3: predictor = (left + above) // 2
            elif filter_type == 4:
                value = left + above - upper_left
                a, b, c = abs(value - left), abs(value - above), abs(value - upper_left)
                predictor = left if a <= b and a <= c else above if b <= c else upper_left
            else: predictor = 0
            row[x] = (row[x] + predictor) & 255
        if y == 0 or y == height - 1:
            corners.extend([row[0], row[-1]])
        transparent += row.count(0)
        partial += width - row.count(0) - row.count(255)
        prior = row
    return {"path": str(path), "dimensions": [width, height], "corner_alpha": corners,
            "transparent_pixels": transparent, "partial_pixels": partial,
            "sha256": hashlib.sha256(data).hexdigest()}


def validate(path):
    result = inspect(path)
    if result["corner_alpha"] != [0, 0, 0, 0] or result["partial_pixels"] == 0:
        raise ValueError(f"{path}: native rounded corners need transparent exteriors and antialiased edges; prepare or recapture this screenshot")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    paths = args.paths or sorted((Path(__file__).resolve().parents[2] / "docs/images/features").glob("*.png"))
    if not paths:
        raise SystemExit("No screenshots found")
    results, errors = [], []
    for path in paths:
        try:
            results.append(validate(path))
        except ValueError as error:
            errors.append(str(error))
    if args.json:
        print(json.dumps({"screenshots": results, "errors": errors}, indent=2))
    else:
        print(f"Checked {len(paths)} screenshots: {len(results)} pass, {len(errors)} fail")
        for error in errors:
            print(error)
    if errors:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
