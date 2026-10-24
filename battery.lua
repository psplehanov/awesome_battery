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
    if status == "Discharging" then
        local current_now = read_num(sys .. "/current_now")
        local power_now   = read_num(sys .. "/power_now")

        local hours
        if charge_now and current_now and current_now ~= 0 then
            hours = charge_now / math.abs(current_now)
        elseif energy_now and power_now and power_now ~= 0 then
            hours = energy_now / math.abs(power_now)
        end

        if hours then
            remaining_min = math.max(0, math.floor(hours * 60))
        end
    end

    return {
        available = available,
        level     = level,
        status    = status,
        health    = health,
        cycles    = cycles,
        model     = model,
        remaining = remaining_min,
        charging  = (status == "Charging" or status == "Full"),
    }
end

-- ===== Виджет =====

function M.new(opts)
    opts = opts or {}
    local sys = POWER_SUPPLY .. (opts.battery or DEFAULT_BATTERY)

    local widget = wibox.widget.base.make_widget()
    widget._state = { level = 0, charging = false }

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
                local hh = math.floor(b.remaining / 60)
                local mm = b.remaining % 60
                table.insert(lines, string.format("Осталось: %dч %02dм", hh, mm))
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
        widget._state = read_battery(sys)
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
