<p align="center">
  <img src="images/battery_example.png" width="600">
</p>

# awesome_battery

A compact battery widget for [AwesomeWM](https://awesomewm.org/).

The icon is drawn with Cairo and needs no external dependencies: only a Linux
system with `sysfs` and AwesomeWM 4.3+.

Data is read from `/sys/class/power_supply/<battery name>/`. Both driver
variants are supported: `charge_*` + `current_now` and `energy_*` + `power_now`.

## Features

- Battery icon drawn with Cairo; no icon theme is required.
- Direct `sysfs` reads, no helper scripts or daemons.
- Support for both `charge_*` and `energy_*` drivers.
- Fill colour reflects the state: charging, below 30%, 30–60%, above 60%.
- Hover notification with model, charge, status, remaining time, health and
  cycle count.
- Battery name, polling interval and colours are configurable from `rc.lua`.

## Requirements

- Linux with `sysfs` and the `/sys/class/power_supply/` interface.
- AwesomeWM 4.3 or newer.

## Installation

Copy `battery.lua` into your AwesomeWM configuration, or clone the repository
and link the file. The examples below use `~/.config/awesome/widgets/battery.lua`:

```sh
git clone https://github.com/psplehanov/awesome_battery.git ~/.config/awesome/awesome_battery
mkdir -p ~/.config/awesome/widgets
ln -sf ~/.config/awesome/awesome_battery/battery.lua ~/.config/awesome/widgets/battery.lua
```

Then restart AwesomeWM.

## Usage

rc.lua

```lua
local battery_widget = require("widgets.battery")

mybattery = wibox.widget {
    battery_widget.new(),
    forced_width  = 10,
    forced_height = 18,
    valign = "center",
    halign = "center",
    layout = wibox.container.place,
}
```

`wibox.container.place` centres the icon vertically in the wibar. Then add
`mybattery` to the bar, for example to its right side:

```lua
{
    layout = wibox.layout.fixed.horizontal,
    mybattery,
    -- other widgets
},
```

## Configuration

| Option     | Default   | Description                                          |
|------------|-----------|------------------------------------------------------|
| `battery`  | `"BAT0"`  | Battery directory name in `/sys/class/power_supply/` |
| `interval` | `30`      | Polling interval in seconds, minimum 1               |
| `colors`   | see below | Outline and fill colours                             |

Options are passed as the first argument of `battery_widget.new()`:

```lua
battery_widget.new({ battery = "BAT1" })
```

### Colours

Colours are set with the `colors` option as hex strings, either full
(`#79A8C4`) or short (`#7AC`):

```lua
battery_widget.new({
    colors = {
        border   = "#272727", -- battery outline
        charging = "#79A8C4", -- while charging
        low      = "#C45555", -- below 30%
        medium   = "#D6AD48", -- 30 to 60%
        normal   = "#272727", -- above 60%
    },
})
```

An invalid value or a missing key falls back to the default colour.

## Charge time estimate

"Until full" is an approximation, not an exact time: the charging current
changes and drops noticeably near the end of the charge, so the number may
stall or even grow.

The widget records the charge on every poll (every 30 seconds by default) and
averages the rate over the last 15 minutes across all samples in the window.
While there is less than 5 minutes of history, or the growth over the window is
below 2%, it falls back to the instantaneous current. If current data is
unavailable, it shows "Until full: —".

The result is rounded: exact below 10 minutes, in 5-minute steps up to an hour,
and in 10-minute steps beyond that.

## Tips

### Finding the battery name

```sh
ls /sys/class/power_supply/
```

Usually the name is `BAT0`, `BAT1`, etc. To check that the chosen directory is
really a battery:

```sh
cat /sys/class/power_supply/BAT0/type
# Battery
```

## Limitations

- The estimate is approximate: the charging current varies and drops near full,
  so the number may stall or grow.
- Only one battery is monitored at a time; use the `battery` option to choose it.
- The widget is not hidden when the battery is absent; hovering shows the path
  it searched.

## License

MIT. See [LICENSE](LICENSE).
