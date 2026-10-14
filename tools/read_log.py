#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""容错读取模组日志并做归因分析。

游戏进程写日志时可能出现截断的多字节序列，所以逐行解码、坏字节替换，
而不是整文件解码失败。
"""
from __future__ import annotations

import os
import re
import sys

CANDIDATES = [
    os.path.join(os.environ.get("LOCALAPPDATA", ""),
                 "CowboyBingus", "Helldivers2", "Logs", "ReinforcementRadar.log"),
    r"C:\ReinforcementRadar.log",
]


def read_lines(path: str):
    with open(path, "rb") as fh:
        data = fh.read()
    out = []
    for raw in data.split(b"\n"):
        out.append(raw.decode("utf-8", "replace").rstrip("\r"))
    return out


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else None
    if not path:
        for candidate in CANDIDATES:
            if os.path.isfile(candidate):
                path = candidate
                break
    if not path or not os.path.isfile(path):
        print("找不到日志。已尝试：")
        for candidate in CANDIDATES:
            print("  " + candidate)
        return 2

    lines = read_lines(path)
    print("日志：%s" % path)
    print("大小：%d 字节，%d 行" % (os.path.getsize(path), len(lines)))
    print("=" * 72)
    for index, line in enumerate(lines, 1):
        print("%4d | %s" % (index, line))
    print("=" * 72)

    # 归因统计
    print("\n【归因统计】")
    versions = sorted(set(re.findall(r"=== Reinforcement Radar (\S+) \(r(\d+)\)", "\n".join(lines))))
    print("出现过的版本：%s" % (versions or "无"))
    for token in ("VERIFY", "构建校验通过", "拒绝", "不支持的游戏构建", "守卫失败",
                  "authoritative=true", "authoritative=false",
                  "status=COOLDOWN", "status=READY", "status=PENDING", "status=PAUSED",
                  "status=UNAVAILABLE", "status=UNKNOWN",
                  "非权威端", "SAMPLE", "HEARTBEAT"):
        count = sum(1 for line in lines if token in line)
        if count:
            print("  %-28s %d 次" % (token, count))
    return 0


if __name__ == "__main__":
    sys.exit(main())
