#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""检查本机安装的游戏是否是本模组支持的那个构建 / Check the installed build.

模组只支持 Steam 构建 25480438。游戏一旦更新，读取器会主动拒绝工作
（它不会按已经不成立的偏移去读）。本脚本让你不必先装模组、先进游戏、
再看日志，就能提前确认。

它读取（只读，不启动游戏）：
  <游戏目录>/bin/helldivers2.exe      的 SHA-256
  <游戏目录>/data/game/game.dll       的 SHA-256，以及 PE 的 TimeDateStamp /
                                      SizeOfImage（模组运行时校验的就是这两个值）

注意：模组运行时校验的是**内存里**的 8 条原生代码签名，那些无法离线核对
——game.dll 的代码段在磁盘上是压缩的，只有加载进内存才展开。所以即使本脚本
全部通过，仍需进游戏确认一次。

用法：
    python tools/check_build.py
    python tools/check_build.py "D:\\SteamLibrary\\steamapps\\common\\Helldivers 2"
    HD2_GAME_ROOT="..." python tools/check_build.py
"""
from __future__ import annotations

import hashlib
import os
import re
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 上游实测确定的期望值。
EXPECTED_EXE_SHA = "F5FEE03DCFDB2E553A4752C283590950AC13316B376D8196AA556FF0400D5F06"
EXPECTED_DLL_SHA = "2E2C3B7C2500646DADD5F2B4C6E0504DBB7E7896139F64CDDC0D1813C718F51E"
EXPECTED_TIMESTAMP = 1790161983
EXPECTED_IMAGE_SIZE = 74727424

DEFAULT_CANDIDATES = [
    r"D:\SteamLibrary\steamapps\common\Helldivers 2",
    r"C:\SteamLibrary\steamapps\common\Helldivers 2",
    r"C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2",
    r"E:\SteamLibrary\steamapps\common\Helldivers 2",
    r"F:\SteamLibrary\steamapps\common\Helldivers 2",
]


def sha256_of(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest().upper()


def pe_fingerprint(path: str):
    with open(path, "rb") as fh:
        head = fh.read(4096)
        if head[:2] != b"MZ":
            raise ValueError("不是 PE 文件（缺少 MZ）")
        pe = struct.unpack_from("<I", head, 60)[0]
        if pe + 84 > len(head):
            fh.seek(pe)
            block = fh.read(128)
        else:
            block = head[pe:]
        if block[:4] != b"PE\0\0":
            raise ValueError("没有 PE 签名")
        timestamp = struct.unpack_from("<I", block, 8)[0]
        image_size = struct.unpack_from("<I", block, 24 + 56)[0]
    return timestamp, image_size


def profile_fingerprint() -> tuple:
    """从 src/profile.lua 读出模组实际会校验的指纹，避免两处写死走偏。"""
    path = os.path.join(ROOT, "src", "profile.lua")
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    match = re.search(r"timestamp = (\d+),\s*\n\s*image_size = (\d+),", text)
    if not match:
        raise SystemExit("无法从 src/profile.lua 读出 game.dll 指纹")
    guards = re.findall(r"\{rva = (\d+), hex = '([0-9a-f]+)'\}", text)
    return int(match.group(1)), int(match.group(2)), guards


def find_game_root(explicit: str | None) -> str | None:
    if explicit:
        return explicit if os.path.isdir(explicit) else None
    env = os.environ.get("HD2_GAME_ROOT")
    if env and os.path.isdir(env):
        return env
    for candidate in DEFAULT_CANDIDATES:
        if os.path.isdir(candidate):
            return candidate
    return None


def main(argv=None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    root = find_game_root(args[0] if args else None)
    if not root:
        print("找不到游戏目录。请显式指定，或设置 HD2_GAME_ROOT：")
        print('  python tools/check_build.py "D:\\SteamLibrary\\steamapps\\'
              'common\\Helldivers 2"')
        print("\n已尝试的默认位置：")
        for candidate in DEFAULT_CANDIDATES:
            print("  " + candidate)
        return 2

    print("游戏目录：%s\n" % root)
    timestamp, image_size, guards = profile_fingerprint()
    print("模组支持的构建：")
    print("  game.dll TimeDateStamp = %d" % timestamp)
    print("  game.dll SizeOfImage   = %d" % image_size)
    print("  原生代码守卫           = %d 条（需进游戏后才能核对）\n" % len(guards))

    problems = 0

    exe = os.path.join(root, "bin", "helldivers2.exe")
    if not os.path.isfile(exe):
        print("FAIL 找不到 %s" % exe)
        problems += 1
    else:
        print("  helldivers2.exe SHA-256 ...", end=" ")
        actual = sha256_of(exe)
        if actual == EXPECTED_EXE_SHA:
            print("匹配")
        else:
            problems += 1
            print("不匹配\n      实际 %s\n      期望 %s" % (actual, EXPECTED_EXE_SHA))

    dll = os.path.join(root, "data", "game", "game.dll")
    if not os.path.isfile(dll):
        print("FAIL 找不到 %s" % dll)
        problems += 1
    else:
        print("  game.dll SHA-256 .........", end=" ")
        actual = sha256_of(dll)
        if actual == EXPECTED_DLL_SHA:
            print("匹配")
        else:
            problems += 1
            print("不匹配\n      实际 %s\n      期望 %s" % (actual, EXPECTED_DLL_SHA))

        print("  game.dll PE 指纹 .........", end=" ")
        try:
            got_timestamp, got_image_size = pe_fingerprint(dll)
        except ValueError as exc:
            problems += 1
            print("读取失败：%s" % exc)
        else:
            if (got_timestamp, got_image_size) == (timestamp, image_size):
                print("匹配")
            else:
                problems += 1
                print("不匹配")
                print("      实际 timestamp=%d image_size=%d"
                      % (got_timestamp, got_image_size))
                print("      期望 timestamp=%d image_size=%d"
                      % (timestamp, image_size))

    print()
    if problems:
        print("结论：本机构建不受支持（%d 项不符）。" % problems)
        print("模组装上去也不会工作——读取器会主动拒绝，只在日志里写明原因。")
        print("请等待模组更新到你的构建，或把游戏回退到受支持的构建。")
        return 1
    print("结论：磁盘上的构建与模组一致。")
    print("还差最后一步：进游戏跑一次，确认日志里出现「构建校验通过」。")
    print("（8 条原生代码守卫只能在内存里核对，磁盘文件是压缩的。）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
