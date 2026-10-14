#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""核对文档：引用的脚本是否存在、内部链接是否有效、有无明显问题。"""
from __future__ import annotations

import io
import os
import re
import sys

H = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main() -> int:
    path = os.path.join(H, "docs", "05-客机时间偏差原理.md")
    with io.open(path, encoding="utf-8") as fh:
        text = fh.read()

    print("=== 文档引用的脚本 ===")
    referenced = sorted(set(re.findall(r"`((?:tools|tests)/[\w./]+)`", text)
                            + re.findall(r"`((?:tools|tests)/[\w./]+\.py)`", text)))
    problems = 0
    for name in referenced:
        exists = os.path.exists(os.path.join(H, name))
        if not exists:
            problems += 1
        print("  %-40s %s" % (name, "存在" if exists else "**缺失**"))
    if not referenced:
        print("  （没有引用具体脚本）")

    print()
    print("=== 引用的源文件/常量是否与代码一致 ===")
    source = io.open(os.path.join(H, "src", "reinforcement.lua"), encoding="utf-8").read()
    constants = re.findall(r"`([A-Z_]{3,})\s*=\s*([0-9.]+)`", text)
    for name, value in constants:
        match = re.search(r"local %s = ([0-9.]+)" % name, source)
        actual = match.group(1) if match else None
        ok = actual is not None and abs(float(actual) - float(value)) < 1e-9
        if not ok:
            problems += 1
        print("  %-22s 文档写 %-8s 代码是 %-8s %s"
              % (name, value, actual if actual else "未找到", "一致" if ok else "**不一致**"))

    print()
    print("=== 文档内锚点/相对链接 ===")
    for target in re.findall(r"\[[^\]]*\]\(([^)]+)\)", text):
        if target.startswith("http"):
            continue
        resolved = os.path.normpath(os.path.join(H, "docs", target))
        ok = os.path.exists(resolved)
        if not ok:
            problems += 1
        print("  %-40s %s" % (target, "有效" if ok else "**断链**"))

    print()
    print("=== 表格与代码块配对 ===")
    fences = text.count("```")
    print("  ``` 出现 %d 次（应为偶数）：%s" % (fences, "正常" if fences % 2 == 0 else "**奇数，有未闭合**"))
    if fences % 2:
        problems += 1

    print()
    print("发现 %d 处问题" % problems)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
