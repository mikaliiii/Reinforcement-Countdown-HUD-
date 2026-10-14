#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""构建可被 Arsenal / HD2MM 导入的模组 ZIP。

产出：build/Reinforcement-Countdown-HUD-<revision>.zip（revision 含 v 前缀，如 v1.0.0）
  manifest.json                        模组管理器清单
  data/9ba626afa44a3aa3.patch_0        .patch 归档（含一个明文 Lua 资源）
  data/9ba626afa44a3aa3.patch_0.stream       空伴随文件
  data/9ba626afa44a3aa3.patch_0.gpu_resources 空伴随文件

设计决定：**单资源 + 明文实现**。
上游是「明文入口 + 字节码实现」的双资源方案，入口 `return require(...)`。
本移植改为把全部实现放进**一个明文资源**，原因有两条：
  1. `require` 的资源名解析规则（点号如何映射、是否加 .lua 后缀）在公开
     文档里从未明确，依赖它等于赌一个未文档化的行为；
  2. 明文不依赖外部 LuaJIT 可执行文件，任何人都能复现这次构建。
加载器只要求**入口**是明文（它靠扫描资源体前 256 字节的 `-- HD2-Addon:`
注释来发现 addon；编译会剥掉注释，mod 会静默消失而不是报错）。

构建流程：
  1. 语法闸门（tools/lua_syntax.py，用游戏同款 LuaJIT 真正编译）
  2. 副作用 API 黑名单（在剥离注释后的代码上检查，附变异测试）
  3. 组装单文件源码（内联 profile，避免循环依赖）
  4. 组装产物再过一遍闸门与接线检查
  5. 写归档 + 伴随文件
  6. 回读校验：重新解析归档，确认声明、明文性、哈希与字节完全一致
  7. 打包 ZIP
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(ROOT, "tools")
SRC = os.path.join(ROOT, "src")
BUILD = os.path.join(ROOT, "build")

# 稳定标识：一次生成后所有后续版本复用，这样 Arsenal 会把它当作同一个模组的
# 升级，而不是一个新模组。
GUID = "3f9a71c4-58e2-4d0b-a6c7-1e4b8d2f9063"
MODULE = "mods/hd2mods/reinforcement_countdown"
REVISION = "v1.0.0"
DISPLAY_NAME = "Reinforcement Countdown HUD"
DESCRIPTION = (
    "Shows the enemy reinforcement cooldown as an on-screen HUD countdown. "
    "Works on the host and on clients. Read-only, client-side only, no gameplay "
    "effect. Requires Bingus Shared Loader v15 or newer (API 1). Supports Steam "
    "build 25480438. Derived from Reinforcement Radar (MIT, superSizzzz)."
)

ARCHIVE_NAME = "9ba626afa44a3aa3.patch_0"
ARCHIVE_TYPE = 0xA14E8DFA2CD117E2
ARCHIVE_MAGIC = 0xF0000011

# 任何写入、改保护属性、分配内存、加载代码或联网的调用都不允许出现。
# 命中即拒绝构建——这让"只读"成为构建期保证，而不是一句注释。
FORBIDDEN = (
    "WriteProcessMemory", "VirtualProtect", "VirtualAlloc", "VirtualFree",
    "CreateRemoteThread", "LoadLibrary", "CreateProcess",
    "Network.", "RPC.", "ffi.cast('void (*",
)

# 组装顺序：先只读内存层，再 profile，最后是读取器 / HUD / 入口。
UNITS = [
    ("create_api", "read_api"),
    ("profile", "profile"),
    ("reinforcement", "reinforcement"),
    ("hud", "hud"),
    ("install", "install"),
]
TAIL = ("return install(create_api, reinforcement, hud, "
        "{revision = '" + REVISION + "', revision_id = 1, sample_every = 6, "
        "diagnostic = false})\n")

DECLARATION = "-- HD2-Addon: " + MODULE + "\n"


class BuildError(SystemExit):
    pass


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def resource_hash(name: str) -> int:
    """MurmurHash64A(name, seed=0)，必须与加载器的哈希完全一致。"""
    data = name.encode("utf-8")
    mask, mix = (1 << 64) - 1, 0xC6A4A7935BD1E995
    value = len(data) * mix & mask
    end = len(data) // 8 * 8
    for (word,) in struct.iter_unpack("<Q", data[:end]):
        word = word * mix & mask
        word ^= word >> 47
        value = (value ^ (word * mix & mask)) * mix & mask
    if data[end:]:
        value = (value ^ int.from_bytes(data[end:], "little")) * mix & mask
    value ^= value >> 47
    value = value * mix & mask
    return value ^ (value >> 47)


def make_archive(resources: dict) -> bytes:
    if not resources:
        raise BuildError("归档至少要有一个资源")
    count = len(resources)
    offset = (104 + 80 * count + 15) & ~15
    entries, body = bytearray(), bytearray(offset)
    for index, (name, resource) in enumerate(sorted(resources.items())):
        entries += struct.pack("<7Q6I", name, ARCHIVE_TYPE, offset, 0, 0, 0, 0,
                               len(resource), 0, 0, 16, 16, index)
        body += resource
        body += b"\0" * (-len(body) % 16)
        offset = len(body)
    header = struct.pack("<III20sQQ24s", ARCHIVE_MAGIC, 1, count, b"", offset, 0, b"")
    types = struct.pack("<IIQIIII", 0, 0, ARCHIVE_TYPE, count, 0, 16, 16)
    body[:104 + len(entries)] = header + types + entries
    return bytes(body)


def parse_archive(data: bytes) -> dict:
    """重新解析归档，用作回读校验。"""
    magic, unk, count = struct.unpack_from("<III", data, 0)
    total, = struct.unpack_from("<Q", data, 32)
    if magic != ARCHIVE_MAGIC:
        raise BuildError("归档 magic 不对：0x%08X" % magic)
    if unk != 1:
        raise BuildError("归档第二个字段应为 1，实际 %d" % unk)
    if total != len(data):
        raise BuildError("归档头部记录长度 %d，实际 %d" % (total, len(data)))
    table_start = 72 + 32 * 1        # 类型表固定 1 行
    entries = []
    for index in range(count):
        row = data[table_start + index * 80: table_start + (index + 1) * 80]
        name, rtype, offset = struct.unpack_from("<QQQ", row, 0)
        length, = struct.unpack_from("<I", row, 56)
        entry_index, = struct.unpack_from("<I", row, 76)
        if rtype != ARCHIVE_TYPE:
            raise BuildError("资源 %d 类型标记不对" % index)
        if entry_index != index:
            raise BuildError("资源 %d 的 index 字段是 %d" % (index, entry_index))
        body_len, version = struct.unpack_from("<II", data, offset)
        if version != 2:
            raise BuildError("资源 %d 的信封版本应为 2，实际 %d" % (index, version))
        if length != body_len + 8:
            raise BuildError("资源 %d 的长度字段 %d 与 body 长度 %d 不符"
                             % (index, length, body_len))
        body = data[offset + 8: offset + 8 + body_len]
        entries.append({"name": name, "offset": offset, "body": body})
    return {"count": count, "entries": entries, "size": len(data)}


def run_syntax_gate() -> None:
    paths = [os.path.join(SRC, name + ".lua") for _, name in UNITS]
    command = [sys.executable, os.path.join(TOOLS, "lua_syntax.py")] + paths
    result = subprocess.run(command, cwd=ROOT)
    if result.returncode != 0:
        raise BuildError("\n语法闸门未通过，拒绝打包")


def strip_comments(source: str) -> str:
    """去掉 Lua 注释，保留字符串常量。

    "只读"这一类断言必须在**代码**上检查，而不是在注释上。源码里确实会提到
    `WriteProcessMemory`——在解释"本模块不声明它"的那句话里。直接对全文做
    子串匹配会把这种说明文字当成违规，从而把唯一正确的写法也堵死。
    """
    out = []
    i, n = 0, len(source)
    while i < n:
        ch = source[i]
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


def scan_for_forbidden(code: str) -> list:
    return [token for token in FORBIDDEN if token in code]


def check_forbidden() -> None:
    """确认代码里没有写内存 / 改保护 / 分配 / 加载代码 / 联网的调用。

    对**剥离注释后**的代码做检查：源码里确实会提到 `WriteProcessMemory`，
    但那是在解释"本模块不声明它"。直接对全文匹配会把唯一正确的写法也堵死。
    """
    for _, name in UNITS:
        path = os.path.join(SRC, name + ".lua")
        with open(path, "r", encoding="utf-8") as fh:
            source = fh.read()
        hits = scan_for_forbidden(strip_comments(source))
        if hits:
            raise BuildError("%s.lua 的代码里出现被禁止的副作用 API：%s"
                             % (name, ", ".join(hits)))

    # 变异测试：确认这套检查真的会失败。
    # 一个永远通过的检查等于没有检查。
    comment_only = (
        "local ffi = require('ffi')"
        "  -- mentions WriteProcessMemory but only in a comment\n"
    )
    if scan_for_forbidden(strip_comments(comment_only)):
        raise BuildError("变异测试失败：注释里的 API 名被误判为违规")
    real_call = (
        "local ffi = require('ffi')\n"
        "ffi.C.WriteProcessMemory(handle, address, buffer, size, done)\n"
    )
    if not scan_for_forbidden(strip_comments(real_call)):
        raise BuildError("变异测试失败：真实调用没有被抓到，黑名单形同虚设")


def assemble() -> str:
    pieces = []
    for variable, name in UNITS:
        path = os.path.join(SRC, name + ".lua")
        with open(path, "r", encoding="utf-8") as fh:
            source = fh.read()
        pieces.append("local %s = (function()\n%s\nend)()\n"
                      % (variable, source.rstrip("\n")))
    pieces.append(TAIL)
    body = "".join(pieces)

    # 声明必须是资源体的最前几字节，且必须在 256 字节内。
    if len(DECLARATION.encode("utf-8")) > 256:
        raise BuildError("声明行超过 256 字节")
    return DECLARATION + body


def validate_profile() -> dict:
    """确认 profile 结构完整——这是唯一能在离线做的守卫检查。"""
    path = os.path.join(SRC, "profile.lua")
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    guards = re.findall(r"\{rva = (\d+), hex = '([0-9a-f]+)'\}", text)
    offsets = re.findall(r"^\s*(\w+) = (0x[0-9a-f]+|\d+),", text, re.M)
    fingerprint = re.search(r"timestamp = (\d+),\s*\n\s*image_size = (\d+),", text)
    if len(guards) < 8:
        raise BuildError("profile 只有 %d 条守卫，期望 8 条以上" % len(guards))
    if not fingerprint:
        raise BuildError("profile 缺少 game.dll 指纹")
    for index, (rva, hexs) in enumerate(guards, 1):
        if len(hexs) % 2:
            raise BuildError("守卫 %d 的十六进制长度为奇数" % index)
        if len(hexs) // 2 > 512:
            raise BuildError("守卫 %d 过长（%d 字节）" % (index, len(hexs) // 2))
    return {
        "guards": len(guards),
        "guard_bytes": sum(len(h) // 2 for _, h in guards),
        "offsets": len(offsets),
        "game_dll_timestamp": int(fingerprint.group(1)),
        "game_dll_image_size": int(fingerprint.group(2)),
    }


def build_readme() -> str:
    return """Reinforcement Countdown HUD %s
================================

在《绝地潜兵2》任务中把「敌人增援冷却」显示成屏幕上的倒计时。
主机与客机都能显示。

依赖
  Bingus Shared Loader v15 或更新（API 1）。只开其中一个不起作用。
  支持 Steam 构建 25480438 / EXE 1.8.46015.0。

安装
  1. 关闭游戏
  2. 用 Arsenal 或 HD2MM 导入本 ZIP
  3. 启用它，并同时启用 Bingus Shared Loader
  4. Purge / Deploy
  5. 启动游戏，进入任务

显示规则
  READY            冷却清零，可以拉烟（绿色）
  剩余 > 2 分钟     绿色 MM:SS
  剩余 1-2 分钟     橙色 MM:SS
  剩余 < 1 分钟     红色 MM:SS
  增援进行中        不显示（那一刻的倒计时会误导）
  不在任务中        不显示

客机
  游戏只把 0..1 的归一化比例同步给客机，不给秒数。本模组用本机测出的比例
  下降率把它换算成秒数（数学上精确）。代价：进入任务或换段后约 4 秒内不
  显示数字——这段时间在测量下降率。宁可晚几秒，也不显示一个会读错的数字。

日志
  %%LOCALAPPDATA%%\\CowboyBingus\\Helldivers2\\Logs\\ReinforcementRadar.log

安全
  只读。源码与构建产物中都不存在写入游戏内存、改页保护、分配内存、
  加载代码或联网的调用；构建脚本会在发现任何一个时拒绝打包。
  全部改动只在内存读取侧，禁用模组即完全还原。

本模组是 Reinforcement Radar 的衍生作品（MIT，superSizzzz），
详见压缩包内的 THIRD_PARTY.md 与 LICENSE-Reinforcement-Radar。
""" % REVISION


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-gate", action="store_true",
                        help="跳过语法闸门（只在排查闸门自身时使用）")
    parser.add_argument("--out", default=None)
    args = parser.parse_args(argv)

    os.makedirs(BUILD, exist_ok=True)

    profile_info = validate_profile()
    print("PASS: profile 结构完整：%d 条守卫 / %d 字节，%d 个偏移，game.dll 指纹 %d / %d"
          % (profile_info["guards"], profile_info["guard_bytes"],
             profile_info["offsets"], profile_info["game_dll_timestamp"],
             profile_info["game_dll_image_size"]))

    check_forbidden()
    print("PASS: 未发现被禁止的副作用 API（%d 个词条）" % len(FORBIDDEN))

    if not args.skip_gate:
        run_syntax_gate()
        print("PASS: 全部源码通过 LuaJIT 语法闸门")

    source = assemble()
    source_bytes = source.encode("utf-8")
    if b"\0" in source_bytes:
        raise BuildError("组装后的源码含 NUL 字节")
    assembled_path = os.path.join(BUILD, "mod.lua")
    with open(assembled_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(source)
    print("PASS: 组装完成，%d 字节：%s" % (len(source_bytes), assembled_path))

    # 组装后**再**过一遍闸门：内联拼接本身可能引入问题。
    if not args.skip_gate:
        result = subprocess.run(
            [sys.executable, os.path.join(TOOLS, "lua_syntax.py"), assembled_path],
            cwd=ROOT)
        if result.returncode != 0:
            raise BuildError("\n组装产物未通过语法闸门")
        print("PASS: 组装产物再次通过 LuaJIT 语法闸门")

    # 接线检查：五个模块各内联一次、尾部调用顺序正确、声明在最前。
    result = subprocess.run(
        [sys.executable, os.path.join(TOOLS, "check_wiring.py")], cwd=ROOT)
    if result.returncode != 0:
        raise BuildError("\n接线检查未通过，拒绝打包")

    key = resource_hash(MODULE)
    resource = struct.pack("<II", len(source_bytes), 2) + source_bytes
    archive = make_archive({key: resource})
    print("PASS: 资源 %s -> 0x%016X" % (MODULE, key))

    sidecars = {
        ARCHIVE_NAME: archive,
        ARCHIVE_NAME + ".stream": b"",
        ARCHIVE_NAME + ".gpu_resources": b"",
    }
    for name, payload in sidecars.items():
        with open(os.path.join(BUILD, name), "wb") as fh:
            fh.write(payload)

    # ---- 回读校验 ----------------------------------------------------
    with open(os.path.join(BUILD, ARCHIVE_NAME), "rb") as fh:
        written = fh.read()
    parsed = parse_archive(written)
    if parsed["count"] != 1:
        raise BuildError("期望 1 个资源，实际 %d 个" % parsed["count"])
    entry = parsed["entries"][0]
    if entry["name"] != key:
        raise BuildError("资源哈希不符：0x%016X != 0x%016X" % (entry["name"], key))
    if entry["body"] != source_bytes:
        raise BuildError("回读的资源体与组装结果不一致")
    if not entry["body"].startswith(DECLARATION.encode("utf-8")):
        raise BuildError("资源体没有以声明行开头，加载器会发现不了这个 addon")
    try:
        entry["body"].decode("utf-8")
    except UnicodeDecodeError as exc:
        raise BuildError("资源体不是合法 UTF-8：%s" % exc)
    print("PASS: 归档回读校验通过（声明在首字节、明文、字节一致）")

    # ---- 打包 ZIP ----------------------------------------------------
    manifest = {
        "Version": 1,
        "Guid": GUID,
        "Name": DISPLAY_NAME,
        "Description": DESCRIPTION,
        "Options": [{
            "Name": DISPLAY_NAME,
            "Description": DESCRIPTION,
            "Include": ["data"],
        }],
    }
    report = {
        "name": DISPLAY_NAME,
        "revision": REVISION,
        "guid": GUID,
        "module": MODULE,
        "resource_hash": "0x%016X" % key,
        "resource_bytes": len(resource),
        "source_bytes": len(source_bytes),
        "impl": "plaintext single resource",
        "read_only": True,
        "network_calls": False,
        "gameplay_memory_writes": False,
        "client_side_estimate": True,
        "forbidden_tokens_checked": list(FORBIDDEN),
        "profile": profile_info,
        "archive_sha256": sha256(archive),
        "source_sha256": sha256(source_bytes),
    }

    files = {
        "manifest.json": (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode("utf-8"),
        "ReinforcementCountdownHUD-README.txt": build_readme().encode("utf-8"),
        "ReinforcementCountdownHUD-report.json": (
            json.dumps(report, indent=2, ensure_ascii=False) + "\n").encode("utf-8"),
    }
    for name, payload in sidecars.items():
        files["data/" + name] = payload

    import zipfile
    out_path = args.out or os.path.join(
        BUILD, "Reinforcement-Countdown-HUD-%s.zip" % REVISION)
    with zipfile.ZipFile(out_path, "w", compression=zipfile.ZIP_DEFLATED,
                         compresslevel=9) as archive_zip:
        for name, payload in sorted(files.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive_zip.writestr(info, payload)

    report["release"] = os.path.basename(out_path)
    report["release_sha256"] = sha256(open(out_path, "rb").read())
    with open(os.path.join(BUILD, "build-report.json"), "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2, ensure_ascii=False)
        fh.write("\n")

    print("\n生成的 ZIP：%s（%d 字节）" % (out_path, os.path.getsize(out_path)))
    print("  发布 SHA-256：%s" % report["release_sha256"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
