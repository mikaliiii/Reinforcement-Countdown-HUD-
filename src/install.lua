-- 入口：环境闸门、日志、update 钩子、采样节流。
--
-- 加载器只负责「发现 + require + 日志」，从不改内存；真正干活的是这里的代码。
-- 本模块只读取内存与绘制 HUD，不写入游戏内存。
--
-- update 钩子采用「安全退钩」写法：直接 `update = original` 会当场切断排在
-- 自己之后挂载的其他 mod 的 update 链，因此只有在确认自己仍是顶层包装时
-- 才还原，否则只把自己旁路掉。
return function(create_api, reinforcement, hud, options)
    options = options or {}
    local revision = options.revision or 'v0.0.0'
    local PROBE = options.probe_seconds or 6

    local M = {revision = revision, revision_id = options.revision_id or 1}

    -- ------------------------------------------------------------------
    -- 日志
    -- ------------------------------------------------------------------
    -- 主日志目录由加载器提供；取不到时逐级回退，保证一定有一个可写的位置。
    local function getenv(name)
        local ok, value = pcall(os.getenv, name)
        if ok and type(value) == 'string' and value ~= '' then return value end
        return nil
    end

    local function candidate_paths(name)
        local list = {}
        -- 显式覆盖优先：离线测试用它把日志写到隔离位置，避免污染玩家真实日志。
        local override = getenv('HD2_RADAR_LOG')
        if override then list[#list + 1] = override end
        local local_appdata = getenv('LOCALAPPDATA')
        if local_appdata then
            list[#list + 1] = local_appdata .. '\\CowboyBingus\\Helldivers2\\Logs\\' .. name
        end
        list[#list + 1] = 'C:\\' .. name
        list[#list + 1] = name
        return list
    end

    local log_handle, log_path
    local function open_log(name)
        if log_handle then return log_handle end
        for _, path in ipairs(candidate_paths(name)) do
            local ok, handle = pcall(io.open, path, 'ab')
            if ok and handle then
                log_handle, log_path = handle, path
                return handle
            end
        end
        return nil
    end

    local function log(line)
        local handle = log_handle or open_log('ReinforcementRadar.log')
        if not handle then return end
        pcall(function()
            handle:write(os.date('[%Y-%m-%d %H:%M:%S] ') .. tostring(line) .. '\n')
            handle:flush()
        end)
    end
    M.log = log

    -- 限流：同一句话只写一次，避免"每帧重试"把日志刷成灾难。
    local logged = {}
    local function log_once(key, line)
        if logged[key] then return end
        logged[key] = true
        log(line)
    end

    -- ------------------------------------------------------------------
    -- 环境闸门
    -- ------------------------------------------------------------------
    -- 加载器版本不够时（v14 = API 0）addon 照样会被加载、照样会跑，不会报错，
    -- 只会安静地做不成事。所以开头就要问一句，并把结论写进日志。
    local function environment_gate()
        local loader = rawget(_G, 'CowboyBingusModLoader')
        M.api = type(loader) == 'table' and tonumber(loader.api) or nil
        M.loader_version = type(loader) == 'table' and tonumber(loader.version) or nil

        if M.api == nil then
            -- 读不到这个 global 时不要直接拒绝（将来可能有别的加载器），
            -- 退一步去解析加载器日志的首行。
            local base = getenv('LOCALAPPDATA')
            if base then
                local path = base
                    .. '\\CowboyBingus\\Helldivers2\\Logs\\BingusSharedLoader.log'
                local ok, handle = pcall(io.open, path, 'rb')
                if ok and handle then
                    local first = handle:read('*l') or ''
                    handle:close()
                    local version, level = first:match('loader%-v(%d+);%s*API%s*(%d+)')
                    if level then
                        M.api = tonumber(level)
                        M.loader_version = tonumber(version)
                    end
                end
            end
        end

        log(string.format('=== Reinforcement Radar %s (r%d) ===', revision, M.revision_id))
        log(string.format('loader api=%s version=%s path=%s',
            tostring(M.api), tostring(M.loader_version), tostring(log_path)))
        log(string.format('lua=%s jit=%s', tostring(_VERSION),
            tostring(rawget(_G, 'jit') and jit.version)))

        if M.api == nil then
            log('拒绝：读不到 CowboyBingusModLoader，也无法从日志解析')
            return false
        end
        if M.api < 1 then
            log('拒绝：加载器 API ' .. tostring(M.api) .. ' 过旧（需要 API 1 / v15+）')
            return false
        end
        return true
    end

    -- ------------------------------------------------------------------
    -- 启动
    -- ------------------------------------------------------------------
    if not environment_gate() then
        return M
    end

    local ok_api, api = pcall(create_api)
    if not ok_api then
        log('拒绝：只读内存层初始化失败：' .. tostring(api))
        return M
    end
    M.api_layer = api

    if type(profile) ~= 'table' or type(profile.guards) ~= 'table' then
        log('拒绝：profile 缺失或结构不对（构建时被内联，正常情况下不会发生）')
        return M
    end
    M.profile = profile

    local reader = reinforcement(api, profile, log)
    M.reader = reader
    -- 诊断开关：打开后读取器会在每次采样里附带换算所需的原始量，由下面的
    -- tick 落盘。**显示逻辑不受它影响**，开关只多写几行日志。
    reader.diagnostic = options.diagnostic == true
    M.diagnostic = reader.diagnostic

    -- 构建校验只做一次，结果记进日志。失败就不挂钩子，静默退出。
    local game, why = reader.verify()
    if game == nil then
        log('拒绝：' .. tostring(why))
        return M
    end
    log(string.format('构建校验通过：%d/%d 条守卫，game.dll timestamp=%d image_size=%d',
        reader.signatures_checked, reader.signatures_total,
        reader.game_timestamp, reader.game_image_size))

    local panel = hud(rawget(_G, 'stingray'), options.layout)
    M.hud = panel

    -- ------------------------------------------------------------------
    -- 采样节流
    -- ------------------------------------------------------------------
    -- 采样本身很便宜（几次 ReadProcessMemory），但进入/退出 Lua 函数在高刷新率
    -- 屏幕上仍会留下帧生成时间的锯齿。稳态下每 SAMPLE_EVERY 帧唤醒一次。
    local SAMPLE_EVERY = options.sample_every or 6
    local frames, last_state, last_heartbeat = 0, nil, 0

    local function describe(snapshot)
        local parts = {'status=' .. tostring(snapshot.status)}
        if snapshot.authoritative ~= nil then
            parts[#parts + 1] = 'authoritative=' .. tostring(snapshot.authoritative)
        end
        if snapshot.seconds ~= nil then
            parts[#parts + 1] = 'seconds=' .. tostring(snapshot.seconds)
        end
        if snapshot.raw_remaining ~= nil then
            parts[#parts + 1] = string.format('raw_remaining=%.6f', snapshot.raw_remaining)
        end
        if snapshot.rate ~= nil then
            parts[#parts + 1] = string.format('rate=%.6f', snapshot.rate)
        end
        if snapshot.fraction ~= nil then
            parts[#parts + 1] = string.format('fraction=%.6f', snapshot.fraction)
        end
        if snapshot.pending ~= nil then
            parts[#parts + 1] = 'pending=' .. tostring(snapshot.pending)
        end
        if snapshot.blockers ~= nil then
            parts[#parts + 1] = 'blockers=' .. tostring(snapshot.blockers)
        end
        if snapshot.raw_remaining and snapshot.rate and snapshot.rate > 0 then
            parts[#parts + 1] = string.format('derived=%d',
                math.ceil(snapshot.raw_remaining / snapshot.rate))
        end
        if snapshot.reason then
            parts[#parts + 1] = 'reason=' .. tostring(snapshot.reason)
        end
        return table.concat(parts, '  ')
    end

    -- 诊断节流状态。早期版本"fraction 一变就写"，实机一局写出了 6187 行、
    -- 且每次都 flush —— 频率远超必要，属于无谓的磁盘活动。现在改为固定节奏。
    local diag_last_frame = 0
    local DIAG_EVERY_FRAMES = 60 * 1       -- 约 1 秒一条（排查闪断用）

    local function diag_text(snapshot)
        local parts = {'DIAG'}
        parts[#parts + 1] = 'authoritative=' .. tostring(snapshot.authoritative)
        parts[#parts + 1] = string.format('fraction=%.6f', snapshot.diag_fraction or 0)
        parts[#parts + 1] = string.format('rate=%.6f', snapshot.diag_rate or 0)
        parts[#parts + 1] = string.format('raw_field=%.6f', snapshot.diag_raw_field or 0)
        if snapshot.diag_raw_seconds ~= nil then
            parts[#parts + 1] = 'raw_seconds=' .. tostring(snapshot.diag_raw_seconds)
        end
        if snapshot.diag_total_seconds ~= nil then
            parts[#parts + 1] = string.format('raw/fraction=%.1f',
                snapshot.diag_total_seconds)
        end
        parts[#parts + 1] = 'client_state=' .. tostring(snapshot.client_state)
        parts[#parts + 1] = 'status=' .. tostring(snapshot.status)
        parts[#parts + 1] = 'seconds=' .. tostring(snapshot.seconds)
        return table.concat(parts, '  ')
    end

    local function tick()
        frames = frames + 1
        if (frames % SAMPLE_EVERY) ~= 0 then return end

        local snapshot = reader.sample()

        -- HUD 每帧都不需要重画：内容不变时 hud.lua 内部会短路。
        pcall(panel.draw, snapshot)

        -- 诊断落盘：固定节奏（约每 5 秒一条）。只在需要排查时打开。
        if M.diagnostic and snapshot.diag_fraction ~= nil then
            if frames - diag_last_frame >= DIAG_EVERY_FRAMES then
                diag_last_frame = frames
                log(diag_text(snapshot))
            end
        end

        -- 状态变化是真正有意思的事件，必须记录。
        if snapshot.status ~= last_state then
            last_state = snapshot.status
            last_heartbeat = frames
            log('SAMPLE  ' .. describe(snapshot))
            if panel.layout then
                log('# HUD layout: ' .. panel.layout)
                panel.layout = nil
            end
        elseif snapshot.status == 'COOLDOWN' then
            -- 冷却递减期间每分钟记一次心跳，便于事后核对倒计时是否连续。
            if frames - last_heartbeat >= 60 * 60 then
                last_heartbeat = frames
                log('HEARTBEAT  ' .. describe(snapshot))
            end
        end
    end

    -- ------------------------------------------------------------------
    -- update 钩子（安全退钩）
    -- ------------------------------------------------------------------
    -- 参考实现把这套手写逻辑记录为「安全退钩守卫」：直接还原 update 会截断
    -- 排在自己之后挂载的其他 mod 的钩子链。
    local previous_update = rawget(_G, 'update')
    if type(previous_update) ~= 'function' then
        log('拒绝：游戏 update 不可用')
        return M
    end

    local retired = false
    local mine
    mine = function(...)
        if not retired then
            -- 自身逻辑单独隔离：出错只记录，绝不影响游戏的 update 返回值。
            local ok, err = pcall(tick)
            if not ok then
                log_once('tick:' .. tostring(err), 'tick 出错：' .. tostring(err))
                retired = true                 -- 一次致命错误即停止采样
                pcall(panel.close)
            end
        end
        return previous_update(...)
    end

    rawset(_G, 'update', mine)
    M.installed = true

    -- 只有当自己仍是当前顶层包装时才还原；否则只旁路自身，保全整条钩子链。
    M.retire = function()
        retired = true
        if rawget(_G, 'update') == mine then
            rawset(_G, 'update', previous_update)
        end
        pcall(panel.close)
        log('已退钩')
    end

    log('已挂钩，SAMPLE_EVERY=' .. tostring(SAMPLE_EVERY))
    return M
end
