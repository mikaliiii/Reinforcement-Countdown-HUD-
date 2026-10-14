#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""LuaJIT (Lua 5.1) 语法闸门 / LuaJIT syntax gate.

游戏跑的是 LuaJIT，即 Lua 5.1。Lua 5.3+ 才有的语法（`//` 整除、位运算符、
`goto`、`utf8` 库等）在现代 Lua 里解析正常，到了游戏里会以
`load failed: unexpected symbol near '/'` 失败——而且要重开一次游戏才能发现。

本脚本用**游戏同款运行时**（lupa 的 luajit21）真正编译每一个源文件。

--self-test 会做变异测试：把每种被禁止的语法塞进样本，要求闸门必须抓到。
一个不会失败的闸门是没有意义的。

用法：
    python tools/lua_syntax.py src/*.lua
    python tools/lua_syntax.py --self-test
"""
from __future__ import annotations

import argparse
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VENDOR = os.path.join(ROOT, "vendor")


def lupa_roots():
    found = sorted(glob.glob(os.path.join(VENDOR, "lupa-*")))
    found += sorted(glob.glob(os.path.join(
        os.path.dirname(ROOT), "vendor", "lupa-*")))
    return found


def load_runtime():
    roots = lupa_roots()
    if not roots:
        return None, None
    sys.path.insert(0, roots[0])
    try:
        from lupa.luajit21 import LuaRuntime  # type: ignore
    except Exception as exc:  # noqa: BLE001
        return None, "cannot import lupa.luajit21: %s" % exc
    # encoding=None：Lua 字符串按原始字节交给 Python，源码里的中文注释才不会
    # 在边界上被 UTF-8 解码炸掉。
    return LuaRuntime(encoding=None), None


def compiler(lua):
    return lua.eval("""function(src, name)
        local chunk, err = loadstring(src, name)
        if chunk == nil then return err end
        return nil
    end""")


# 每一项：(说明, 会被注入的源码片段)
# 两类都必须抓到：编译闸门负责真正的语法错误，词法闸门负责"能编译但在
# LuaJIT 里运行时不存在"的库调用。
MUTATIONS = {
    "整除 //": "local x = 10 // 3\n",
    "位运算 &": "local x = 1 & 2\n",
    "位运算 |": "local x = 1 | 2\n",
    "位移 <<": "local x = 1 << 2\n",
    "math.type": "local t = math.type(1)\n",
    "table.move": "table.move(a, 1, 2, 3)\n",
    "string.pack": "local s = string.pack('i4', 1)\n",
    "utf8 库": "local a = utf8.char(65)\n",
    "_ENV": "local e = _ENV\n",
}

# 这些必须**通过**：注释和字符串里的关键字不算违规；
# `goto` 也不该报错——LuaJIT 2.1 实测支持它。
CLEAN = {
    "注释里出现关键字": "-- 这一行提到 // 和 & 但不该报错\nlocal x = 1\n",
    "字符串里出现关键字": "local s = 'a // b and 1 & 2'\n",
    "比较不是位运算": "local x = 1\nif x >= 1 and x <= 2 then x = x + 1 end\n",
    "手工整除": "local x = math.floor(10 / 3)\n",
    "长字符串": "local s = [[ // & goto ]]\nlocal y = 2\n",
    "拼接不是位移": "local s = 'a' .. 'b'\n",
    "中文注释": "-- 中文注释应该正常通过\nlocal 名 = 1\n",
    "goto 可用": "do goto done end\n::done::\n",
    "math.floor 正常": "local x = math.floor(1.5)\n",
    "table.insert 正常": "table.insert({}, 1)\n",
}


def compile_one(compile_fn, source: bytes, name):
    if isinstance(name, str):
        name = name.encode("ascii", "replace")
    return compile_fn(source, name)


# --------------------------------------------------------------------------
# 词法层检查：编译闸门抓不到的那一类
# --------------------------------------------------------------------------
# `math.type(1)`、`utf8.char(65)` 在 LuaJIT 里能**编译**通过，只在运行时
# 报 "attempt to index a nil value"。所以必须在词法层把它们挑出来。
#
# 注意 `goto` 不在禁止之列：LuaJIT 2.1 实际上支持 goto，实测编译通过。
# 把它列进禁止项会误报，因此这里只列真正不存在的库与函数。
FORBIDDEN_CALLS = {
    ("math", "type"): "math.type 是 Lua 5.3+",
    ("table", "move"): "table.move 是 Lua 5.3+",
    ("string", "pack"): "string.pack 是 Lua 5.3+",
    ("string", "unpack"): "string.unpack 是 Lua 5.3+",
}
FORBIDDEN_NAMES = {
    "utf8": "utf8 库是 Lua 5.3+",
    "_ENV": "_ENV 是 Lua 5.2+，LuaJIT 不支持",
    "bit32": "bit32 是 Lua 5.2；LuaJIT 用 bit",
}

NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
LONG_BRACKET_RE = re.compile(r"\[(=*)\[")


def _tokens(source: str):
    """去掉注释与字符串后的 (文本, 行号) 序列。

    只做词法层剥离，够用即可：注释和字符串里的关键字不会被误判，
    这正是"变异测试抓得住、正常代码不误报"的关键。
    """
    out = []
    i, n, line = 0, len(source), 1
    while i < n:
        ch = source[i]
        if ch == "\n":
            line += 1
            i += 1
            continue
        if ch in " \t\r":
            i += 1
            continue
        if source.startswith("--", i):
            bracket = LONG_BRACKET_RE.match(source, i + 2)
            if bracket:
                close = "]" + "=" * len(bracket.group(1)) + "]"
                end = source.find(close, bracket.end())
                if end < 0:
                    line += source.count("\n", i)
                    i = n
                    continue
                line += source.count("\n", i, end)
                i = end + len(close)
                continue
            end = source.find("\n", i)
            i = n if end < 0 else end
            continue
        if ch == "[":
            # 长字符串 [[...]]
            bracket = LONG_BRACKET_RE.match(source, i)
            if bracket:
                close = "]" + "=" * len(bracket.group(1)) + "]"
                end = source.find(close, bracket.end())
                stop = n if end < 0 else end + len(close)
                line += source.count("\n", i, stop)
                i = stop
                continue
        if ch in "\"'":
            quote, j = ch, i + 1
            while j < n:
                if source[j] == "\\":
                    j += 2
                    continue
                if source[j] == quote or source[j] == "\n":
                    break
                j += 1
            i = j + 1
            continue
        match = NAME_RE.match(source, i)
        if match:
            out.append((match.group(0), line))
            i = match.end()
            continue
        out.append((ch, line))
        i += 1
    return out


def check_lexical(source: str):
    """返回问题列表；空列表表示没问题。"""
    tokens = _tokens(source)
    problems = []
    for index, (text, line) in enumerate(tokens):
        if text in FORBIDDEN_NAMES:
            problems.append((line, FORBIDDEN_NAMES[text]))
            continue
        # 成员访问被拆成 name '.' name，所以要看三连。
        if (index + 2 < len(tokens) and tokens[index + 1][0] == "."
                and (text, tokens[index + 2][0]) in FORBIDDEN_CALLS):
            problems.append((line, FORBIDDEN_CALLS[(text, tokens[index + 2][0])]))
    return problems


def check_all(compile_fn, source: bytes, name: str):
    """编译 + 词法，两关都过才算通过。返回错误文本列表。"""
    errors = []
    lexical = check_lexical(source.decode("utf-8", "replace"))
    for line, why in lexical:
        errors.append("第 %d 行：%s" % (line, why))
    compiled = compile_one(compile_fn, source, name)
    if compiled is not None:
        text = compiled.decode("utf-8", "replace") if isinstance(compiled, bytes) else str(compiled)
        errors.append("编译失败：%s" % text.split("\n")[0])
    return errors


def self_test(compile_fn) -> int:
    failures = 0
    for label, snippet in MUTATIONS.items():
        errors = check_all(compile_fn, snippet.encode("utf-8"), "mutation")
        if not errors:
            print("FAIL  闸门漏掉：%s" % label)
            failures += 1
        else:
            print("ok    抓到 %-16s -> %s" % (label, errors[0]))
    for label, snippet in CLEAN.items():
        errors = check_all(compile_fn, snippet.encode("utf-8"), "clean")
        if errors:
            print("FAIL  误报：%s -> %s" % (label, errors[0]))
            failures += 1
        else:
            print("ok    通过 %-16s" % label)
    if failures:
        print("\n闸门自检失败：%d 项" % failures)
        return 1
    print("\n闸门自检通过（%d 项变异全部抓到，%d 项正常样本全部通过）"
          % (len(MUTATIONS), len(CLEAN)))
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*")
    parser.add_argument("--self-test", action="store_true",
                        help="对闸门本身做变异测试")
    args = parser.parse_args(argv)

    lua, problem = load_runtime()
    if lua is None:
        print("无法加载 LuaJIT：%s" % problem)
        print("请先运行 tools/vendor_lupa.py，或安装 lupa。")
        return 2
    version = lua.eval("jit and jit.version or _VERSION")
    if isinstance(version, bytes):
        version = version.decode("ascii", "replace")
    compile_fn = compiler(lua)

    if args.self_test:
        print("运行时：%s\n" % version)
        return self_test(compile_fn)

    if not args.paths:
        parser.error("至少给一个 .lua 文件，或用 --self-test")

    print("运行时：%s\n" % version)
    failed = False
    for path in args.paths:
        with open(path, "rb") as fh:
            source = fh.read()
        if source.startswith(b"\xef\xbb\xbf"):
            print("FAIL %s\n   文件带 UTF-8 BOM" % path)
            failed = True
            continue
        if source.startswith(b"\x1b"):
            print("FAIL %s\n   这是字节码，不是明文" % path)
            failed = True
            continue
        errors = check_all(compile_fn, source,
                           os.path.basename(path).encode("ascii", "replace"))
        if not errors:
            print("ok   %s" % path)
        else:
            failed = True
            print("FAIL %s" % path)
            for error in errors:
                print("   %s" % error)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
