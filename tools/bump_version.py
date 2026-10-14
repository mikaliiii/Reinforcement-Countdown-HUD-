#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把版本号从 v1.0.0 提到 v1.1.0。

为什么要提版本：v1.0.0 是**客机不显示**的版本，v1.1.0 才是支持客机的。
两份包必须能一眼区分，否则玩家拿错了不会知道。
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, "tools", "build.py")

with io.open(PATH, encoding="utf-8") as fh:
    source = fh.read()

before = re.search(r"""REVISION\s*=\s*['"]([^'"]+)['"]""", source)
revision_before = before.group(1) if before else None
revision_id_before = re.search(r"revision_id = (\d+)", source)

source = re.sub(r"""REVISION\s*=\s*['"][^'"]+['"]""",
                'REVISION = "v1.1.0"', source)
source = re.sub(r"revision_id = \d+", "revision_id = 2", source)

with io.open(PATH, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(source)

print("build.py 版本号：%s -> %s" % (revision_before, "v1.1.0"))
print("revision_id ：%s -> %s"
      % (revision_id_before.group(1) if revision_id_before else "?", "2"))
sys.exit(0)
