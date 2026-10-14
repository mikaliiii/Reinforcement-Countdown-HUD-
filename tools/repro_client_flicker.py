#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""用 v1.2.2 实机日志的真实参数复现「客机极少锁定、数字乱跳」。

实机观测（v1.2.2 客机段）：
  rate ≈ 2.842378，fraction 每 0.078431 一步 …… 实际相邻档位差 0.039216
  某一段冷却里 fraction 0.627451 -> 0 用时约 51 秒 => 总时长约 77.4 秒
  134 条诊断里只有 6 条 locked、1 条 ready

怀疑：包络的"回升判据"（fraction > 预期 + JITTER）在**阶梯信号**上误触。
fraction 是台阶，而包络按斜率线性外推，两者之间的差会随时间单调拉大；
JITTER 只有 0.002，累积超过它只是两三秒的事 —— 于是一到那里就清空历史，
永远攒不满 4 秒窗口。
"""
from __future__ import annotations

import glob
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, sorted(glob.glob(os.path.join(ROOT, "vendor", "lupa-*")))[0])
from lupa.luajit21 import LuaRuntime

HARNESS = r"""
return function(reader_source, total, rate, level_count, update_hz)
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
    p32(SLOTS, 0xABCD); p32(DESC + 8, 0xABCD); p32(DESC + 20, 0)
    p64(MGR + OFF.manager_descriptor, DESC)
    p32(MGR + OFF.pending_count, 0)
    p32(PACE + OFF.pacing_blockers, 0)
    pf32(PACE + OFF.pacing_rate, rate)
    pf32(MGR + OFF.cooldown_seconds_raw, 0)

    local profile = {game_dll = {timestamp = 1790161983, image_size = 74727424},
                     guards = {{rva = 0x200, hex = GUARD}}, offsets = OFF,
                     globals = {reinforcement = GR, pacing = GP}}
    local factory = assert(loadstring(reader_source, '@r'))()
    local reader = factory(api, profile, function() end)

    -- 阶梯：fraction 只在主机下发时刻变化，且是量化档位（level_count 档）
    local update_dt = 1 / update_hz
    local sample_dt = 0.05
    local next_update = -1e9
    local counts = {measuring = 0, locked = 0, ready = 0, unknown = 0, paused = 0}
    local seconds_values = {}
    local lock_times = {}
    local max_span, max_hist, fail_samples = -1, 0, 0
    local prev_hist, cleared_at = nil, nil
    local fit_fail, reported = nil, false
    local t = 0
    while t <= total + 2 do
        CLOCK = t                       -- 采样时刻与推进的时间必须是同一个
        if t >= next_update then
            next_update = next_update + update_dt
            local raw = 1 - t / total
            -- 量化到 level_count 档，模拟主机下发的离散值
            local q = math.floor(raw * level_count + 0.5) / level_count
            if q < 0 then q = 0 end
            pf32(MGR + OFF.cooldown_fraction, q)
        end
        local r = reader.sample()
        local cs = tostring(r.client_state)
        counts[cs] = (counts[cs] or 0) + 1
        if r.client_state == nil and not reported then
            reported = true
            print('   [异常] sample() 返回：status=' .. tostring(r.status)
                .. ' reason=' .. tostring(r.reason))
        end
        local probe = reader.history_probe()
        if probe then
            if probe.n > max_hist then max_hist = probe.n end
            -- 抓历史被清空的那一瞬间
            if prev_hist and probe.n < prev_hist and not cleared_at then
                cleared_at = {t = t, before = prev_hist, after = probe.n,
                    state = cs, rebind = probe.rebind_count}
            end
            prev_hist = probe.n
            if probe.fit then fit_fail = probe.fit end
            if probe.fail then
                fail_samples = fail_samples + 1
                if probe.fail.span and probe.fail.span > max_span then
                    max_span = probe.fail.span
                end
            end
        end
        if r.seconds and r.seconds > 0 then
            seconds_values[#seconds_values + 1] = {t = t, s = r.seconds}
        end
        if cs == 'locked' and #lock_times < 8 then lock_times[#lock_times + 1] = t end
        t = t + sample_dt
    end

    print(string.format('  参数：总时长 %.1f 秒  rate=%.6f  档数=%d  主机下发 %.1f Hz  采样 %.0f Hz',
        total, rate, level_count, update_hz, 1 / sample_dt))
    -- 结束时读内部状态：如果从未锁定，这里会说明卡在哪一步
    print(string.format('  内部最大值：history 条数峰值=%d  跨度门槛失败次数=%d  失败时的最大 span=%.6f',
        max_hist, fail_samples, max_span))
    local hist = reader.history_probe and reader.history_probe() or nil
    if hist then
        print(string.format('  最终历史：条数=%d level_width=%s rate=%s fit_rms=%s',
            hist.n, tostring(hist.level_width), tostring(hist.rate),
            tostring(hist.fit_rms)))
        if hist.fail then
            print(string.format('  卡在跨度门槛：need=%.4f  实际 span=%s  history=%s  最旧记录年龄=%.1f 秒',
                hist.fail.need, tostring(hist.fail.span), tostring(hist.fail.history),
                hist.fail.oldest_age))
        end
        print(string.format('  「回升判据」误触次数 = %s', tostring(hist.rebind_count)))
        if fit_fail then
            print(string.format('  拟合阶段失败：why=%s  %s', tostring(fit_fail.why),
                fit_fail.why == 'residual'
                    and string.format('rms=%.6f tol=%.6f levels=%.1f count=%d',
                        fit_fail.rms, fit_fail.tol, fit_fail.levels, fit_fail.count)
                    or string.format('rate=%.6f span=%.5f count=%d levels=%.1f',
                        fit_fail.rate or -1, fit_fail.span or -1, fit_fail.count or -1,
                        fit_fail.levels or -1)))
        end
        if cleared_at then
            print(string.format('  历史首次被清空：t=%.2f 从 %d 条变成 %d 条 (state=%s, rebind_count=%s)',
                cleared_at.t, cleared_at.before, cleared_at.after,
                cleared_at.state, tostring(cleared_at.rebind)))
        end
        if hist.rebind then
            print(string.format('     最后一次误触：clock=%.2f fraction=%.6f 预期=%.6f 差=%.6f 容差=%.4f',
                hist.rebind.clock, hist.rebind.fraction, hist.rebind.expected,
                hist.rebind.gap, hist.rebind.jitter))
        end
    end
    print(string.format('  client_state 分布：measuring=%d  locked=%d  ready=%d  unknown=%d',
        counts.measuring or 0, counts.locked or 0, counts.ready or 0, counts.unknown or 0))
    if #lock_times > 0 then
        local s = {}
        for i, v in ipairs(lock_times) do s[i] = string.format('%.1f', v) end
        print('  前几次锁定时刻：t=' .. table.concat(s, ', '))
    else
        print('  **从未锁定** —— 与实机现象一致')
    end
    if #seconds_values > 0 then
        local bits = {}
        for i = 1, math.min(12, #seconds_values) do
            bits[i] = tostring(seconds_values[i].s)
        end
        print('  给出的秒数（前 12 个）：' .. table.concat(bits, ', '))
        local deltas = {}
        for i = 2, math.min(14, #seconds_values) do
            deltas[#deltas + 1] = seconds_values[i].s - seconds_values[i - 1].s
        end
        if #deltas > 0 then
            print('  相邻差值：' .. table.concat(deltas, ', ')
                .. '   （正常应约 -1~-2）')
        end
    else
        print('  从未给出秒数')
    end
    return counts.locked or 0
end
"""


def main() -> int:
    lua = LuaRuntime(encoding=None)
    with open(os.path.join(ROOT, "src", "reinforcement.lua"), "rb") as fh:
        source = fh.read()
    runner = lua.eval("function(src) return assert(loadstring(src, '@h'))() end")(
        HARNESS.encode("utf-8"))
    # 实机参数：总时长 77.4 秒、rate 2.842378、fraction 是 1/255 档、主机约 2 Hz 下发
    locks = runner(source, 77.4, 2.842378, 255, 2.1)
    print()
    print("锁定帧数 = %d" % locks)
    return 0 if locks > 100 else 1


if __name__ == "__main__":
    sys.exit(main())
