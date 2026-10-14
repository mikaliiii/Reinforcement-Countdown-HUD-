-- 验证诊断功能：客机分支下，读取器会附带换算所需的原始量。
--
-- 只测读取器这一半（日志落盘由安装层负责，属于另一件事）。
-- 夹具布局与 tests/state_machine.lua 一致，避免两套假内存走偏。

local failures, checks = 0, 0

local function check(condition, label, detail)
    checks = checks + 1
    if condition then
        print(string.format('  ok   %s', label))
    else
        failures = failures + 1
        print(string.format('  FAIL %s%s', label, detail and ('  -- ' .. tostring(detail)) or ''))
    end
end

return function(state_source)
    local MIN, MAX = 65536, 0x100000
    local RAM, CLOCK = {}, 0

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

    -- 摆一局「客机、冷却中」的现场：任务 id 与实体映射表对上，权威位置 0
    RAM = {}
    poke(GAME, 'MZ'); p32(GAME + 60, 0x80); poke(GAME + 0x80, 'PE\0\0')
    p32(GAME + 0x88, 1790161983); p32(GAME + 0xD0, 74727424)
    local g = {}
    for pair in GUARD:gmatch('%x%x') do g[#g + 1] = string.char(tonumber(pair, 16)) end
    poke(GAME + 0x200, table.concat(g))
    p64(GAME + GR, MGR); p64(GAME + GP, PACE)
    p32(MGR + OFF.manager_entity_map + 8, 4)
    p64(MGR + OFF.manager_entity_map, SLOTS)
    p32(SLOTS, 0xABCD); p32(DESC + 8, 0xABCD)
    p32(DESC + 20, 0)                        -- bit0 = 0 -> 客机
    p64(MGR + OFF.manager_descriptor, DESC)
    p32(MGR + OFF.pending_count, 0)
    p32(PACE + OFF.pacing_blockers, 0)
    pf32(PACE + OFF.pacing_rate, 1.6)        -- 客机也能读到 rate
    pf32(MGR + OFF.cooldown_fraction, 0.8)
    pf32(MGR + OFF.cooldown_seconds_raw, 0)  -- 客机的 raw 字段实测为 0

    local profile = {game_dll = {timestamp = 1790161983, image_size = 74727424},
                     guards = {{rva = 0x200, hex = GUARD}}, offsets = OFF,
                     globals = {reinforcement = GR, pacing = GP}}

    local loadstring = loadstring or load
    local factory = assert(loadstring(state_source, '@reinforcement'))()

    print('诊断字段测试（客机分支）')

    -- 1. 不开诊断：不应出现 diag_* 字段（确认开关真的起作用）
    local reader = factory(api, profile, function() end)
    CLOCK = 1
    local snapshot = reader.sample()
    check(snapshot.authoritative == false, '确认走客机分支', tostring(snapshot.authoritative))
    check(snapshot.diag_rate == nil, '未开诊断时没有 diag_rate 字段',
        tostring(snapshot.diag_rate))

    -- 2. 打开诊断：三个原始量都要有
    reader = factory(api, profile, function() end)
    reader.diagnostic = true
    CLOCK = 1
    snapshot = reader.sample()
    check(snapshot.diag_rate ~= nil, 'diag_rate 有值', tostring(snapshot.diag_rate))
    check(math.abs((snapshot.diag_rate or 0) - 1.6) < 0.001,
        'diag_rate == 夹具的 1.6', tostring(snapshot.diag_rate))
    check(snapshot.diag_fraction ~= nil, 'diag_fraction 有值',
        tostring(snapshot.diag_fraction))
    check(math.abs((snapshot.diag_fraction or 0) - 0.8) < 0.001,
        'diag_fraction == 夹具的 0.8', tostring(snapshot.diag_fraction))
    check(snapshot.diag_raw_field ~= nil, 'diag_raw_field 有值（客机的 raw 字段）',
        tostring(snapshot.diag_raw_field))
    check(math.abs(snapshot.diag_raw_field) < 0.0001,
        'diag_raw_field == 0（与上游说法一致）', tostring(snapshot.diag_raw_field))
    -- raw 为 0 时 raw_seconds 应为 0（能被算出），K_implied 不应产生（fraction 虽非零，
    -- 但 raw=0 时 K=0，属于无意义值；这里只要求不报错）
    check(snapshot.diag_raw_seconds ~= nil, 'diag_raw_seconds 有值',
        tostring(snapshot.diag_raw_seconds))

    -- 3. 权威端也应该带诊断字段（方便同一台机器上对拍）
    p32(DESC + 20, 1)                        -- bit0 = 1 -> 权威端
    pf32(MGR + OFF.cooldown_seconds_raw, 156.127884)
    pf32(MGR + OFF.cooldown_fraction, 0.709672)
    reader = factory(api, profile, function() end)
    reader.diagnostic = true
    CLOCK = 2
    snapshot = reader.sample()
    check(snapshot.authoritative == true, '切成权威端后判定正确',
        tostring(snapshot.authoritative))
    if snapshot.diag_raw_seconds then
        check(snapshot.diag_raw_seconds == 98,
            'diag_raw_seconds == 98（与日志 seconds 一致）',
            tostring(snapshot.diag_raw_seconds))
    end
    -- raw/fraction 在权威端实测恒为 220（日志八条样本），这里应当复现
    if snapshot.diag_total_seconds then
        check(math.abs(snapshot.diag_total_seconds - 220.0) < 0.5,
            'diag_total_seconds（raw/fraction）≈ 220，与日志一致',
            tostring(snapshot.diag_total_seconds))
    else
        check(false, 'raw/fraction 应被算出', 'diag_total_seconds 为 nil')
    end

    print(string.format('\n%d 项检查，%d 项失败', checks, failures))
    return failures
end
