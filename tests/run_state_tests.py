#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""跑状态机夹具测试 / Run the offline state-machine fixtures.

用游戏的 LuaJIT 真正执行 tests/state_machine.lua，并把读取器源码从 Python 侧
喂进去——Lua 的 fopen 打不开含中文的路径，这是本机实测过的坑。

用法：
    python tests/run_state_tests.py
"""
from __future__ import annotations

import glob
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def lupa_root():
    for pattern in (os.path.join(ROOT, "vendor", "lupa-*"),
                    os.path.join(os.path.dirname(ROOT), "vendor", "lupa-*")):
        found = sorted(glob.glob(pattern))
        if found:
            return found[0]
    return None


def main() -> int:
    root = lupa_root()
    if not root:
        print("找不到 lupa，请先运行 tools/vendor_lupa.py")
        return 2
    sys.path.insert(0, root)
    try:
        from lupa.luajit21 import LuaRuntime  # type: ignore
    except Exception as exc:  # noqa: BLE001
        print("无法加载 lupa.luajit21：%s" % exc)
        return 2

    lua = LuaRuntime(encoding=None)

    def read_bytes(relative):
        path = os.path.join(ROOT, relative.replace("/", os.sep))
        with open(path, "rb") as fh:
            return fh.read()

    reader_source = read_bytes("src/reinforcement.lua")
    test_source = read_bytes("tests/state_machine.lua")

    runner = lua.eval("function(src) return assert(loadstring(src, '@state_machine'))() end")(
        test_source)
    if runner is None:
        print("测试文件没有 return 出运行函数")
        return 1

    version = lua.eval("jit and jit.version or _VERSION")
    if isinstance(version, bytes):
        version = version.decode("ascii", "replace")
    print("运行时：%s\n" % version)

    failures = runner(reader_source)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
