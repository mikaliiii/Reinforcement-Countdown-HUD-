-- 游戏内 HUD：用 Stingray screen GUI 直接绘制倒计时。
--
-- 与上游参考实现的差别：
--   1. 不挂在 minimap 上，因此地图关着时也可见——那正是玩家需要这个数字的时候
--   2. 只显示必要信息：READY 或纯倒计时。增援进行中宁可不显示，也不显示一个
--      会误导人的陈旧数字
--   3. 无背景板，文字直接画在世界之上
--
-- 坐标说明：Stingray screen GUI 的 y 轴从屏幕**底部**向上量。这是实测得出的
-- 结论——早期按"y 从顶部"计算时，x 位置分毫不差（右边距 1.2% 完全正确），
-- 面板却画到了屏幕右下角。x 轴不受影响，仍是从左量起。
--
-- 每一次绘制都包在 pcall 里：GUI 故障只会隐藏面板并留下记录，绝不会传到游戏
-- 主循环。
return function(stingray, layout_override)
    local H = {status = 'idle', visible = false}

    -- 布局参数集中在这里，按分辨率自动缩放。
    -- 改位置/大小只需要动这几个数。启动时日志会记录一次实际布局，
    -- 方便按自己的分辨率核对。
    local LAYOUT = {
        right_margin = 0.012,
        -- 从屏幕顶边向下量的屏幕高度比例。选 0.28 是取"原生任务面板中心
        -- （约 0.15）"与"早期 0.42 锚点"之间的位置。注意这里锚的是面板**顶边**。
        below_objectives = 0.28,
        width = 242,
        height = 40,
        text_inset_x = 10,
        text_inset_y = 7,
        text_size = 26,
        reference_height = 1080,
    }
    for key, value in pairs(layout_override or {}) do
        LAYOUT[key] = value
    end
    H.layout_config = LAYOUT

    -- 时间充裕显示绿色；低于 2 分钟转橙；低于 1 分钟转红。READY 为绿色。
    local GREEN = {90, 220, 155}
    local ORANGE = {255, 180, 70}
    local RED = {235, 90, 80}

    -- 本面板唯一使用的字体。这是所有已知 HD2 Lua mod 都在用的字体，
    -- 已确认可加载。
    --
    -- 这里**刻意不做字体探测**：曾经有一版为了找更圆润的字体，在启动时用候选
    -- 字体名逐个创建屏幕外的临时文本对象来判定可用性，结果导致游戏崩溃。
    -- 探测属于一次性诊断行为，只能放进按需运行的诊断构建，绝不能放在每次启动
    -- 都会执行的路径上。
    local FONT = 'core/performance_hud/debug'

    local gui, bound_world, text_id, last_key, layout_reported

    local function worlds_now()
        local ok, list = pcall(stingray.Application.worlds)
        if not ok then return nil end
        return list
    end

    local function present(list, value)
        if type(list) ~= 'table' then return false end
        for _, entry in ipairs(list) do
            if entry == value then return true end
        end
        return false
    end

    local function dispose()
        local list = worlds_now()
        if gui ~= nil and list ~= nil and present(list, bound_world) then
            pcall(stingray.World.destroy_gui, bound_world, gui)
        end
        gui, bound_world, text_id, last_key = nil, nil, nil, nil
    end

    -- 任务世界 = worlds 列表里除 main_world 之外的第一个世界。
    local function mission_world()
        local list = worlds_now()
        if list == nil then return nil end
        local ok, main = pcall(stingray.Application.main_world)
        if not ok then return nil end
        if not present(list, main) then return nil end
        for _, entry in ipairs(list) do
            if entry ~= main then return entry end
        end
        return nil
    end

    -- 返回要显示的文字与颜色；返回 nil 表示整个面板隐藏。
    --
    -- PENDING 与 PAUSED 都表示增援已经在进行中，那一刻显示倒计时是误导。
    -- UNKNOWN 与 UNAVAILABLE 表示这个值不可信，同样隐藏，而不是给玩家一个
    -- 他可能会据此行动的数字。
    local function presentation(snapshot)
        local status = snapshot.status
        if status == 'READY' then
            return 'READY', GREEN
        end
        if status == 'COOLDOWN' then
            local seconds = snapshot.seconds or 0
            if seconds < 0 then seconds = 0 end
            local colour
            if seconds > 120 then
                colour = GREEN
            elseif seconds >= 60 then
                colour = ORANGE
            else
                colour = RED
            end
            local text = string.format('%02d:%02d',
                math.floor(seconds / 60), seconds % 60)
            -- 客机是换算出来的，秒数带有不确定度，把幅度直接标在括号里。
            -- 主机（权威端）读的是游戏自己的值，没有这一项，也就不加括号。
            -- 宁可让玩家看见"±8 秒"，也不要让他以为这是精确值。
            if snapshot.estimated and snapshot.error_seconds then
                text = text .. string.format(' (±%d)', snapshot.error_seconds)
            end
            return text, colour
        end
        return nil, nil
    end

    local function hide()
        if H.visible and gui ~= nil and stingray.Gui ~= nil
            and stingray.Gui.set_visible ~= nil then
            pcall(stingray.Gui.set_visible, gui, false)
        end
        H.visible = false
    end

    local function run(snapshot)
        if type(stingray) ~= 'table' or stingray.Gui == nil or stingray.World == nil
            or stingray.Application == nil then
            H.status = 'Stingray UI 不可用'
            hide()
            return
        end

        local text, colour = presentation(snapshot)
        if text == nil then
            hide()
            H.status = '隐藏：' .. tostring(snapshot.status)
            return
        end

        local target = mission_world()
        if target == nil then
            if gui ~= nil then dispose() end
            H.status = '等待进入任务'
            hide()
            return
        end

        if bound_world ~= target or gui == nil then
            dispose()
            gui = stingray.World.create_screen_gui(target, 'scale', 1, 1)
            assert(gui ~= nil, '屏幕 GUI 创建失败')
            bound_world = target
            last_key = nil
        end

        local ok, screen_w, screen_h = pcall(stingray.Gui.resolution)
        if not ok or screen_w == nil or screen_h == nil
            or screen_w <= 0 or screen_h <= 0 then
            hide()
            H.status = '取不到分辨率'
            return
        end

        local scale = screen_h / LAYOUT.reference_height
        local panel_w = LAYOUT.width * scale
        local panel_h = LAYOUT.height * scale
        local x = screen_w - panel_w - screen_w * LAYOUT.right_margin
        -- y 自下而上，所以"距顶部"的锚点要翻转；再减去面板高度，是因为
        -- y 指的是面板的**下边缘**。
        local y = screen_h * (1 - LAYOUT.below_objectives) - panel_h

        if x < 0 or y < 0 or x + panel_w > screen_w or y + panel_h > screen_h then
            hide()
            H.status = '该分辨率下没有空间'
            return
        end

        local key = string.format('%s|%d|%d|%.4f|%.4f', text, screen_w, screen_h, x, y)
        if key == last_key then
            H.status = '可见（内容未变）'
            if not H.visible and stingray.Gui.set_visible ~= nil then
                pcall(stingray.Gui.set_visible, gui, true)
            end
            H.visible = true
            return
        end

        if not layout_reported then
            layout_reported = true
            H.layout = string.format('screen=%dx%d scale=%.3f panel=%.0fx%.0f at %.0f,%.0f',
                screen_w, screen_h, scale, panel_w, panel_h, x, y)
        end

        if text_id ~= nil then
            pcall(stingray.Gui.destroy_text, gui, text_id)
            text_id = nil
        end

        -- 无背景板：文字直接绘制在世界之上。
        text_id = stingray.Gui.text(gui, text, FONT,
            LAYOUT.text_size * scale, FONT,
            stingray.Vector3(x + LAYOUT.text_inset_x * scale,
                             y + LAYOUT.text_inset_y * scale, 3),
            stingray.Color(255, colour[1], colour[2], colour[3]))
        assert(text_id ~= nil, '创建文字失败')

        if stingray.Gui.set_visible ~= nil then
            pcall(stingray.Gui.set_visible, gui, true)
        end
        last_key = key
        H.visible, H.status = true, 'visible'
    end

    function H.draw(snapshot)
        local ok, err = pcall(run, snapshot)
        if not ok then
            hide()
            H.status = '绘制出错：' .. tostring(err)
        end
        return H.visible == true
    end

    -- 暴露出来只为让测试拿到**同一个** presentation 函数。
    -- 测试如果自己复制一份格式化逻辑，那就是自证——复制品通过不代表原函数通过。
    H.presentation_for_test = presentation

    function H.close()
        pcall(dispose)
        H.status = 'closed'
    end

    return H
end
