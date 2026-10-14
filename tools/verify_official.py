#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""核对正式版 v1.0.0 的包内容。"""
from __future__ import annotations

import glob
import hashlib
import json
import os
import re
import struct
import zipfile

H = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
path = glob.glob(os.path.join(H, "build", "Reinforcement-Countdown-HUD-*.zip"))[0]

archive = zipfile.ZipFile(path)
manifest = json.loads(archive.read("manifest.json").decode("utf-8"))
report = json.loads(archive.read("ReinforcementCountdownHUD-report.json").decode("utf-8"))
blob = archive.read("data/9ba626afa44a3aa3.patch_0")
off, = struct.unpack_from("<Q", blob, 104 + 16)
length = struct.unpack_from("<II", blob, off)[0]
source = blob[off + 8:off + 8 + length].decode("utf-8")

print("=== 正式版 v1.0.0 核对 ===")
print("  包内文件       : %s" % ", ".join(sorted(archive.namelist())))
print("  manifest.Name  : %s" % manifest["Name"])
print("  manifest.Guid  : %s" % manifest["Guid"])
print("  report.revision: %s" % report["revision"])
print("  源码含 v1.0.0  : %s" % ("v1.0.0" in source))

tail = re.search(r"sample_every = (\d+), (diagnostic = \w+)", source)
print("  尾部接线       : %s" % (tail.group(0) if tail else "?"))

print()
print("  内容自检：")
checks = [
    ("READY 锁存 (saw_zero)", "saw_zero" in source),
    ("blockers 挂起守卫", "if blockers and blockers > 0 then return 'unknown' end" in source),
    ("滑动中位数速率", "ratios[#ratios + 1]" in source),
    ("窗口按需向后扩展", "local extended = RATE_WINDOW * 3" in source),
    ("离散度随跨度缩放", "spread_tolerance" in source),
    ("显示值单调保护", "estimate.shown" in source),
    ("HUD 括号误差", "(±%d)" in source),
    ("速率窗口 12 秒", "RATE_WINDOW = 12.0" in source),
]
for label, ok in checks:
    print("     %-22s %s" % (label, "在" if ok else "**缺失**"))

print()
with open(path, "rb") as fh:
    digest = hashlib.sha256(fh.read()).hexdigest().upper()
print("  发布 SHA-256   : %s" % digest)
