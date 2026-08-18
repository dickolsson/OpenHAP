# Tasmota MQTT Device Control

This document describes the commands used to control Tasmota relays and lights:
power, dimmer, color, color temperature, status queries, and device groups. See
[MQTT.md](MQTT.md) for the index and glossary, and
[MQTT-Transport.md](MQTT-Transport.md) for how commands and responses travel
over MQTT.

---

## 1. Power Control

Controls relay/switch state (from `Commands.md`).

**Commands:**

| Command | Topic                | Payload             | Response       |
| ------- | -------------------- | ------------------- | -------------- |
| Power   | `cmnd/%topic%/Power` | (empty)             | Query state    |
| Power   | `cmnd/%topic%/Power` | `0`, `off`, `false` | Turn OFF       |
| Power   | `cmnd/%topic%/Power` | `1`, `on`, `true`   | Turn ON        |
| Power   | `cmnd/%topic%/Power` | `2`, `toggle`       | Toggle state   |
| Power   | `cmnd/%topic%/Power` | `3`, `blink`        | Start blinking |
| Power   | `cmnd/%topic%/Power` | `4`, `blinkoff`     | Stop blinking  |

**Multi-relay devices:**

For devices with multiple relays, append the relay number:

```
cmnd/tasmota/Power1 ON    ← First relay
cmnd/tasmota/Power2 OFF   ← Second relay
cmnd/tasmota/Power0 ON    ← All relays simultaneously
```

**Response format:**

```json
stat/tasmota/RESULT = {"POWER":"ON"}
stat/tasmota/POWER = ON
```

For multi-relay:

```json
stat/tasmota/RESULT = {"POWER1":"ON"}
stat/tasmota/POWER1 = ON
```

**SetOption26:** When `SetOption26 1` is enabled, single-relay devices also use
indexed format (`POWER1` instead of `POWER`).

---

## 2. Dimmer Control

Controls brightness level (from `Commands.md`, `Lights.md`).

**Commands:**

| Command | Payload  | Description                         |
| ------- | -------- | ----------------------------------- |
| Dimmer  | (empty)  | Query current dimmer value          |
| Dimmer  | `0..100` | Set brightness percentage           |
| Dimmer  | `+`      | Increase by DimmerStep (default 10) |
| Dimmer  | `-`      | Decrease by DimmerStep              |
| Dimmer  | `+<n>`   | Increase by n                       |
| Dimmer  | `-<n>`   | Decrease by n                       |
| Dimmer  | `<`      | Decrease to 1                       |
| Dimmer  | `>`      | Increase to 100                     |
| Dimmer  | `!`      | Stop any fade in progress           |

**Example:**

```
cmnd/tasmota/Dimmer 75
  ↳ stat/tasmota/RESULT → {"Dimmer":75}
```

**Notes:**

- Dimmer range is 0-100 (percentage)
- Default behavior: Setting Dimmer > 0 automatically turns power ON
- With `SetOption20 1`: Dimmer changes do not turn power ON

**DimmerRange command:** Adjusts the internal dimmer range for lights that don't
dim well at low values:

```
cmnd/tasmota/DimmerRange 40,100   ← Min 40%, max 100%
```

---

## 3. Color Control

Controls RGB color for color-capable lights (from `Commands.md`, `Lights.md`).

### 3.1 HSBColor (Hue, Saturation, Brightness)

**Commands:**

| Command   | Payload             | Description                         |
| --------- | ------------------- | ----------------------------------- |
| HSBColor  | (empty)             | Query current HSB values            |
| HSBColor  | `<hue>,<sat>,<bri>` | Set H (0-360), S (0-100), B (0-100) |
| HSBColor1 | `0..360`            | Set hue only                        |
| HSBColor2 | `0..100`            | Set saturation only                 |
| HSBColor3 | `0..100`            | Set brightness only                 |

**Example:**

```
cmnd/tasmota/HSBColor 180,100,50
  ↳ stat/tasmota/RESULT → {"HSBColor":"180,100,50"}
```

**Value ranges:**

- Hue: 0-360 degrees (0=red, 120=green, 240=blue)
- Saturation: 0-100% (0=white/gray, 100=pure color)
- Brightness: 0-100%

### 3.2 Color (RGB Hex)

**Commands:**

| Command | Payload       | Description                         |
| ------- | ------------- | ----------------------------------- |
| Color   | (empty)       | Query current color                 |
| Color   | `#RRGGBB`     | Set RGB color (hex)                 |
| Color   | `#RRGGBBWW`   | Set RGBW color (4-channel lights)   |
| Color   | `#RRGGBBCWWW` | Set RGBCCT color (5-channel lights) |
| Color   | `r,g,b`       | Set RGB (decimal 0-255)             |
| Color   | `1..12`       | Preset colors                       |

**Preset colors:**

```
1 = red        5 = light green   9 = purple
2 = green      6 = light blue   10 = yellow
3 = blue       7 = amber        11 = pink
4 = orange     8 = cyan         12 = white (RGB)
```

**Example:**

```
cmnd/tasmota/Color #FF5500
  ↳ stat/tasmota/RESULT → {"Color":"FF550000"}
```

The reported `Color` string contains two hex digits per light channel: six
digits for an RGB light, eight for RGBW (as in this example), ten for RGBCCT.
Parse it according to the device's channel count rather than assuming six
digits.

**SetOption17:**

- `SetOption17 0`: Color shown as hex string (default)
- `SetOption17 1`: Color shown as comma-separated decimal

### 3.3 Channel Control

Direct control of individual PWM channels (from `Commands.md`):

| Command  | Payload  | Description                |
| -------- | -------- | -------------------------- |
| Channel1 | `0..100` | Red channel (or first PWM) |
| Channel2 | `0..100` | Green channel              |
| Channel3 | `0..100` | Blue channel               |
| Channel4 | `0..100` | White channel (RGBW)       |
| Channel5 | `0..100` | Cold/Warm white (RGBCCT)   |

---

## 4. Color Temperature Control

Controls white color temperature for CCT and RGBCCT lights (from `Commands.md`,
`Lights.md`).

**Commands:**

| Command | Payload    | Description                     |
| ------- | ---------- | ------------------------------- |
| CT      | (empty)    | Query current color temperature |
| CT      | `153..500` | Set color temperature in mireds |
| CT      | `+`        | Increase CT by 34 (warmer)      |
| CT      | `-`        | Decrease CT by 34 (cooler)      |

**Value range:**

- 153 = Cold White (6500K equivalent)
- 500 = Warm White (2000K equivalent)

**Mired to Kelvin conversion:**

```
Kelvin = 1,000,000 / Mired
Mired = 1,000,000 / Kelvin

Examples:
153 mireds ≈ 6536K (cold)
370 mireds ≈ 2703K (warm)
500 mireds ≈ 2000K (very warm)
```

**Example:**

```
cmnd/tasmota/CT 300
  ↳ stat/tasmota/RESULT → {"CT":300}
```

**SetOption82 (AlexaCTRange):** When `SetOption82 1`: CT range reduced from
153-500 to 200-380 for Alexa compatibility.

---

## 5. Status Queries

Query comprehensive device state (from `Commands.md`).

**Commands:**

| Command | Payload | Description                        |
| ------- | ------- | ---------------------------------- |
| Status  | (empty) | Abbreviated status information     |
| Status  | `0`     | All status information (1-11)      |
| Status  | `1`     | Device parameters                  |
| Status  | `2`     | Firmware information               |
| Status  | `3`     | Logging and telemetry parameters   |
| Status  | `4`     | Memory information                 |
| Status  | `5`     | Network information                |
| Status  | `6`     | MQTT information                   |
| Status  | `7`     | Time and daylight saving settings  |
| Status  | `8`     | Sensor information (legacy)        |
| Status  | `9`     | Power thresholds (margins)         |
| Status  | `10`    | Sensor information                 |
| Status  | `11`    | Full state (like TelePeriod STATE) |

**Example Status 11 response:**

```json
{
  "StatusSTS": {
    "Time": "2021-01-01T12:00:00",
    "Uptime": "0T01:00:00",
    "UptimeSec": 3600,
    "Heap": 27,
    "SleepMode": "Dynamic",
    "Sleep": 50,
    "LoadAvg": 19,
    "MqttCount": 1,
    "POWER": "ON",
    "Dimmer": 75,
    "Color": "FF55000000",
    "HSBColor": "20,100,100",
    "CT": 300,
    "Wifi": {
      "AP": 1,
      "SSId": "MyNetwork",
      "BSSId": "AA:BB:CC:DD:EE:FF",
      "Channel": 6,
      "RSSI": 70,
      "Signal": -65,
      "LinkCount": 1,
      "Downtime": "0T00:00:03"
    }
  }
}
```

---

## 6. Device Groups

### 6.1 GroupTopic

Devices with the same GroupTopic respond to shared commands (from `MQTT.md`):

**Default GroupTopic:** `tasmotas`

**Example - Update all devices:**

```
cmnd/tasmotas/Upgrade 1
```

**Custom GroupTopic:**

```
cmnd/tasmota/GroupTopic bedroom_lights
  ↳ Now responds to cmnd/bedroom_lights/Power
```

### 6.2 DeviceGroup Commands

Device Groups provide synchronized control without MQTT (from `Commands.md`):

**Commands:**

| Command             | Description              |
| ------------------- | ------------------------ |
| `DevGroupName<x>`   | Set device group name    |
| `DevGroupShare`     | Set shared items bitmask |
| `DevGroupSend<x>`   | Send update to group     |
| `DevGroupStatus<x>` | Show group status        |

**Shared items bitmask:**

| Value | Category         |
| ----- | ---------------- |
| 1     | Power            |
| 2     | Light brightness |
| 4     | Light fade/speed |
| 8     | Light scheme     |
| 16    | Light color      |
| 32    | Dimmer presets   |
| 64    | Event            |

**Example:**

```
DevGroupShare 19,1   ← Receive power+brightness+color, send power only
```
