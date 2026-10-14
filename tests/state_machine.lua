-- 状态机离线测试 / Offline state-machine test for the reinforcement reader.
--
-- 用一块假内存把 game.dll 里的整条解析链摆出来：
--   全局指针 -> 管理器 -> 实体映射表 / 任务描述符 -> 冷却字段
-- 逐个验证各种状态的判定、每一步失败的原因、以及派生的秒数。
--
-- 由 tests/run_state_tests.py 调用：源码从 Python 侧读入再传进来，
-- 因为 Lua 的 fopen 打不开含中文的路径。
--
-- 夹具刻意包含"看起来合法但字段不对"的诱饵，用来确认校验真的有用，
-- 而不是只要读到数字就放行。

local failures, checks = 0, 0

local function check(condition, label, detail)
    checks = checks + 1
    if condition then
        print(string.format('  ok   %s', label))
    else
        failures = failures + 1
        print(string.format('  FAIL %s%s', label,
            detail and ('  -- ' .. tostring(detail)) or ''))
    end
end

-- ---------------------------------------------------------------------------
-- 假内存
-- ---------------------------------------------------------------------------
local MIN, MAX = 65536, 0x100000
local RAM

local function poke(address, bytes)
    for index = 1, #bytes do
        RAM[address + index - 1] = bytes:byte(index)
    end
end

local function peek(address, size)
    if address < MIN or address + size > MAX then return nil end
    local out = {}
    for offset = 0, size - 1 do
        out[#out + 1] = string.char(RAM[address + offset] or 0)
    end
    return table.concat(out)
end

local function poke_u32(address, value)
    poke(address, string.char(value % 256, math.floor(value / 256) % 256,
        math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256))
end

local function poke_u64(address, value)
    poke_u32(address, value % 4294967296)
    poke_u32(address + 4, math.floor(value / 4294967296))
end

-- 用小整数构造精确的 32 位浮点，不依赖 string.pack（LuaJIT 没有它）。
local function f32_bytes(value)
    if value == 0 then return '\0\0\0\0' end
    local sign = 0
    if value < 0 then sign, value = 128, -value end
    local exponent = math.floor(math.log(value) / math.log(2))
    local mantissa = math.floor((value / 2 ^ exponent - 1) * 8388608 + 0.5)
    if mantissa >= 8388608 then mantissa, exponent = 0, exponent + 1 end
    local bits = sign * 16777216 + (exponent + 127) * 8388608 + mantissa
    return string.char(bits % 256, math.floor(bits / 256) % 256,
        math.floor(bits / 65536) % 256, math.floor(bits / 16777216) % 256)
end

local function poke_f32(address, value) poke(address, f32_bytes(value)) end

local function read_scalar(address, size)
    local bytes = peek(address, size)
    if not bytes then return nil end
    local value = 0
    for index = size, 1, -1 do
        value = value * 256 + bytes:byte(index)
    end
    return value
end

local api = {}

-- 可控时钟。非权威端的速率估计必须按已知的时间间隔喂样本，
-- 才能验证它算出来的秒数是不是精确解。
local CLOCK = 0
function api.time() return CLOCK end
local function advance(seconds) CLOCK = CLOCK + seconds end
local function reset_clock() CLOCK = 0 end

function api.module(name)
    if name == 'game.dll' then return 0x10000 end
    if name == nil then return 0x8000 end
    return nil
end

function api.read(address, size)
    if type(address) ~= 'number' or type(size) ~= 'number' then return nil end
    if size < 1 or size > 2097152 then return nil end
    return peek(address, size)
end

function api.u8(address) return read_scalar(address, 1) end
function api.u32(address) return read_scalar(address, 4) end
function api.u64(address) return read_scalar(address, 8) end

function api.f32(address)
    local bits = read_scalar(address, 4)
    if bits == nil then return nil end
    local sign = 1
    if bits >= 2147483648 then sign, bits = -1, bits - 2147483648 end
    local exponent = math.floor(bits / 8388608)
    local mantissa = bits - exponent * 8388608
    if exponent == 255 then return 0 / 0 end
    if exponent == 0 then
        if mantissa == 0 then return sign * 0.0 end
        return sign * mantissa * 2 ^ -149
    end
    return sign * (1 + mantissa / 8388608) * 2 ^ (exponent - 127)
end

function api.pointer(address)
    local value = api.u64(address)
    if value == nil or value < MIN or value >= MAX then return nil end
    return value
end

function api.finite(value, maximum)
    if type(value) ~= 'number' then return false end
    if value ~= value then return false end
    return math.abs(value) <= (maximum or 1000000)
end

-- ---------------------------------------------------------------------------
-- 夹具
-- ---------------------------------------------------------------------------
local GAME_BASE = 0x10000
local GLOBAL_REINFORCE = 0x2000
local GLOBAL_PACING = 0x2100
local MANAGER = 0x30000
local DESCRIPTOR = 0x40000
local PACING = 0x50000
local SLOTS = 0x60000
local MISSION_ID = 0xABCD
-- 守卫字节放在假内存里，这样构建校验能真的通过；
-- 不摆守卫的话读取器会在第一步就拒绝，后面的状态判定根本测不到。
local PE_OFFSET = 0x80
local GUARD_RVA = 0x200
local GUARD_BYTES = '488bcbe8e5110000f30f5984b3d00a0000488b742438f30f11841f94000000'
local PE_TIMESTAMP = 1790161983
local PE_IMAGE_SIZE = 74727424

-- profile 里真实使用的偏移键名，与 src/profile.lua 逐字一致。
-- 用短名会让读取器读到 nil，测试就变成在测自己写错的夹具。
local OFF = {
    manager_entity_map = 0x68,
    manager_descriptor = 0x80,
    cooldown_fraction = 0xad0,
    cooldown_seconds_raw = 0x94,
    pending_count = 0xa0,
    pending_item = 0xc4,
    pending_stride = 0x104,
    pacing_blockers = 0x934,
    pacing_rate = 0x924,
}
local GL = {reinforcement = GLOBAL_REINFORCE, pacing = GLOBAL_PACING}

-- 摆出一整套现场。默认是"任务进行中、权威端、冷却 164.014862 秒、速率 0.963457"，
-- 数值取自上游日志里交叉验证过的那组。
local function build_mission(options)
    options = options or {}
    RAM = {}

    -- 伪造一个可解析的 PE 头：MZ、"PE\0\0"、TimeDateStamp、SizeOfImage。
    -- 校验链的第一关就是这四项，不摆齐了后面全测不到。
    poke(GAME_BASE, 'MZ')
    poke_u32(GAME_BASE + 60, PE_OFFSET)                    -- e_lfanew
    poke(GAME_BASE + PE_OFFSET, 'PE\0\0')
    poke_u32(GAME_BASE + PE_OFFSET + 8, PE_TIMESTAMP)
    poke_u32(GAME_BASE + PE_OFFSET + 80, PE_IMAGE_SIZE)

    -- 在 (GAME_BASE + GUARD_RVA) 处摆上守卫期望的字节。
    local guard = {}
    for pair in GUARD_BYTES:gmatch('%x%x') do
        guard[#guard + 1] = string.char(tonumber(pair, 16))
    end
    poke(GAME_BASE + GUARD_RVA, table.concat(guard))

    poke_u64(GAME_BASE + GL.reinforcement, MANAGER)
    poke_u64(GAME_BASE + GL.pacing, PACING)

    local capacity = options.capacity
    if capacity == nil then capacity = 4 end
    poke_u32(MANAGER + OFF.manager_entity_map + 8, capacity)
    poke_u32(MANAGER + OFF.manager_entity_map + 12, 0)
    poke_u64(MANAGER + OFF.manager_entity_map, SLOTS)
    poke_u32(SLOTS + 0, MISSION_ID)
    poke_u32(SLOTS + 4, 0)

    poke_u32(DESCRIPTOR + 8, MISSION_ID)
    poke_u32(DESCRIPTOR + 20, options.authoritative == false and 0 or 1)
    poke_u64(MANAGER + OFF.manager_descriptor, DESCRIPTOR)

    poke_f32(MANAGER + OFF.cooldown_fraction, options.fraction or 0.5)
    poke_f32(MANAGER + OFF.cooldown_seconds_raw, options.raw or 0)
    poke_u32(MANAGER + OFF.pending_count, options.pending or 0)
    if (options.pending or 0) > 0 then
        for index = 0, options.pending - 1 do
            poke_u32(MANAGER + OFF.pending_item + index * OFF.pending_stride,
                options.pending_type or 0)
        end
    end
    poke_u32(PACING + OFF.pacing_blockers, options.blockers or 0)
    poke_f32(PACING + OFF.pacing_rate, options.rate or 1.0)
end

-- ---------------------------------------------------------------------------
-- 入口：由 Python 侧传入读取器源码
-- ---------------------------------------------------------------------------
local function run(source)
    local build_profile = function()
        return {
            game_dll = {timestamp = 1790161983, image_size = 74727424},
            guards = {{rva = GUARD_RVA, hex = GUARD_BYTES}},
            offsets = OFF,
            globals = GL,
        }
    end
    local loadstring = loadstring or load
    local factory = assert(loadstring(source, '@reinforcement'))()

    local function sample(options)
        build_mission(options)
        return factory(api, build_profile(), function() end).sample()
    end

    -- 有些用例需要在 build_mission 之后再把某个字段改坏，
    -- 所以给一个"现场可继续修改"的版本。
    local function sample_after(options, mutate)
        build_mission(options)
        mutate()
        return factory(api, build_profile(), function() end).sample()
    end

    -- 同一实例连续采样：只有留住同一个 reader，速率估计才有历史。
    -- set_fraction 在每次采样前刷新"同步比例"，用来模拟客机看到的投影。
    -- 返回最后一次结果，以及一个可选的"逐帧结果"表。
    local function sample_stream(options, set_fraction, steps, step_seconds, collect)
        reset_clock()
        build_mission(options)
        local reader = factory(api, build_profile(), function() end)
        local last
        local history = {}
        for _ = 1, steps do
            if set_fraction then set_fraction(CLOCK) end
            last = reader.sample()
            history[#history + 1] = {clock = CLOCK, result = last}
            advance(step_seconds)
        end
        if collect then return last, history end
        return last
    end

    -- 按**实机节奏**跑：fraction 由主机每隔若干秒才刷新一格，而模组每帧都在采样。
    -- 这两件事的间隔完全不同，而且正是这个差别把 v1.2.1 的客机坑死了——
    -- 历史缓冲区按"每次采样"记录，16 条只覆盖 1.6 秒，永远够不到 4 秒窗口。
    -- 夹具必须同时模拟这两种节奏，否则根本测不出这个 bug。
    --
    --   updates_per_second  fraction 每秒变几格（实机实测约 0.75~1）
    --   samples_per_second  模组每秒采样几次（每 6 帧，约 10）
    local function run_realistic(options, set_value, duration, updates_per_second,
                                 samples_per_second)
        reset_clock()
        build_mission(options)
        local reader = factory(api, build_profile(), function() end)
        local sample_dt = 1 / samples_per_second
        local update_dt = 1 / updates_per_second
        local next_update = -1e9
        local last, history = nil, {}
        local t = 0
        while t <= duration + 1e-9 do
            if t >= next_update then
                next_update = next_update + update_dt
                if set_value then set_value(t) end
            end
            CLOCK = t
            last = reader.sample()
            history[#history + 1] = {clock = t, result = last}
            t = t + sample_dt
        end
        return last, history
    end

    print('状态机夹具测试')
    print('  -- 基础状态判定 --')

    local value

    -- 0. 构建校验本身：守卫匹配 -> 通过
    build_mission({})
    local reader = factory(api, build_profile(), function() end)
    local game, why = reader.verify()
    check(game == GAME_BASE, '守卫匹配 -> 构建校验通过', tostring(why))
    check(reader.signatures_checked == 1 and reader.signatures_total == 1,
        '检查了全部守卫', tostring(reader.signatures_checked))

    -- 0b. 守卫不匹配 -> 拒绝工作（这是保护固定偏移的关键机制）
    build_mission({})
    poke_u32(GAME_BASE + GUARD_RVA + 8, 0xDEADBEEF)     -- 改坏守卫中间 4 字节
    value = factory(api, build_profile(), function() end)
    local bad_game, bad_why = value.verify()
    check(bad_game == nil and tostring(bad_why):find('守卫失败') ~= nil,
        '守卫不匹配 -> 拒绝运行', tostring(bad_why))

    -- 0c. PE 指纹不符 -> 拒绝（游戏更新后的第一道闸门）
    build_mission({})
    local wrong = {
        game_dll = {timestamp = 1, image_size = 2},
        guards = build_profile().guards,
        offsets = OFF, globals = GL,
    }
    bad_game, bad_why = factory(api, wrong, function() end).verify()
    check(bad_game == nil and tostring(bad_why):find('不支持的游戏构建') ~= nil,
        'PE 指纹不符 -> 拒绝运行', tostring(bad_why))

    -- 1. 管理器存在但没有描述符 -> 不在任务中
    value = sample_after({}, function() poke_u64(MANAGER + OFF.manager_descriptor, 0) end)
    check(value.status == 'UNAVAILABLE', '没有描述符 -> UNAVAILABLE', value.status)

    -- 2. 实体映射表容量为 0 -> 不在任务中
    value = sample({capacity = 0})
    check(value.status == 'UNAVAILABLE', '容量 0 -> UNAVAILABLE', value.status)

    -- 3. 容量不是 2 的幂 -> 拒绝，而不是按垃圾值去读
    value = sample({capacity = 3})
    check(value.status == 'UNKNOWN' and value.reason == '实体映射表容量非法',
        '容量 3（非 2 的幂）-> 拒绝', value.status .. ' / ' .. tostring(value.reason))

    -- 4. 任务实例不在映射表里 -> 拒绝（防止把残留管理器当成活任务）
    value = sample_after({}, function() poke_u32(SLOTS, 0x1234) end)
    check(value.status == 'UNAVAILABLE' and value.reason == '任务实例不存在',
        '任务实例缺失 -> 拒绝', value.status .. ' / ' .. tostring(value.reason))

    -- 5. 权威端冷却中：164.014862 / 0.963457 -> ceil = 171（上游交叉验证过的数）
    value = sample({raw = 164.014862, rate = 0.963457, fraction = 0.5})
    check(value.status == 'COOLDOWN', '权威端冷却中 -> COOLDOWN', value.status)
    check(value.seconds == 171, 'seconds = ceil(164.014862/0.963457) = 171',
        value.seconds)
    check(math.abs(value.raw_remaining - 164.014862) < 0.001,
        'raw_remaining 精确保留', value.raw_remaining)

    -- 6. 冷却清零 -> READY
    value = sample({raw = 0, rate = 1.0})
    check(value.status == 'READY' and value.seconds == 0, '冷却为零 -> READY',
        value.status)

    -- 7. 队列里有普通增援请求 -> PENDING（优先于 COOLDOWN）
    value = sample({raw = 100, rate = 1.0, pending = 1, pending_type = 0})
    check(value.status == 'PENDING', '队列有普通请求 -> PENDING', value.status)

    -- 8. 队列项不是普通类型 -> 不判定为 PENDING
    value = sample({raw = 100, rate = 1.0, pending = 1, pending_type = 7})
    check(value.status == 'COOLDOWN', '队列项非普通类型 -> 仍 COOLDOWN', value.status)

    -- 9. 有阻塞 -> PAUSED（增援进行中，冷却被冻结）
    value = sample({raw = 100, rate = 1.0, blockers = 2})
    check(value.status == 'PAUSED', '有阻塞 -> PAUSED', value.status)

    -- 10. 速率为 0 -> PAUSED
    value = sample({raw = 100, rate = 0})
    check(value.status == 'PAUSED', '速率为 0 -> PAUSED', value.status)

    -- 11. 非权威端（客机）：只有归一化比例，但比例是线性投影，
    --     用本机测出的下降率可以**精确**反推秒数。
    --     场景：总时长 180 秒，比例从 1.0 开始递减。
    local TOTAL, STEP = 180, 0.5
    local function projection(clock)
        return 1 - clock / TOTAL
    end

    local client_options = {
        authoritative = false, raw = 0, rate = 1.0, fraction = 1.0,
    }
    local function refresh(clock)
        poke_f32(MANAGER + OFF.cooldown_fraction, projection(clock))
    end

    -- 只喂两帧、间隔不足 MIN_INTERVAL(0.4s) 时不该报数字。
    value = sample_stream(client_options, refresh, 2, 0.2)
    check(value.status == 'UNKNOWN',
        '客机：间隔不足时不急着报数字',
        value.status .. ' / ' .. tostring(value.reason))

    -- 喂到 12 秒（24 帧 × 0.5s），此时应已锁定速率并给出正确秒数。
    value = sample_stream(client_options, refresh, 24, STEP)
    do
        -- 探针：注意必须在 sample() 之后读，否则拿到的是上一帧的状态
        local r = factory(api, build_profile(), function() end)
        reset_clock()
        local last = nil
        for _ = 1, 24 do
            refresh(CLOCK)
            last = r.sample()
            advance(STEP)
        end
        local pr = r.history_probe()
        print(string.format('      [probe] 末帧 state=%s seconds=%s', tostring(last.client_state), tostring(last.seconds)))
        print(string.format('      [probe] history=%s rate=%s fit_rms=%s lw=%s',
            tostring(pr.n), tostring(pr.rate), tostring(pr.fit_rms), tostring(pr.level_width)))
        if pr.fail then
            print(string.format('      [probe] 跨度不足 need=%.4f span=%.4f', pr.fail.need, pr.fail.span or -1))
        end
        if pr.fit then
            print(string.format('      [probe] 拟合失败 why=%s rms=%s tol=%s levels=%s',
                tostring(pr.fit.why), tostring(pr.fit.rms), tostring(pr.fit.tol),
                tostring(pr.fit.levels)))
        end
    end
    check(value.status == 'COOLDOWN', '客机：测出速率后进入 COOLDOWN', value.status)
    check(value.estimated == true, '客机：结果标记为换算得来', tostring(value.estimated))
    -- 12 秒处剩余应为 168；速率由实测得出，允许 1 秒取整误差。
    check(value.seconds ~= nil and math.abs(value.seconds - 168) <= 1,
        '客机：12 秒处反推出 168 秒（精确解）', tostring(value.seconds))
    check(value.rate_measured ~= nil
            and math.abs(value.rate_measured - 1 / TOTAL) < 0.0002,
        '客机：实测速率为 1/180', tostring(value.rate_measured))
    -- 客机的秒数是换算来的，必须同时给出不确定度，HUD 会把它显示成 (±N)。
    check(value.error_seconds ~= nil and value.error_seconds >= 1,
        '客机：给出误差范围（HUD 括号里的数字）', tostring(value.error_seconds))
    check(value.error_seconds ~= nil and value.error_seconds <= 60,
        '客机：误差范围在合理量级（不会大到无意义）', tostring(value.error_seconds))
    -- 主机读的是游戏自己的值，没有不确定度，HUD 也就不该加括号。
    local host_value = sample({authoritative = true, raw = 156.127884, rate = 1.6})
    check(host_value.status == 'COOLDOWN' and host_value.error_seconds == nil,
        '主机：不带误差字段（HUD 不加括号）',
        tostring(host_value.error_seconds))

    -- 12. 比例冻结（增援进行中）-> PAUSED，而不是继续倒数。
    --     步长 1.5s，冻结超过 STALL_LIMIT(1.5s) 后判定。
    value = sample_stream(client_options,
        function() poke_f32(MANAGER + OFF.cooldown_fraction, 1 - 12 / TOTAL) end,
        6, 1.5)
    check(value.status == 'PAUSED',
        '客机：比例冻结 -> PAUSED', value.status .. ' / ' .. tostring(value.reason))

    -- 13. 比例归零 -> READY
    --
    --     注意这里必须按实机节奏跑（fraction 每个更新周期降一格、模组高频采样）。
    --     早期版本用 1.5 秒一步采样：每步跨度都超过 MIN_INTERVAL，于是每一步
    --     都在重新测量，永远锁定不了速率，也就观察不到"递减到 0"这件事——
    --     结果它测的其实是"从未观察到递减"，而不是这条用例想验证的"走完"。
    local ready_at, last_ready = nil, nil
    local _, ready_trace = run_realistic(client_options,
        function(t)
            poke_f32(MANAGER + OFF.cooldown_fraction,
                math.max(0, 1 - t / TOTAL))
        end,
        TOTAL + 2, 1, 10)
    for _, entry in ipairs(ready_trace) do
        if entry.result.status == 'READY' then
            if not ready_at then ready_at = entry.clock end
            last_ready = entry.clock
        end
    end
    -- 判定方式：READY 必须出现在"比例刚刚归零"那一刻附近，而不是永远显示。
    -- 归零之后状态会回到 unknown（新一段冷却从 0 开始，还没观察到递减），
    -- 所以不能拿末帧状态当判据——那测的是另一件事。
    check(ready_at ~= nil and ready_at >= TOTAL - 1 and ready_at <= TOTAL + 1,
        '客机：观察到递减并走完 -> 在归零那一刻显示 READY',
        ready_at and string.format('READY 出现在 t=%.1f（理论归零 t=%.0f）', ready_at, TOTAL)
            or '从未出现 READY')
    check(last_ready ~= nil and last_ready >= TOTAL + 1.0,
        '客机：READY 在归零后持续显示（不再只闪一帧）',
        last_ready and string.format('最后一条 READY 在 t=%.1f（归零于 t=%.0f）',
            last_ready, TOTAL) or 'n/a')

    -- 15. 网络抖动 + 量化台阶：按**实机节奏**跑。
    --     早期这条用"每次采样都刷新比例"，那等于让比例与采样同频——实机上比例是
    --     每秒才下发一格，这个维度缺失让旧用例全绿而实机完全不可用。所以这里
    --     必须用 run_realistic，并同时叠上量化台阶与噪声。
    local JITTER_TOTAL = 240
    local RATE_WINDOW_FOR_TEST = 12     -- 与 src 的 RATE_WINDOW 保持一致
    local JITTER_HZ = 1                  -- 每秒 1 格：240 秒总时长下接近实机的细分辨率
    local NOISE = 0.12                   -- 噪声幅度 = 0.12 个档宽（实机量级）

    local jitter_last, jitter_history = run_realistic(client_options,
        function(t)
            local value = 1 - t / JITTER_TOTAL
                + NOISE * math.sin(t * math.pi / 2) / JITTER_TOTAL
            local q = math.floor(value * 255 + 0.5) / 255
            poke_f32(MANAGER + OFF.cooldown_fraction, q > 0 and q or 0)
        end,
        JITTER_TOTAL + 2, JITTER_HZ, 10)

    local remeasured, first_report, worst = 0, nil, 0
    for _, entry in ipairs(jitter_history) do
        local r = entry.result
        if r.client_state ~= 'locked' then remeasured = remeasured + 1 end
        if r.seconds then
            if not first_report then first_report = entry.clock end
            -- 只统计稳态段：窗口刚建成的前 30 秒量化误差最大，那是物理下限
            -- （见下一条用例的说明），不是缺陷。
            if entry.clock >= 30 then
                local error_seconds = math.abs(r.seconds - (JITTER_TOTAL - entry.clock))
                if error_seconds > worst then worst = error_seconds end
            end
        end
    end
    check(first_report ~= nil and first_report <= RATE_WINDOW_FOR_TEST + 8,
        '客机：抖动+量化下仍能及时出数字',
        first_report and string.format('首次出数字 %.1f 秒', first_report) or '从未给出')
    check(first_report ~= nil and worst <= 14,
        '客机：抖动+量化下稳态秒数误差 ≤ 14 秒',
        string.format('最大误差 %.1f 秒（抖动幅度 0.12 档）', worst))

    -- 15b. 分辨率更细时（每秒整数格），噪声会被量化直接抹掉，误差应显著更小。
    local fine_worst, fine_frames = 0, 0
    local fine_last, fine_history = run_realistic(client_options,
        function(t)
            local value = 1 - t / JITTER_TOTAL
                + NOISE * math.sin(t * math.pi / 2) / JITTER_TOTAL
            local q = math.floor(value * 510 + 0.5) / 510      -- 每秒 2 格（整数）
            poke_f32(MANAGER + OFF.cooldown_fraction, q > 0 and q or 0)
        end,
        JITTER_TOTAL + 2, 2, 10)
    for _, entry in ipairs(fine_history) do
        local r = entry.result
        if r.seconds and entry.clock >= 30 then
            fine_frames = fine_frames + 1
            local error_seconds = math.abs(r.seconds - (JITTER_TOTAL - entry.clock))
            if error_seconds > fine_worst then fine_worst = error_seconds end
        end
    end
    -- 放宽离散门限后（为了让倒计时不闪断），细分辨率下稳态误差从 6 秒松到
    -- 约 7 秒。8 秒上限 = 240 秒冷却的 3.3%，属于稳定性换来的合理代价。
    check(fine_frames > 0 and fine_worst <= 8,
        '客机：分辨率变细后稳态误差随之变小（≤8 秒）',
        string.format('%d 帧, 最大误差 %.1f 秒', fine_frames, fine_worst))

    -- 15b. 抖动周期**整除**速率窗口时，两端差分把抖动完全消掉，误差应接近 0。
    --      这是窗口法的关键性质：它说明"用窗口"不只是把噪声摊薄，而是能在
    --      周期对上时精确消除。取周期 2 秒、窗口 4 秒（整除）。
    -- 15b 已在上方按实机节奏重写（见"分辨率变细后误差随之变小"）。
    -- 这里不再保留旧的"整除窗口"用例：那个性质属于已废弃的"两端差分"模型，
    -- 现在的实现取窗口内各点 ratio 的中位数，不存在"周期对齐"这回事。

    -- 16. 比例回升 -> 视为新一段冷却，旧速率作废、重新测量。
    --     用一段物理上说得通的序列，且**回升值必须严格高于回升前的值**：
    --       第一段：总时长 240，从 1.0 稳定递减（clock=20 时约 0.92）
    --       被一次部署重置：跳回 1.0（这就是回升）
    --       第二段：总时长 120，继续递减（每帧降幅是前一段的两倍）
    --     降幅的变化也顺便验证了：估计器必须改用新速率，而不是沿用旧的。
    local REBOUND_AT, FIRST_TOTAL, SECOND_TOTAL = 20, 240, 120
    local last, history = sample_stream(client_options,
        function(clock)
            local fraction
            if clock < REBOUND_AT then
                fraction = 1 - clock / FIRST_TOTAL
            else
                fraction = 1 - (clock - REBOUND_AT) / SECOND_TOTAL
            end
            poke_f32(MANAGER + OFF.cooldown_fraction, fraction)
        end,
        REBOUND_AT + 6, 1.0, true)

    local at_jump, before_jump
    for _, entry in ipairs(history) do
        if entry.clock == REBOUND_AT then at_jump = entry.result end
        if entry.clock == REBOUND_AT - 1 then before_jump = entry.result end
    end

    check(before_jump ~= nil and before_jump.status == 'COOLDOWN'
            and before_jump.rate_measured ~= nil,
        '客机：回升前已锁定第一段的速率',
        before_jump and tostring(before_jump.rate_measured) or 'nil')

    check(at_jump ~= nil and at_jump.client_state == 'measuring',
        '客机：比例回升那一帧回到"测量中"',
        at_jump and at_jump.client_state or 'nil')
    check(at_jump ~= nil and at_jump.seconds == nil,
        '客机：回升后不沿用第一段的旧秒数',
        at_jump and tostring(at_jump.seconds) or 'nil')

    -- 回升后应重新锁定，且第二段的速率约为 1/120（第一段的 1/240 的两倍）。
    check(last.status == 'COOLDOWN'
            and last.rate_measured ~= nil
            and math.abs(last.rate_measured - 1 / SECOND_TOTAL) < 0.0005,
        '客机：第二段用新速率重新锁定（1/120）',
        last and tostring(last.rate_measured) or 'nil')

    -- 15. 非权威端比例越界仍然被拒（诱饵：字段不对时不能装作能换算）
    value = sample({fraction = 3.5, authoritative = false})
    check(value.status == 'UNKNOWN' and value.reason == '同步来的冷却比例非法',
        '客机：比例越界 -> 拒绝', value.status .. ' / ' .. tostring(value.reason))

    -- ---------------------------------------------------------------
    -- 实机节奏用例（新增）
    --
    -- 这两条是为了堵住 v1.2.1 在实机上暴露的缺陷。之前的客机用例都用
    -- 「每次采样都刷新 fraction」，那等于让 fraction 与采样同频——
    -- 而实机上 fraction 是主机每秒才下发一格，模组却每帧采样。
    -- 维度缺失导致夹具全绿、实机完全不能用。所以这两条必须按真实节奏跑。
    -- ---------------------------------------------------------------
    print('  -- 实机节奏（fraction 每秒一格 vs 采样每秒 10 次）--')

    -- 用实机日志里的真实参数：rate=2.97，总时长约 417 秒（由 K/rate 推得）
    local REAL_TOTAL, REAL_UPS, REAL_SPS = 417, 1, 10
    local real_options = {authoritative = false, raw = 0, rate = 2.97}

    local real_last, real_history = run_realistic(real_options,
        function(t)
            local f = 1 - t / REAL_TOTAL
            poke_f32(MANAGER + OFF.cooldown_fraction, f > 0 and f or 0)
        end,
        REAL_TOTAL + 5, REAL_UPS, REAL_SPS)

    -- 首次给出秒数的时间：必须远早于冷却结束
    local first_seconds
    for _, entry in ipairs(real_history) do
        if entry.result.seconds and not first_seconds then
            first_seconds = entry.clock
        end
    end
    check(first_seconds ~= nil and first_seconds <= 12,
        '客机：实机节奏下 12 秒内出数字（v1.2.1 是 54 秒/冷却结束才出）',
        first_seconds and string.format('%.1f 秒', first_seconds) or '从未给出')

    -- 中途的秒数必须贴合理论值（fraction × T）
    local worst_real = 0
    for _, entry in ipairs(real_history) do
        local r = entry.result
        if r.seconds and entry.clock >= 20 then
            local truth = REAL_TOTAL - entry.clock
            local err = math.abs(r.seconds - truth)
            if err > worst_real then worst_real = err end
        end
    end
    -- 窗口从 4 秒加到 12 秒后，短冷却的量化误差占比反而略升，阈值放宽到 8 秒。
    check(worst_real <= 8,
        '客机：实机节奏下秒数误差 ≤ 8 秒',
        string.format('最大 %.1f 秒（v1.2.1 根本给不出数字）', worst_real))

    -- 16. 增援暂停：客机 fraction 被置 0 —— **不能判成 READY**
    --     实机里这段持续 70~77 秒，v1.2.1 会一直显示「可以拉烟」。
    local pause_last, pause_history = run_realistic(real_options,
        function() poke_f32(MANAGER + OFF.cooldown_fraction, 0) end,
        30, REAL_UPS, REAL_SPS)
    local ready_frames = 0
    for _, entry in ipairs(pause_history) do
        if entry.result.status == 'READY' then ready_frames = ready_frames + 1 end
    end
    check(ready_frames == 0,
        '客机：fraction 恒为 0 且没观察到过递减 -> 绝不显示 READY',
        ready_frames .. ' 帧被判成 READY（v1.2.1 会给 70~77 秒）')
    check(pause_last.status ~= 'READY',
        '客机：暂停段最终状态也不是 READY', pause_last.status)

    -- 17. 反过来：真正观察过递减 -> 冷却走完时应当显示 READY
    real_last, real_history = run_realistic(real_options,
        function(t)
            local f = 1 - t / REAL_TOTAL
            poke_f32(MANAGER + OFF.cooldown_fraction, f > 0 and f or 0)
        end,
        REAL_TOTAL + 3, REAL_UPS, REAL_SPS)
    local saw_ready = false
    for _, entry in ipairs(real_history) do
        if entry.result.status == 'READY' then saw_ready = true end
    end
    check(saw_ready, '客机：观察到递减后走完 -> 正确显示 READY',
        '最后状态 ' .. tostring(real_last.status))

    -- 18. READY 必须**持续**显示，而不是只活一帧。
    --
    --     实机 v1.2.3：READY 出现后下一帧立刻回到 UNKNOWN，面板闪一下就没。
    --     根因是同一个"本段观察到过递减"的标志既表示"跑完过"又表示"这是新一段"，
    --     而 reset 会清掉它，所以只够撑一帧。
    --
    --     夹具按实机节奏跑：冷却走完后 fraction 继续为 0 若干秒（实机里那段有
    --     70~77 秒）。用 20 Hz 采样，"只活一帧"就精确等于 0.05 秒。
    local READY_HOLD = 70
    local function descend_then_zero(t)
        if t <= REAL_TOTAL then
            local f = 1 - t / REAL_TOTAL
            poke_f32(MANAGER + OFF.cooldown_fraction, f > 0 and f or 0)
        else
            poke_f32(MANAGER + OFF.cooldown_fraction, 0)
        end
    end

    local hold_ready_frames = 0
    local hold_last, hold_history = run_realistic(real_options, descend_then_zero,
        REAL_TOTAL + READY_HOLD, REAL_UPS, 20)
    local first_zero = nil
    for _, entry in ipairs(hold_history) do
        if entry.clock >= REAL_TOTAL and not first_zero then first_zero = entry.clock end
        if entry.result.status == 'READY' then hold_ready_frames = hold_ready_frames + 1 end
    end
    -- 期望值：fraction 为 0 之后每帧都应是 READY，允许零星缺口（速率过期等）。
    local expected_ready = READY_HOLD * 20 * 0.9
    check(hold_ready_frames > expected_ready,
        '客机：fraction 持续为 0 期间 READY 一直显示（不再只活一帧）',
        string.format('READY 共 %d 帧，20Hz 下 70 秒应有约 %d 帧',
            hold_ready_frames, READY_HOLD * 20))
    check(hold_last.status == 'READY',
        '客机：READY 保持到本段结束（末帧仍是 READY）', tostring(hold_last.status))

    -- 19. 冷却期间状态不得在 COOLDOWN 与 UNKNOWN 之间来回跳。
    --     实机日志里 UNKNOWN 夹在 COOLDOWN 之间，面板每几秒重画一次可见性。
    --     物理上冷却期间速率不会突然消失，一旦锁定就该保持到本段结束。
    local flickers, seen_lock = 0, false
    for _, entry in ipairs(hold_history) do
        local state = entry.result.client_state
        if entry.clock < REAL_TOTAL - 2 then
            if state == 'locked' then
                seen_lock = true
            elseif seen_lock and state ~= 'locked' then
                flickers = flickers + 1
            end
        end
    end
    check(seen_lock and flickers == 0,
        '客机：锁定速率后在冷却段内不再闪断（不再回到 measuring）',
        string.format('闪断 %d 帧', flickers))

    -- 20. blockers > 0 时必须隐藏 READY。
    --     主机端就是这么判定的（blockers 表示冷却被挂起）。给客机加同一条守卫，
    --     这样"暂停期间误报可以拉烟"在任何解释下都不会发生。
    local blocked_frames = 0
    local blocked_last, blocked_history = run_realistic(
        {authoritative = false, raw = 0, rate = 2.97, blockers = 1},
        descend_then_zero, REAL_TOTAL + 20, REAL_UPS, 20)
    for _, entry in ipairs(blocked_history) do
        if entry.clock > REAL_TOTAL and entry.result.status == 'READY' then
            blocked_frames = blocked_frames + 1
        end
    end
    check(blocked_frames == 0,
        '客机：blockers > 0 时不显示 READY（冷却被挂起）',
        string.format('%d 帧误报 READY，末帧状态 %s',
            blocked_frames, tostring(blocked_last.status)))

    -- 冷却比例越界 -> 拒绝（诱饵：看起来合法但字段不对）
    value = sample({fraction = 3.5})
    check(value.status == 'UNKNOWN' and value.reason == '同步来的冷却比例非法',
        '比例 3.5 越界 -> 拒绝', value.status .. ' / ' .. tostring(value.reason))

    -- 14. 队列长度越界 -> 拒绝
    value = sample({pending = 99})
    check(value.status == 'UNKNOWN' and value.reason == '增援队列非法',
        '队列长度 99 -> 拒绝', value.status .. ' / ' .. tostring(value.reason))

    -- 15. 速率为负 -> 拒绝
    value = sample({rate = -1})
    check(value.status == 'UNKNOWN' and value.reason == 'pacing 状态非法',
        '速率为负 -> 拒绝', value.status .. ' / ' .. tostring(value.reason))

    -- 16. 取不到 pacing 管理器 -> 报告原因而不是崩溃
    value = sample_after({raw = 50, rate = 1.0},
        function() poke_u64(GAME_BASE + GL.pacing, 0) end)
    check(value.status == 'UNKNOWN' and value.reason == 'pacing 管理器不可用',
        'pacing 缺失 -> 说明原因', value.status .. ' / ' .. tostring(value.reason))

    -- 17. 递归检查：sample 内部任何异常都必须被 pcall 吸收
    value = sample_after({}, function() RAM = {} end)   -- 抹掉整块内存
    check(type(value) == 'table' and value.status ~= nil,
        '内存被抹掉也不抛异常', value.status)

    print(string.format('\n%d 项检查，%d 项失败', checks, failures))
    return failures
end

return run
