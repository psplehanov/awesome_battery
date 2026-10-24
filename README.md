# awesome_battery

Компактный виджет батареи для [AwesomeWM](https://awesomewm.org/).

Виджет рисует иконку батареи через Cairo и не требует внешних зависимостей:
достаточно Linux-системы с `sysfs` и AwesomeWM 4.3+.

## Подключение

Скопируйте battery.lua в конфигурацию awesome. В примере используется путь `~/.config/awesome/widgets/battery.lua`.

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

`wibox.container.place` нужен, чтобы иконка была выровнена по центру
по вертикали в wibar. Затем добавьте `mybattery` в wibar, например
в правую часть:

```lua
{
    layout = wibox.layout.fixed.horizontal,
    mybattery,
    -- другие виджеты
},
```


## Параметры виджета

| Опция     | По умолчанию | Описание                                              |
|-----------|--------------|-------------------------------------------------------|
| `battery` | `"BAT0"`     | Имя каталога батареи в `/sys/class/power_supply/`      |

Опции передаются первым аргументом `battery_widget.new()`:

```lua
battery_widget.new({ battery = "BAT1" })
```


## Полезные советы

### Как узнать имя батареи

```sh
ls /sys/class/power_supply/
```

Обычно это `BAT0`, `BAT1` и т. п. Убедиться, что выбранный каталог
действительно является батареей, можно так:

```sh
cat /sys/class/power_supply/BAT0/type
# Battery
```
