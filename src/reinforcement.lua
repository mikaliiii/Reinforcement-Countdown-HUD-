-- 敌人增援冷却读取器 / Enemy reinforcement cooldown reader.
--
-- 偏移与状态机来自上游实测（见 THIRD_PARTY.md）：
--   game.dll + 0x3326020 -> 增援管理器
--   game.dll + 0x3325f18 -> pacing 管理器
-- 上游交叉验证过的日志：
--   raw_remaining=164.014862  rate=0.963457  seconds=171
--   ceil(164.014862 / 0.963457) = ceil(170.2) = 171
--
-- 这里没有任何猜测值。相对上游新增的是**诊断深度**：解析链的每一步都记录
-- 下来，失败时能说清是哪一环断了，而不是塌缩成一句 status。
--
-- 游戏构建：Steam 25480438 / EXE 1.8.46015.0
return function(api, profile, log)
    local bit = require('bit')

    local M = {status = 'UNKNOWN', samples = 0, diagnostic = false}
    local offsets = profile.offsets

    -- 把十六进制字符串还原成字节串。守卫有 800 多字节，必须机械生成，
    -- 手工誊写必然出错。
    local function hex(text)
        return (text:gsub('%x%x', function(pair)
            return string.char(tonumber(pair, 16))
        end))
    end

    -- ------------------------------------------------------------------
    -- 模块与构建校验
    -- ------------------------------------------------------------------
    -- 固定的字段偏移只有在"它所指的那段代码还没变"时才安全。任一条守卫不符
    -- 就停止，而不是按已经变了的含义去读。
    function M.verify()
        local game = api.module('game.dll')
        if game == nil then return nil, 'game.dll 未加载' end
        M.game = game

        -- PE 基本合理性：DOS 头、合理的 e_lfanew、PE 签名。
        if api.read(game, 2) ~= 'MZ' then
            return nil, 'game.dll 不以 MZ 开头'
        end
        local pe = api.u32(game + 60)
        if pe == nil or pe < 64 or pe > 4096 then
            return nil, 'e_lfanew 不合理'
        end
        if api.read(game + pe, 4) ~= 'PE\0\0' then
            return nil, '没有 PE 签名'
        end

        local timestamp = api.u32(game + pe + 8)
        local image_size = api.u32(game + pe + 80)
        M.game_timestamp, M.game_image_size = timestamp, image_size
        if timestamp ~= profile.game_dll.timestamp
            or image_size ~= profile.game_dll.image_size then
            return nil, string.format('不支持的游戏构建：timestamp=%s image_size=%s',
                tostring(timestamp), tostring(image_size))
        end

        -- 原生代码守卫。它们无法离线校验：game.dll 的代码段在磁盘上是压缩的，
        -- 只有加载进内存后才展开，所以文件里的字节并不等于这里比较的字节。
        -- 这也是守卫表必须从参考实现机械提取、而不是手打的原因。
        --
        -- 每条守卫都检查，不在第一条失败处停下，这样一份报告就能看到全貌。
        local failures, passed = {}, 0
        for index, guard in ipairs(profile.guards) do
            local expected = hex(guard.hex)
            local found = api.read(game + guard.rva, #expected)
            if found == nil then
                failures[#failures + 1] = string.format('#%d rva 0x%x 不可读',
                    index, guard.rva)
            elseif found ~= expected then
                local at = 0
                for position = 1, #expected do
                    if found:byte(position) ~= expected:byte(position) then
                        at = position
                        break
                    end
                end
                local function show(text, from)
                    local slice = text:sub(from, from + 3)
                    return (slice:gsub('.', function(c)
                        return string.format('%02x', c:byte())
                    end))
                end
                failures[#failures + 1] = string.format(
                    '#%d rva 0x%x 第 %d 字节不符（实际 %s 期望 %s）',
                    index, guard.rva, at, show(found, at), show(expected, at))
            else
                passed = passed + 1
            end
        end
        M.signatures_total = #profile.guards
        M.signatures_checked = passed
        if #failures > 0 then
            return nil, string.format('%d/%d 条守卫失败：%s',
                #failures, #profile.guards, table.concat(failures, ' | '))
        end
        return game
    end

    -- ------------------------------------------------------------------
    -- 非权威端：从"投影"反推秒数
    -- ------------------------------------------------------------------
    -- 客机拿不到 +0x94（原生剩余秒数），只收到 +0xad0 的归一化比例。
    -- 但比例是**线性**递减的：fraction = 剩余 / 总时长，而且总时长在
    -- 同一段冷却里不变。于是
    --
    --     d(fraction)/dt = -1 / 总时长
    --     剩余秒数 = fraction / |d(fraction)/dt|
    --
    -- 也就是说速率可以本机测出来，秒数就是精确解——不需要权威端的数据。
    -- 上游把 +0xad0 注释成"不是秒数"，这一步没错，但结论（因此无法显示）
    -- 少推了一步。
    --
    -- 实测的是每秒下降量，所以不受刷新率影响。
    --
    -- 关于网络延迟，有两件事必须分清：
    --
    -- 1. **恒定延迟不影响速率。** 延迟 L 让客机看到 f(t-L)，那是同一条斜率
    --    的直线整体平移；两个本地时刻相减时 L 被消掉。所以剩余秒数的误差
    --    就是 +L 这个固定偏移（300ms -> 0.3 秒），而显示是 MM:SS、十秒一跳，
    --    恒定延迟在显示上不可见。
    --
    -- 2. **抖动让单个样本失真，这才是要防的。** 抖动幅度（150ms 约
    --    0.0006~0.0013）和正常单帧降幅（0.0004~0.0008）**量级相同**，所以
    --    任何固定阈值都分不开两者：太松会漏掉真实换段，太紧会被每次抖动
    --    误触（每次误触都要丢速率重测约一秒，表现为数字闪断）。
    --    正确做法是用**已测速率当尺子**维护一条单调下降的包络线——抖动推
    --    不动包络，真实的新一段冷却则会持续高于包络并突破容差。
    local MIN_INTERVAL = 0.4          -- 采样间隔下限（秒）
    local MIN_MOVE = 0.0002           -- 判定"比例真的动了"的下限
    local RATE_WINDOW = 12.0          -- 速率测量窗口（秒），理由见下
    local MIN_SPAN = 0.02             -- 速率至少要跨这么多比例，理由见下
    local JITTER = 0.008              -- 跳变判定容差，吸收同步抖动与台阶漂移
    local STALL_LIMIT = 1.5           -- 比例多久没动就认定被冻结（秒）
    local MAX_RATE_AGE = 8.0          -- 速率多久没过期（秒）
    local MAX_DOWNWARD_RATE = 0.05    -- 常规冷却不会几秒内掉光
    local HISTORY = 256               -- 历史记录条数上限（按"变化"记，见下）
    local LEVEL_SCALE = 4096          -- fraction 量化成整数档位用的刻度

    -- **速率为什么必须在长窗口上测，而不是相邻两帧：**
    --
    -- 抖动是加在每次同步上的一个位移量 e。两帧相减时只有 e 的**差**进得来。
    -- 设抖动是周期 P、幅度 A 的正弦，窗口长度 L，则残余速率误差为
    --
    --     |A·[sin(ωt) − sin(ω(t−L))]| / L
    --
    -- 这个式子有两个重要含义：
    --
    -- 1. **L 越大误差越小。** 分母是 L，而分子里 e 之差并不随 L 增大而增大。
    --    实测（A = 75ms 等效、总时长 240 秒）：L=0.5s 时秒数能甩偏几十秒，
    --    L=4s 时余下几秒。
    -- 2. **当 P 整除 L 时误差精确为 0。** 两端取值相同，抖动被完全消掉。
    --    反过来说慢抖动（P ≫ L）残余最大：实测 P=4s/L=2s 时约 18 秒，
    --    而 P=2s/L=2s 时为 0。
    --
    -- 真实网络抖动是随机的、没有单一周期，所以实际误差在这两者之间。
    -- 取 L=4 秒是"精度"与"换段后要等多久才有数字"的折中：代价是首次出数字
    -- 要等约 4 秒（这段时间不显示，而不是显示一个错的数字）。
    --
    -- 注意：**跳变检测不能依赖长窗口**（那会迟钝 L 秒），所以它走独立的纯预测
    -- 包络线，对瞬时变化立即反应。两件事分开做。
    local estimate = {rate = nil, at = nil, prev_at = nil, prev = nil,
                      envelope = nil, envelope_at = nil,
                      history = {}, history_n = 0, last_level = nil,
                      saw_positive = false, saw_zero = false}

    local function reset_estimate(manager)
        estimate.rate, estimate.at, estimate.prev_at = nil, nil, nil
        estimate.prev = nil
        estimate.envelope, estimate.envelope_at = nil, nil
        estimate.history, estimate.history_n = {}, 0
        estimate.last_level = nil
        estimate.saw_positive = false
        estimate.saw_zero = false
        estimate.fit_fraction, estimate.fit_rms = nil, nil
        estimate.shown = nil
        estimate.manager = manager
    end

    local function level_of(fraction)
        return math.floor(fraction * LEVEL_SCALE + 0.5)
    end

    -- 历史只在 fraction **真正换档**时记录一条，并记下这一刻的时刻。
    --
    -- 这里是 v1.2.1 客机彻底失效的地方：原来是"每次采样推一条"。
    -- 但客机的 fraction 是主机每隔约 1 秒才下发一格，而模组每帧（约 0.1 秒）
    -- 采样一次 —— 于是 16 条记录只覆盖 1.6 秒，永远够不到 4 秒的速率窗口，
    -- anchor 恒为空，客机永远停在 measuring、屏幕上什么都不显示。
    -- 按"换档"记录后，条数直接对应台阶数，覆盖时长由主机的下发节奏决定。
    --
    -- 顺带的好处：每条记录的 clock 是该档位首次出现的时刻，量化噪声在
    -- 两端自然抵消（Δfraction 精确等于 Δt/T）。
    local function push_history(clock, fraction)
        local level = level_of(fraction)
        if level == estimate.last_level then return end
        estimate.last_level = level
        local n = estimate.history_n
        if n >= HISTORY then
            for index = 1, n - 1 do
                estimate.history[index] = estimate.history[index + 1]
            end
            n = n - 1
        end
        estimate.history[n + 1] = {clock = clock, fraction = fraction, level = level}
        estimate.history_n = n + 1
    end

    -- 包络：按已测速率从**上一个已知点**衰减到当前时刻，返回"比例正常下降时
    -- 此刻该在哪"的预测值。
    --
    -- 这里绝不能把当前这一帧的比例并进包络（早期版本写了
    -- `max(env - decay, fraction)`）：那等于用**待检测的信号本身**把要检测的
    -- 差异抹平——比例一跳，包络立刻跟着跳到同一个值，回升判据永远不成立，
    -- 于是把段间跳变当成一次陡降，显示出一个荒谬的秒数。
    local function envelope_expected(clock)
        if estimate.envelope == nil then return nil end
        local decay = (estimate.rate or 0) * (clock - estimate.envelope_at)
        return estimate.envelope - decay
    end

    -- 采样一帧比例，尝试刷新速率估计。返回状态：
    --   'measuring' 还测不出来   'locked' 已有可信速率
    --   'paused'    比例停止变化 'ready'  已归零
    --   'unknown'   比例为 0、但从未观察到过递减（见下）
    --
    -- 差分基准落在**历史窗口的另一端**，而不是"上一次被接受的值"：后者会跨过
    -- 不连续点（一段冷却结束、另一段开始），把整段跳变当成一次下降，算出极陡
    -- 的速率并显示一个荒谬的秒数。窗口两端都在同一段冷却里才安全，而跨段会被
    -- 上面的包络判据先一步拦下。
    -- 比例为 0 时的处理。
    --
    -- 客机上比例归零有两种含义，数据本身分不清：
    --   (a) 冷却真的走完了
    --   (b) 增援进行中，游戏把共享冷却冻结，客机这一侧读到 0
    --
    -- 判据只有一条：**本段冷却里亲眼见过 fraction > 0**。见过就当 (a)。
    -- 这个依据来自实机日志：客机 fraction=0 的采样里 blockers=0 占 16/20，
    -- 而 blockers=0 按主机端逻辑正表示"冷却在正常递减、没被挂起"，即真的走完了。
    --
    -- 关键在"锁存"：这件事一旦成立就一直成立，直到出现"从 0 转正"（新一段冷却）
    -- 才清除。v1.2.3 的写法是每次归零就 reset_estimate，把标志一并清掉，于是
    -- READY 只活一帧、面板闪一下就没——实机反馈正是如此。
    local function estimate_zero(blockers, manager)
        if estimate.manager ~= manager then reset_estimate(manager) end
        estimate.saw_zero = true
        if not estimate.saw_positive then return 'unknown' end
        -- 冷却被挂起时不显示"可以拉烟"：主机端就是这么判的，客机沿用同一条。
        if blockers and blockers > 0 then return 'unknown' end
        return 'ready'
    end

    local function client_estimate(clock, fraction, manager, blockers)
        M.client_fraction = fraction

        if estimate.manager ~= manager then reset_estimate(manager) end

        if fraction <= 0 then
            return estimate_zero(blockers, manager)
        end

        -- 从 0 转回正数 = 新一段冷开始。这时才重置估计器。
        -- 归零那一刻**不重置**：否则"本段跑完过"这个依据会被自己抹掉。
        if estimate.saw_zero then
            reset_estimate(manager)
        end

        estimate.saw_positive = true

        push_history(clock, fraction)

        if not estimate.prev_at then
            estimate.prev_at, estimate.prev = clock, fraction
            estimate.envelope, estimate.envelope_at = fraction, clock
            return 'measuring'
        end

        -- 先按上一帧的结论算出"正常下降的话此刻该在哪"，再判断这一帧是否是回升。
        local expected = envelope_expected(clock)

        local elapsed = clock - estimate.prev_at
        local previous = estimate.prev
        estimate.prev_at, estimate.prev = clock, fraction

        if expected and fraction > expected + JITTER then
            -- 持续高于纯预测 -> 另一段冷却（新部署、新任务）。旧速率作废。
            estimate.rate, estimate.at = nil, nil
            estimate.envelope, estimate.envelope_at = fraction, clock
            estimate.history, estimate.history_n = {}, 0
            estimate.stall_at = nil
            estimate.rebind_count = (estimate.rebind_count or 0) + 1
            estimate.probe_rebind = {fraction = fraction, expected = expected,
                gap = fraction - expected, jitter = JITTER, clock = clock}
            return 'measuring'
        end

        -- 冻结判定用相邻两帧：它要的是"多久没动"，和速率窗口无关。
        local moved = true
        if elapsed >= MIN_INTERVAL and previous - fraction < MIN_MOVE then
            moved = false
            if estimate.stall_at and clock - estimate.stall_at > STALL_LIMIT then
                return 'paused'
            end
            if not estimate.stall_at then estimate.stall_at = clock end
        end
        if moved then estimate.stall_at = nil end

        -- 速率：取窗口里最旧的一个样本，要求它同时满足两个条件
        --   ① 距现在至少 RATE_WINDOW 秒
        --   ② 与当前比例至少差 MIN_SPAN
        --
        -- ② 是实机逼出来的。fraction 是量化台阶，且台阶级距不小：实机客机
        -- 实测分辨率 1/255（约 0.004），而同步抖动能让相邻两帧读数差 ±1 档。
        -- 只跨一两档时估出的速率能差 5 倍以上——实机日志里出现过
        -- rate=1.000000（真值约 0.0129），于是 `seconds = fraction / 1.0`
        -- 直接把比例当秒数显示，数字疯狂跳动、倒计时一闪一闪。
        -- 跨度越大，台阶的相对误差越小：0.04 时约 5%，足够稳。
        --
        -- 先确定**拟合窗口**：只取最近 RATE_WINDOW 秒内的历史。
        --
        -- 不必再单独选一个 anchor。早期版本花了不少代码去挑"尽量旧、又满足
        -- 跨度门槛"的那一条，结果窗口与 anchor 两套判据互相打架：anchor 可能
        -- 远在窗口之外，于是拟合用了一大段陈旧数据，残差爆掉（实测 0.58），
        -- 反而锁不上。既然拟合只用窗口内的点，那就直接按窗口取，判据只剩一个。
        local count = estimate.history_n
        if count < 3 then return 'measuring' end
        local first = count
        while first > 1 and clock - estimate.history[first - 1].clock <= RATE_WINDOW do
            first = first - 1
        end
        -- 档位间隔偏大时，12 秒窗口里可能只落得下 2 条记录，ratio 不足以取中位数，
        -- 于是估计被临时否掉、倒计时闪一下。这里在条目太少时**向后多取一些**
        -- （上限 3 倍窗口），保证有足够样本；取更久的数据只会让中位数更稳，
        -- 而"混进换段"由下面的离散度检查负责识别。
        local extended = RATE_WINDOW * 3
        while first > 1 and (count - first + 1) < 4
            and clock - estimate.history[first - 1].clock <= extended do
            first = first - 1
        end
        local used = count - first + 1
        if used < 3 then return 'measuring' end

        -- 窗口跨度（两端比例之差）作为**提示性**记录，不再当作独立门槛。
        --
        -- 跨度太小这件事已经被下面的"ratio 离散度"检查覆盖：跨度只有一两档时，
        -- 各点推出的总时长必然散得很开（实测能差数倍），会被直接否掉。保留两个
        -- 判据只会让它们在边界上互相打架——实机与夹具都出现过这种"一个够、一个
        -- 不够"的僵持。
        local span = estimate.history[first].fraction - fraction
        estimate.probe_span = span

        -- **只在比例创出新低时才重算速率。**
        --
        -- 每帧都用"最旧的 anchor"重算时，anchor 一滑动速率就变一点点，而
        -- `剩余 = 比例 / 速率` 对这个变化很敏感——实机表现就是数字来回跳。
        -- 冷却期间剩余只可能减少，所以重算只由"数据变多"驱动，不由"帧过去了"驱动。
        if estimate.rate and fraction >= (estimate.fit_fraction or 1) - 1e-9 then
            if expected == nil or fraction < expected then
                estimate.envelope, estimate.envelope_at = fraction, clock
            end
            return 'locked'
        end

        -- 速率用**窗口内各点的滑动中位数**，不再做最小二乘拟合。
        --
        -- 每一步的比值 `ratio = 比例 / (窗口首比例 - 比例)` 就是"剩余秒数"，
        -- 而窗口时长是已知常数，所以 `rate = ratio / 窗口时长`。取中位数而不是
        -- 均值：任意一次抖动只污染一个点，中位数直接把它丢掉。
        --
        -- 换掉拟合的原因是拟合出了几处难以自证的坑（残差统计范围、截距与斜率
        -- 用了不同窗口等），每一次都要靠探针才看得出来。中位数的好处是**速率和
        -- 误差都能由窗口里那几个 ratio 直接读出**，没有隐含状态。
        -- 量出窗口内相邻记录的档宽（取中位数，对个别异常小值免疫），
        -- 它是"跨了多少档"的尺子，也是离散度门限的缩放依据。
        local level_width
        do
            local widths = {}
            for index = first + 1, count do
                local delta = estimate.history[index - 1].fraction
                    - estimate.history[index].fraction
                if delta > 1e-9 then widths[#widths + 1] = delta end
            end
            if #widths > 0 then
                table.sort(widths)
                level_width = widths[math.floor((#widths + 1) / 2)]
            end
        end

        local ratios = {}
        for index = first, count - 1 do
            local entry = estimate.history[index]
            local drop = entry.fraction - fraction
            if drop > 1e-9 then
                ratios[#ratios + 1] = (clock - entry.clock) / drop
            end
        end
        if #ratios < 3 then
            estimate.measuring_why = 'ratio不足(' .. #ratios .. ')'
            return 'measuring'
        end
        table.sort(ratios)
        local total_seconds = ratios[math.floor((#ratios + 1) / 2)]

        -- 自洽性：窗口内各点推出的总时长应彼此接近。散得太开说明这段里混进了
        -- 换段或跳变，此时宁可不给数字。
        --
        -- 门限必须**随跨度缩放**：一个档位的时间误差带来的 ratio 相对波动是
        -- 1/跨档数。窗口里只有几档时，正常量化噪声就能让离散度超过 25%，
        -- 于是估计被误否、速率清空，下一帧重新测又偶然通过——实机表现就是
        -- 倒计时一闪一闪地消失。跨档数多时这个门限自然收紧到 25% 以内。
        local levels_in_window = 1
        if level_width and level_width > 1e-9 then
            levels_in_window = span / level_width
        end
        local spread_tolerance = 0.25
        if levels_in_window > 0 then
            local quantisation = 1 / levels_in_window
            if quantisation * 3 > spread_tolerance then
                spread_tolerance = quantisation * 3
            end
        end
        local spread = ratios[#ratios] - ratios[1]
        estimate.ratio_spread = spread
        estimate.spread_tolerance = spread_tolerance
        if spread > spread_tolerance * total_seconds then
            estimate.rate, estimate.at = nil, nil
            estimate.measuring_why = string.format('离散%.2f>%.2f',
                spread / total_seconds, spread_tolerance)
            estimate.probe_fit = {why = 'spread', spread = spread,
                total = total_seconds, count = #ratios}
            return 'measuring'
        end

        -- 平均量化误差：档宽的一半（取不到档宽时用整段跨度估）。它直接给出
        -- 总时长的相对误差，也就是秒数的不确定度。
        local level_width = estimate.level_width
            or (span / math.max(used - 1, 1))
        local span_seconds = clock - estimate.history[first].clock
        local half_level = level_width / 2
        estimate.error_fraction = total_seconds * half_level
            / math.max(clock - estimate.history[first].clock, 1e-6)
        estimate.span_seconds = span_seconds

        local rate = 1 / total_seconds
        if rate <= 0 or rate > MAX_DOWNWARD_RATE then
            estimate.rate, estimate.at = nil, nil
            return 'measuring'
        end

        estimate.at, estimate.rate, estimate.precise = clock, rate, true
        estimate.fit_fraction = fraction
        if expected == nil or fraction < expected then
            estimate.envelope, estimate.envelope_at = fraction, clock
        end
        return 'locked'
    end

    -- 用已测得的速率把当前比例换算成秒数。
    -- fraction = 剩余 / 总时长 且 d(fraction)/dt = -1/总时长，
    -- 所以 剩余 = fraction / rate，是精确解。
    local function client_seconds(clock, fraction)
        local rate = estimate.rate
        if not rate or rate <= 0 then return nil end
        if clock - estimate.at > MAX_RATE_AGE then return nil end
        local seconds = fraction / rate
        if seconds ~= seconds or seconds < 0 or seconds > 86400 then return nil end

        -- 单调保护：同一段冷却里剩余时间**只可能减少**。速率重估时算出的值可能
        -- 略微回升（实机表现为数字偶尔 +2 跳一下，很扎眼），这里直接压住。
        -- 只在同一段内生效：换段时 saw_positive/fit_fraction 会被重置。
        local shown = math.ceil(seconds)
        if estimate.shown and fraction > 0 and shown > estimate.shown then
            shown = estimate.shown
        end
        estimate.shown = shown
        return shown
    end

    -- ------------------------------------------------------------------
    -- 采样
    -- ------------------------------------------------------------------
    -- 每一步都记录为什么停下，因此只凭日志就能定位故障，不必再进一次游戏。
    local function sample()
        local result = {status = 'UNKNOWN'}
        local game = M.game or M.verify()
        if game == nil then
            result.reason = '游戏不可用'
            return result
        end

        local manager = api.pointer(game + profile.globals.reinforcement)
        if manager == nil then
            result.status, result.reason = 'UNAVAILABLE', '取不到增援管理器'
            return result
        end
        result.manager = manager

        -- 实体映射表是两种网络角色下都可靠的"在任务中"判据。
        local map_header = api.read(manager + offsets.manager_entity_map, 24)
        if map_header == nil then
            result.reason = '实体映射表头不可读'
            return result
        end
        local capacity = api.u32(manager + offsets.manager_entity_map + 8)
        result.map_capacity = capacity
        if capacity == nil or capacity > 16
            or (capacity ~= 0 and bit.band(capacity, capacity - 1) ~= 0) then
            result.reason = '实体映射表容量非法'
            return result
        end
        if capacity == 0 then
            result.status, result.reason = 'UNAVAILABLE', '不在任务中'
            return result
        end

        local descriptor = api.pointer(manager + offsets.manager_descriptor)
        if descriptor == nil then
            -- 不在任务中时管理器仍存在，只是没有描述符。这是飞船上的正常状态，
            -- 不是读取失败，HUD 会据此隐藏。
            result.status, result.reason = 'UNAVAILABLE', '没有进行中的任务'
            return result
        end
        local identity = api.read(descriptor, 24)
        if identity == nil then
            result.reason = '任务标识不可读'
            return result
        end
        -- bit0 = 本端是否为权威端（自己持有冷却计时器）。
        result.authoritative = bit.band(api.u32(descriptor + 20), 1) == 1

        -- 确认任务实例确实在实体映射表里，避免把残留的管理器当成活任务。
        local id = api.u32(descriptor + 8)
        local empty = api.u32(manager + offsets.manager_entity_map + 12)
        local slots_address = api.u64(manager + offsets.manager_entity_map)
        local slots = slots_address and api.read(slots_address, capacity * 8) or nil
        if slots == nil then
            result.reason = '实体映射表槽位不可读'
            return result
        end
        local found = false
        for index = 0, capacity - 1 do
            local base = index * 8
            local key = api.u32(slots_address + base)
            local value = api.u32(slots_address + base + 4)
            if key ~= nil and key ~= empty and key == id and value == 0 then
                found = true
            end
        end
        if not found then
            result.status, result.reason = 'UNAVAILABLE', '任务实例不存在'
            return result
        end

        local fraction = api.f32(manager + offsets.cooldown_fraction)
        result.fraction_raw = fraction
        if not api.finite(fraction, 2) or fraction < -0.01 or fraction > 1.01 then
            result.reason = '同步来的冷却比例非法'
            return result
        end
        result.fraction = math.max(0, math.min(1, fraction))

        -- 时钟：非权威端要用它测比例下降率，两端都取一次。
        local clock = api.time()
        result.clock = clock

        -- pacing 管理器是全局量（game.dll + 0x3325f18），**两端都要在这里读**。
        -- v1.2.0 把它放在权威端分支里，于是客机拿不到 rate——而实测证明
        -- rate 正是客机换算所缺的那一项（详见 docs/01 的「客机换算」一章）。
        local pacing = api.pointer(game + profile.globals.pacing)
        if pacing == nil then
            result.reason = 'pacing 管理器不可用'
            return result
        end
        result.pacing = pacing
        local blockers = api.u32(pacing + offsets.pacing_blockers)
        local rate = api.f32(pacing + offsets.pacing_rate)
        result.blockers, result.rate = blockers, rate
        if blockers == nil or blockers > 4096
            or not api.finite(rate, 100) or rate < 0 then
            result.reason = 'pacing 状态非法'
            return result
        end

        -- 诊断（v1.2.1）：把换算所需的三个原始量都读出来记进日志，
        -- 并算出「如果 raw 字段可用，会得到什么秒数」，供离线对拍。
        -- 这只是观测，**不改变任何显示逻辑**——1.2.1 的显示行为与 1.2.0 完全一致。
        if M.diagnostic then
            local raw_field = api.f32(manager + offsets.cooldown_seconds_raw)
            result.diag_raw_field = raw_field
            result.diag_rate = rate
            result.diag_fraction = result.fraction
            if api.finite(raw_field, 86400) and rate and rate > 0 then
                -- 候选秒数 = ceil(raw/rate)，也就是上游权威端的算法。
                -- 名字叫 raw_seconds 而不是 K：它是个"秒数"，不是常数。
                result.diag_raw_seconds = math.ceil(math.max(0, raw_field) / rate)
                -- 同时记录 raw 与 fraction 的比：若 fraction 是"剩余比例"，
                -- 这个比值应等于"总秒数"，可以用来判定 fraction 的语义。
                if result.fraction > 0.0001 then
                    result.diag_total_seconds = raw_field / result.fraction
                end
            end
        end

        if not result.authoritative then
            -- 客机只有归一化比例。先喂一帧给估计器，再用本机测出的下降率
            -- 把比例换算成秒数——这是精确解，不是估计（推导见 client_estimate）。
            result.client_state = client_estimate(clock, result.fraction, manager,
                blockers)
            result.rate_measured = estimate.rate

            if result.client_state == 'ready' then
                result.status, result.seconds = 'READY', 0
                result.reason = '同步比例已归零'
                return result
            end

            if result.client_state == 'unknown' then
                -- 比例为 0，但本段冷却里从没观察到过递减。最可能是增援进行中
                -- （游戏冻结共享冷却，客机这侧读到 0），也可能是刚进任务还没同步。
                -- 两者都无法从客机数据区分，所以什么都不显示——而不是显示 READY。
                result.status = 'UNKNOWN'
                result.reason = '非权威端：比例为 0 且未观察到递减（增援进行中或尚未同步）'
                return result
            end

            if result.client_state == 'paused' then
                -- 比例停止变化：增援进行中（游戏会冻结共享冷却）。
                result.status = 'PAUSED'
                result.reason = '非权威端：同步比例停止变化（增援进行中）'
                return result
            end

            local seconds = client_seconds(clock, result.fraction)
            result.rate_measured = estimate.rate
            result.precise = estimate.precise
            if seconds == nil then
                result.status = 'UNKNOWN'
                result.reason = '非权威端：仍在测量冷却速率'
                return result
            end

            result.status = 'COOLDOWN'
            result.seconds = seconds
            result.estimated = true
            -- 不确定度：总时长的相对误差 = 半个档宽 ÷ 测量窗口跨度，秒数误差按
            -- 同一比例放大。这就是 HUD 上括号里的那个数字。
            if estimate.error_fraction then
                result.error_seconds = math.max(1,
                    math.ceil(seconds * estimate.error_fraction))
            end
            result.reason = '非权威端：由同步比例与实测速率换算（精确解）'
            return result
        end

        local raw = api.f32(manager + offsets.cooldown_seconds_raw)
        result.raw_remaining = raw
        if not api.finite(raw, 86400) or raw < -1 then
            result.reason = '原生冷却值非法'
            return result
        end
        result.raw_remaining = math.max(0, raw)

        local pending = api.u32(manager + offsets.pending_count)
        result.pending = pending
        if pending == nil or pending > 8 then
            result.reason = '增援队列非法'
            return result
        end
        local ordinary = false
        for index = 0, pending - 1 do
            if api.u32(manager + offsets.pending_item
                + index * offsets.pending_stride) == 0 then
                ordinary = true
            end
        end

        if ordinary then
            result.status = 'PENDING'
            result.reason = '已有一个普通增援请求在队列中'
        elseif blockers > 0 or rate == 0 then
            result.status = 'PAUSED'
            result.reason = '原生冷却递减被挂起'
        elseif raw > 0 then
            result.status = 'COOLDOWN'
            result.seconds = math.ceil(raw / rate)
        else
            result.status, result.seconds = 'READY', 0
            result.reason = '共享冷却已清零；本地请求闸门仍可能生效'
        end
        return result
    end

    -- 诊断探针：把估计器的内部状态暴露出来，只给离线复现脚本用。
    -- 游戏内没有任何地方调用它，因此不影响运行行为；保留它是因为
    -- tools/repro_client_flicker.py 靠它读内部状态，删掉会让复现能力丢失。
    function M.history_probe()
        local n = estimate.history_n
        if n == 0 then return {n = 0} end
        local first = estimate.history[1]
        return {
            n = n,
            first_fraction = first.fraction, first_clock = first.clock,
            rate = estimate.rate,
            span_seconds = estimate.span_seconds,
            error_fraction = estimate.error_fraction,
            ratio_spread = estimate.ratio_spread,
            span = estimate.probe_span,
        }
    end

    -- 公开采样：整条链单独隔离，读取器的任何故障都到不了游戏主循环。
    function M.sample()
        local ok, value = pcall(sample)
        if not ok then
            return {status = 'UNKNOWN', reason = tostring(value)}
        end
        M.samples = M.samples + 1
        M.last = value
        return value
    end

    return M
end
