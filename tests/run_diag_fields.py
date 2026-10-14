#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""跑诊断字段测试 / Run the diagnostic-field test.

只测读取器那一半：客机分支下 diag_* 字段是否被正确填充。
日志落盘归安装层管，由 tests/run_install_diag.py 单独覆盖。
"""
from __future__ import annotations

import glob
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main() -> int:
    root = None
    for pattern in (os.path.join(ROOT, "vendor", "lupa-*"),
                    os.path.join(os.path.dirname(ROOT), "vendor", "lupa-*")):
        found = sorted(glob.glob(pattern))
        if found:
            root = found[0]
            break
    if not root:
        print("找不到 lupa，请先运行 tools/vendor_lupa.py")
        return 2
    sys.path.insert(0, root)
    from lupa.luajit21 import LuaRuntime  # type: ignore

    lua = LuaRuntime(encoding=None)

    with open(os.path.join(ROOT, "src", "reinforcement.lua"), "rb") as fh:
        state_source = fh.read()
    with open(os.path.join(ROOT, "tests", "diag_fields.lua"), "rb") as fh:
        test_source = fh.read()

    version = lua.eval("jit and jit.version or _VERSION")
    if isinstance(version, bytes):
        version = version.decode("ascii", "replace")
    print("运行时：%s\n" % version)

    runner = lua.eval("function(src) return assert(loadstring(src, '@diag'))() end")(test_source)
    if runner is None:
        print("测试文件没有 return 出运行函数")
        return 1
    failures = runner(state_source)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
