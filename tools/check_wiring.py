#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""组装产物的接线检查 / Wiring check for the assembled single-file mod.

构建脚本已经做了语法与归档层面的校验；这一步补的是"接线对不对"：
五个模块是否都内联了、尾部是否按正确顺序调用、声明是否在最前、
以及代码里有没有出现被禁止的 API 名。

用法：
    python tools/check_wiring.py
"""
from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSEMBLED = os.path.join(ROOT, "build", "mod.lua")
BUILD_SCRIPT = os.path.join(ROOT, "tools", "build.py")
MODULE = "mods/hd2mods/reinforcement_countdown"


def expected_revision() -> str:
    """从 build.py 读当前版本号。

    这里写死版本号是个陷阱：每次升版都会变成误报，而"检查失败"看起来像
    真故障。让它跟着 build.py 走。
    """
    with open(BUILD_SCRIPT, "r", encoding="utf-8") as fh:
        text = fh.read()
    match = re.search(r"""REVISION\s*=\s*['"]([^'"]+)['"]""", text)
    if not match:
        raise SystemExit("无法从 tools/build.py 读出 REVISION")
    return match.group(1)


REVISION = expected_revision()

REQUIRED = [
    ("local create_api = (function()", "read_api 内联"),
    ("local profile = (function()", "profile 内联"),
    ("local reinforcement = (function()", "reinforcement 内联"),
    ("local hud = (function()", "hud 内联"),
    ("local install = (function()", "install 内联"),
    ("return install(create_api, reinforcement, hud,", "尾部接线"),
    ("revision = '%s'" % REVISION, "版本号 %s 传入" % REVISION),
    ("rawget(_G, 'stingray')", "取 stingray 全局"),
    ("rawget(_G, 'CowboyBingusModLoader')", "loader 环境闸门"),
    ("reader.verify()", "构建校验被调用"),
    ("pcall(tick)", "每帧逻辑被 pcall 包住"),
    ("rawget(_G, 'update')", "update 钩子"),
]

FORBIDDEN_CALLS = [
    "WriteProcessMemory", "VirtualProtect", "VirtualAlloc", "VirtualFree",
    "CreateRemoteThread", "LoadLibrary", "CreateProcess",
]


def strip_comments(source: str) -> str:
    out, i, n = [], 0, len(source)
    while i < n:
        if source.startswith("--", i):
            bracket = re.match(r"\[(=*)\[", source[i + 2:])
            if bracket:
                close = "]" + "=" * len(bracket.group(1)) + "]"
                end = source.find(close, i + 2 + bracket.end())
                i = n if end < 0 else end + len(close)
                continue
            end = source.find("\n", i)
            i = n if end < 0 else end
            continue
        ch = source[i]
        if ch in "\"'":
            quote, j = ch, i + 1
            out.append(ch)
            while j < n:
                out.append(source[j])
                if source[j] == "\\":
                    if j + 1 < n:
                        out.append(source[j + 1])
                    j += 2
                    continue
                if source[j] == quote:
                    j += 1
                    break
                j += 1
            i = j
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def main() -> int:
    if not os.path.isfile(ASSEMBLED):
        print("找不到 %s，请先运行 tools/build.py" % ASSEMBLED)
        return 2
    with open(ASSEMBLED, "r", encoding="utf-8") as fh:
        source = fh.read()

    failures = 0
    declaration = "-- HD2-Addon: " + MODULE + "\n"
    if not source.startswith(declaration):
        print("FAIL 第一行不是声明：%r" % source.split("\n")[0][:80])
        failures += 1
    else:
        print("ok   第一行是 -- HD2-Addon 声明")
        if len(declaration.encode("utf-8")) > 256:
            print("FAIL 声明超过 256 字节")
            failures += 1

    for needle, label in REQUIRED:
        if needle in source:
            print("ok   %s" % label)
        else:
            print("FAIL 缺少：%s（找不到 %r）" % (label, needle))
            failures += 1

    code = strip_comments(source)
    for token in FORBIDDEN_CALLS:
        if token in code:
            print("FAIL 代码里出现被禁止的 API：%s" % token)
            failures += 1
    if not any(token in code for token in FORBIDDEN_CALLS):
        print("ok   代码中无写内存/改保护/分配/加载代码的调用")

    # 每个模块必须恰好内联一次：重复内联会让后面的定义覆盖前面的，
    # 而症状是"莫名其妙用了旧逻辑"。
    for variable in ("create_api", "profile", "reinforcement", "hud", "install"):
        count = source.count("local %s = (function()" % variable)
        if count != 1:
            print("FAIL %s 内联了 %d 次（应为 1 次）" % (variable, count))
            failures += 1
    if failures == 0:
        print("ok   五个模块各内联一次")

    print()
    if failures:
        print("%d 项接线检查失败" % failures)
        return 1
    print("接线检查全部通过（%d 项）" % (len(REQUIRED) + 8))
    return 0


if __name__ == "__main__":
    sys.exit(main())
