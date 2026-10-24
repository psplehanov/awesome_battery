local wibox = require("wibox")
local gears = require("gears")
local naughty = require("naughty")

local M = {}

local POWER_SUPPLY = "/sys/class/power_supply/"
local DEFAULT_BATTERY = "BAT0"

-- ===== Чтение sysfs =====

local function read_num(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local v = f:read("*a")
    f:close()
    return tonumber(v:match("^%s*(-?%d+)"))
end

local function read_str(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local v = f:read("*a")
    f:close()
    return (v:gsub("%s+$", ""))
end

-- ===== Сбор данных =====

local function clamp_percent(value)
    return math.max(0, math.min(100, value))
end

local function format_minutes(total)
    return string.format("%dч %02dм", math.floor(total / 60), total % 60)
end

local CHARGE_WINDOW     = 15 * 60
local CHARGE_MIN_SPAN   = 5 * 60
local CHARGE_MIN_GROWTH = 0.02

-- Наклон по всем точкам окна: устойчивее разности первого и последнего замера.
local function trend(history)
    local n = #history
    if n < 3 then return nil end

    local t0 = history[1].t
    local sum_t, sum_v = 0, 0
    for _, p in ipairs(history) do
        sum_t = sum_t + (p.t - t0)
        sum_v = sum_v + p.value
    end

    local mean_t = sum_t / n
    local mean_v = sum_v / n
    local num, den = 0, 0
    for _, p in ipairs(history) do
        local dt = (p.t - t0) - mean_t
        num = num + dt * (p.value - mean_v)
        den = den + dt * dt
    end

    if den == 0 then return nil end
    return num / den
end

local function round_minutes(total)
    if total < 10 then return total end
    if total < 60 then return math.floor(total / 5 + 0.5) * 5 end
    return math.floor(total / 10 + 0.5) * 10
end

local function estimate_minutes(history, value, goal, timestamp)
    local first = history[1]
    if not first then return nil end

    local span = timestamp - first.t
    if span < CHARGE_MIN_SPAN then return nil end

    local rate = trend(history)
    if not rate or rate <= 0 then return nil end

    -- Прирост меньше 2% не отличить от шага квантования 1%.
    if rate * span < goal * CHARGE_MIN_GROWTH then return nil end

    local left = goal - value
    if left <= 0 then return 0 end
    return math.max(0, math.floor(left / rate / 60 + 0.5))
end

local function progress(b)
    if b.now and b.full and b.full > 0 then
        return b.now, b.full, "raw"
    end
    return b.level, 100, "level"
end

-- Резкое изменение принимается только после подтверждения следующим замером.
local function blend_estimate(state, previous, fresh)
    if fresh == nil then return previous end

    if previous == nil or math.abs(fresh - previous) <= 2 then
        state.pending, state.count = nil, 0
        return fresh
    end

    if state.pending and math.abs(fresh - state.pending) <= 2 then
        state.count = state.count + 1
    else
        state.count = 1
    end
    state.pending = fresh

    if state.count >= 2 then
        state.pending, state.count = nil, 0
        return fresh
    end

    return previous
end

local function read_battery(sys)
    local present   = read_num(sys .. "/present")
    local available = read_str(sys .. "/type") == "Battery"
        and (present == nil or present ~= 0)
    local status    = read_str(sys .. "/status") or "Unknown"
    local cycles    = read_num(sys .. "/cycle_count")
    local model     = read_str(sys .. "/model_name")

    local charge_now  = read_num(sys .. "/charge_now")
    local charge_full = read_num(sys .. "/charge_full")
    local energy_now  = read_num(sys .. "/energy_now")
    local energy_full = read_num(sys .. "/energy_full")

    local full, design
    if charge_full then
        full   = charge_full
        design = read_num(sys .. "/charge_full_design")
    elseif energy_full then
        full   = energy_full
        design = read_num(sys .. "/energy_full_design")
    end

    local now
    if charge_full then
        now = charge_now
    elseif energy_full then
        now = energy_now
    end

    local health = nil
    if full and design and design > 0 then
        health = clamp_percent(math.floor(full / design * 100 + 0.5))
    end

    local level = read_num(sys .. "/capacity")
    if not level and now and full and full > 0 then
        level = now / full * 100
    end
    level = math.floor(clamp_percent(level or 0) + 0.5)

    local remaining_min = nil
    local until_full_min = nil
    local current_now = read_num(sys .. "/current_now")
    local power_now   = read_num(sys .. "/power_now")

    if status == "Discharging" then
        local hours
        if charge_now and current_now and current_now ~= 0 then
            hours = charge_now / math.abs(current_now)
        elseif energy_now and power_now and power_now ~= 0 then
            hours = energy_now / math.abs(power_now)
        end

        if hours then
            remaining_min = math.max(0, math.floor(hours * 60))
        end
    elseif status == "Charging" then
        local hours
        if charge_now and charge_full and current_now and current_now ~= 0 then
            hours = (charge_full - charge_now) / math.abs(current_now)
        elseif energy_now and energy_full and power_now and power_now ~= 0 then
            hours = (energy_full - energy_now) / math.abs(power_now)
        end

        if hours then
            until_full_min = math.max(0, math.floor(hours * 60))
        end
    end

    return {
        available  = available,
        level      = level,
        status     = status,
        health     = health,
        cycles     = cycles,
        model      = model,
        now        = now,
        full       = full,
        remaining  = remaining_min,
        until_full = until_full_min,
        charging   = (status == "Charging" or status == "Full"),
    }
end

-- ===== Виджет =====

function M.new(opts)
    opts = opts or {}
    local sys = POWER_SUPPLY .. (opts.battery or DEFAULT_BATTERY)

    local widget = wibox.widget.base.make_widget()
    widget._state = { level = 0, charging = false }

    local history = {}
    local estimate = nil
    local smoothing = { pending = nil, count = 0 }

    local function record_progress(b)
        if not b.available or b.status ~= "Charging" then
            if #history > 0 then
                history = {}
            end
            return
        end

        local value, _, source = progress(b)
        local timestamp = os.time()
        local last = history[#history]

        if last and (timestamp < last.t or timestamp - last.t > CHARGE_WINDOW) then
            history = {}
        end

        if #history > 0 and history[#history].source ~= source then
            history = {}
        end

        table.insert(history, { t = timestamp, value = value, source = source })

        local cutoff = timestamp - CHARGE_WINDOW
        while #history > 1 and history[1].t < cutoff do
            table.remove(history, 1)
        end
    end

    local function estimate_until_full(b)
        local value, goal = progress(b)
        return estimate_minutes(history, value, goal, os.time())
    end

    local function refresh_estimate(b)
        if not b.available or b.status ~= "Charging" then
            history = {}
            estimate = nil
            smoothing.pending, smoothing.count = nil, 0
            return
        end

        record_progress(b)

        local fresh = estimate_until_full(b)
        if type(fresh) ~= "number" then
            fresh = b.until_full -- прогресс не измерим, показываем оценку по току
        else
            fresh = round_minutes(fresh)
        end

        estimate = blend_estimate(smoothing, estimate, fresh)
    end

    function widget:fit(context, width, height)
        return 10, 18
    end

    function widget:draw(_, cr, width, height)
        local w, h = width, height
        local s = widget._state

        -- Контур корпуса (отступ сверху под контакт)
        cr:set_source_rgb(0.153, 0.153, 0.153)
        cr:set_line_width(1.4)
        cr:rectangle(0.7, 3.7, w - 1.4, h - 4.4)
        cr:stroke()

        -- Контакт сверху
        cr:rectangle(w / 2 - 2, 0.5, 4, 2.5)
        cr:fill()

        -- Заливка
        if s.charging then
            cr:set_source_rgb(121/255, 168/255, 196/255)
        elseif s.level < 30 then
            cr:set_source_rgb(196/255, 85/255, 85/255)
        elseif s.level <= 60 then
            cr:set_source_rgb(214/255, 173/255, 72/255)
        else
            cr:set_source_rgb(39/255, 39/255, 39/255)
        end

        local inner_top    = 3.7 + 2
        local inner_bottom = h - 0.7 - 2
        local inner_height = inner_bottom - inner_top
        local fill = inner_height * (s.level / 100)

        if fill > 0 then
            cr:rectangle(2, inner_bottom - fill, w - 4, fill)
            cr:fill()
        end
    end

    -- ===== Всплывашка =====

    local notif = nil

    function widget:hide_details()
        if notif then
            naughty.destroy(notif)
            notif = nil
        end
    end

    function widget:show_details()
        widget:hide_details()

        local b = read_battery(sys)
        if b.status == "Charging" then
            b.until_full = estimate
        end

        local lines = {}

        if not b.available then
            table.insert(lines, "Батарея не найдена")
            table.insert(lines, "Путь: " .. sys)
        else
            if b.model then
                table.insert(lines, "Модель: " .. b.model)
            end
            table.insert(lines, string.format("Заряд: %d%%", b.level))
            table.insert(lines, "Статус: " .. b.status)

            if b.remaining then
                table.insert(lines, "Осталось: " .. format_minutes(b.remaining))
            end
            if b.until_full then
                table.insert(lines, "До полной: " .. format_minutes(b.until_full))
            elseif b.status == "Charging" and b.available then
                table.insert(lines, "До полной: —")
            end

            if b.health then
                table.insert(lines, string.format("Здоровье: %d%%", b.health))
            end
            if b.cycles then
                table.insert(lines, string.format("Циклов: %d", b.cycles))
            end
        end

        notif = naughty.notify({
            title = "Battery",
            text = table.concat(lines, "\n"),
            timeout = 0,
            position = "top_right",
            screen = mouse.screen,
        })
    end

    widget:connect_signal("mouse::enter", function() widget:show_details() end)
    widget:connect_signal("mouse::leave", function() widget:hide_details() end)

    -- ===== Обновление =====

    local function update()
        local b = read_battery(sys)
        refresh_estimate(b)
        widget._state = b
        widget:emit_signal("widget::redraw_needed")
    end

    update()
    gears.timer {
        timeout   = 30,
        autostart = true,
        call_now  = false,
        callback  = update,
    }

    return widget
end

return M
