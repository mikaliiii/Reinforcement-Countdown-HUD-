#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""用日志里的真实时序复现「客机一直 measuring」。

实机观测（v1.2.1 客机段）：
  rate ≈ 2.97，fraction 从中段 0.384 降到 0 用了约 54 秒
  => slope ≈ 1/140 每秒（按 fraction 单位）
  相邻 DIAG 行间隔中位数 1.0 秒（诊断落盘一次约 1 秒）
  但模组内部每 6 帧采样一次（约 0.1 秒）

本脚本让读取器按 0.1 秒采样、按 1 秒节奏变化 fraction，看它能否锁定。
"""
from __future__ import annotations

import glob
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, sorted(glob.glob(os.path.join(ROOT, "vendor", "lupa-*")))[0])
from lupa.luajit21 import LuaRuntime

HARNESS = r"""
return function(reader_source)
    local MIN, MAX = 65536, 0x100000
    local RAM = {}
    local function poke(a, b) for i = 1, #b do RAM[a + i - 1] = b:byte(i) end end
    local function peek(a, n)
        if a < MIN or a + n > MAX then return nil end
        local o = {}
        for i = 0, n - 1 do o[#o + 1] = string.char(RAM[a + i] or 0) end
        return table.concat(o)
    end
    local function p32(a, v) poke(a, string.char(v % 256, math.floor(v / 256) % 256,
        math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)) end
    local function p64(a, v) p32(a, v % 4294967296); p32(a + 4, math.floor(v / 4294967296)) end
    local function f32b(v)
        if v == 0 then return '\0\0\0\0' end
        local s = 0; if v < 0 then s, v = 128, -v end
        local e = math.floor(math.log(v) / math.log(2))
        local m = math.floor((v / 2 ^ e - 1) * 8388608 + 0.5)
        if m >= 8388608 then m, e = 0, e + 1 end
        local bits = s * 16777216 + (e + 127) * 8388608 + m
        return string.char(bits % 256, math.floor(bits / 256) % 256,
            math.floor(bits / 65536) % 256, math.floor(bits / 16777216) % 256)
    end
    local function pf32(a, v) poke(a, f32b(v)) end
    local function rs(a, n)
        local b = peek(a, n); if not b then return nil end
        local v = 0; for i = n, 1, -1 do v = v * 256 + b:byte(i) end; return v
    end
    local CLOCK = 0
    local api = {}
    function api.time() return CLOCK end
    function api.module(n) if n == 'game.dll' then return 0x10000 end return nil end
    function api.read(a, n)
        if type(a) ~= 'number' or type(n) ~= 'number' or n < 1 or n > 2097152 then return nil end
        return peek(a, n)
    end
    function api.u32(a) return rs(a, 4) end
    function api.u64(a) return rs(a, 8) end
    function api.f32(a)
        local bits = rs(a, 4); if not bits then return nil end
        local s = 1; if bits >= 2147483648 then s, bits = -1, bits - 2147483648 end
        local e = math.floor(bits / 8388608); local m = bits - e * 8388608
        if e == 0 then return m == 0 and s * 0.0 or s * m * 2 ^ -149 end
        return s * (1 + m / 8388608) * 2 ^ (e - 127)
    end
    function api.pointer(a)
        local v = api.u64(a); if v == nil or v < MIN or v >= MAX then return nil end; return v
    end
    function api.finite(v, mx)
        if type(v) ~= 'number' or v ~= v then return false end
        return math.abs(v) <= (mx or 1e6)
    end

    local GAME, GR, GP = 0x10000, 0x2000, 0x2100
    local MGR, DESC, PACE, SLOTS = 0x30000, 0x40000, 0x50000, 0x60000
    local OFF = {manager_entity_map = 0x68, manager_descriptor = 0x80,
                 cooldown_fraction = 0xad0, cooldown_seconds_raw = 0x94,
                 pending_count = 0xa0, pending_item = 0xc4, pending_stride = 0x104,
                 pacing_blockers = 0x934, pacing_rate = 0x924}
    local GUARD = '488bcbe8e5110000f30f5984b3d00a0000488b742438f30f11841f94000000'
    poke(GAME, 'MZ'); p32(GAME + 60, 0x80); poke(GAME + 0x80, 'PE\0\0')
    p32(GAME + 0x88, 1790161983); p32(GAME + 0xD0, 74727424)
    local g = {}
    for pair in GUARD:gmatch('%x%x') do g[#g + 1] = string.char(tonumber(pair, 16)) end
    poke(GAME + 0x200, table.concat(g))
    p64(GAME + GR, MGR); p64(GAME + GP, PACE)
    p32(MGR + OFF.manager_entity_map + 8, 4)
    p64(MGR + OFF.manager_entity_map, SLOTS)
    p32(SLOTS, 0xABCD); p32(DESC + 8, 0xABCD); p32(DESC + 20, 0)   -- 客机
    p64(MGR + OFF.manager_descriptor, DESC)
    p32(MGR + OFF.pending_count, 0)
    p32(PACE + OFF.pacing_blockers, 0)
    pf32(PACE + OFF.pacing_rate, 2.970000)
    pf32(MGR + OFF.cooldown_seconds_raw, 0)      -- 客机 raw 恒为 0

    local profile = {game_dll = {timestamp = 1790161983, image_size = 74727424},
                     guards = {{rva = 0x200, hex = GUARD}}, offsets = OFF,
                     globals = {reinforcement = GR, pacing = GP}}
    local factory = assert(loadstring(reader_source, '@r'))()
    local reader = factory(api, profile, function() end)
    reader.diagnostic = true

    -- 用实机观测的参数驱动：fraction 按 1 秒一格下降，模组按 0.1 秒采样。
    -- 起始 fraction=0.384314，下降到 0 用 54 秒 -> 每秒降 0.007117
    local START, PER_SEC, SAMPLE_DT = 0.384314, 0.007117, 0.1
    local states, first_locked = {}, nil
    local t = 0
    CLOCK = 0
    while t <= 60 do
        local frac = START - PER_SEC * t
        if frac < 0 then frac = 0 end
        pf32(MGR + OFF.cooldown_fraction, frac)
        CLOCK = t
        local r = reader.sample()
        states[#states + 1] = string.format('%.1f %s %s %s', t,
            tostring(r.client_state), tostring(r.seconds), tostring(r.rate_measured))
        if r.seconds and not first_locked then first_locked = t end
        t = t + SAMPLE_DT
    end

    print(string.format('  复现结果：首次给出秒数的时间 = %s 秒',
        first_locked and string.format('%.1f', first_locked) or '（从未给出）'))
    print('  前 20 个采样点：')
    for i = 1, 20 do
        if states[i] then print('    t=' .. states[i]) end
    end
    print('  t=45 之后：')
    for i = #states - 5, #states do
        if states[i] then print('    t=' .. states[i]) end
    end
    return first_locked ~= nil
end
"""


def main() -> int:
    lua = LuaRuntime(encoding=None)
    with open(os.path.join(ROOT, "src", "reinforcement.lua"), "rb") as fh:
        source = fh.read()
    runner = lua.eval("function(src) return assert(loadstring(src, '@h'))() end")(
        HARNESS.encode("utf-8"))
    ok = runner(source)
    print()
    print("锁定成功" if ok else "**未能锁定——复现了实机现象**")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
