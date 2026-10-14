#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Extract the verified signature table + offsets from the upstream source.

Hand-transcribing ~1 KB of hex inside 8 guards is exactly how guard 7 got a
one-character error upstream, and it also cannot be checked against game.dll on
disk (the code section is packed in the file and only expands in memory).

So: read the upstream file, pull the table out mechanically, and emit a Lua
fragment. Nothing here is typed by hand.

Usage:
    python tools/extract_profile.py <upstream reinforcement.lua> <out.lua>
"""
from __future__ import annotations

import os
import re
import sys

GUARD = re.compile(r"\{rva = (\d+), hex = '([0-9a-f]+)'\}")
OFFSET = re.compile(r"^\s*(\w+) = (0x[0-9a-f]+|\d+),\s*--\s*(.+)$", re.M)
GLOBAL = re.compile(r"(\w+) = (\d+),\s*--\s*(0x[0-9a-f]+)", re.I)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    source = open(sys.argv[1], "r", encoding="utf-8").read()

    guards = GUARD.findall(source)
    if len(guards) < 4:
        print("only found %d guards; refusing to emit a partial table" % len(guards))
        return 1

    lines = [
        "-- 由 tools/extract_profile.py 从上游源机械提取，请勿手工编辑。",
        "-- 这些是原生代码守卫：RVA + 该处期望的精确字节。游戏更新后它们会变，",
        "-- 读取器会因此拒绝工作，而不是按已经变了的偏移去读。",
        "return {",
    ]

    fingerprint = re.search(r"game_dll = \{(.*?)\},", source, re.S)
    if not fingerprint:
        print("could not locate the game.dll fingerprint block")
        return 1
    fields = dict(re.findall(r"(\w+) = (\d+)", fingerprint.group(1)))
    lines.append("    game_dll = {")
    for key in ("timestamp", "image_size"):
        if key not in fields:
            print("fingerprint block is missing %r" % key)
            return 1
        lines.append("        %s = %s," % (key, fields[key]))
    lines.append("    },")

    lines.append("    guards = {")
    for rva, hexs in guards:
        lines.append("        {rva = %s, hex = '%s'}," % (rva, hexs))
    lines.append("    },")

    # Offsets block: manager/pacing field offsets with their trailing comments.
    block = re.search(r"offsets = \{(.*?)\n    \},", source, re.S)
    if not block:
        print("could not locate the offsets block")
        return 1
    lines.append("    offsets = {")
    for name, value, comment in OFFSET.findall(block.group(1)):
        lines.append("        %s = %s,   -- %s" % (name, value, comment.strip()))
    lines.append("    },")

    lines.append("    globals = {")
    for name, decimal, hexa in GLOBAL.findall(
            re.search(r"globals = \{(.*?)\n    \},", source, re.S).group(1)):
        lines.append("        %s = %s,   -- %s" % (name, decimal, hexa))
    lines.append("    },")
    lines.append("}")

    out = "\n".join(lines) + "\n"
    with open(sys.argv[2], "w", encoding="utf-8", newline="\n") as fh:
        fh.write(out)
    total = sum(len(h) // 2 for _, h in guards)
    print("wrote %s: %d guards, %d guard bytes, %d offsets"
          % (sys.argv[2], len(guards), total, len(OFFSET.findall(block.group(1)))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
