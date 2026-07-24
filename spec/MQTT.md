# Tasmota MQTT Protocol Specification

This document specifies the MQTT protocol used by Tasmota devices to communicate
over MQTT. It is intended for implementing a HomeKit bridge that translates
between Tasmota MQTT messages and Apple HomeKit.

**Source References:** Information in this document is primarily derived from
the Tasmota documentation files `MQTT.md`, `Commands.md`, `Lights.md`, and
`Buttons-and-Switches.md` in the Tasmota-Docs repository.

---

## Table of Contents

1. [Glossary](#1-glossary)
2. [Topic Structure](#2-topic-structure)
   - 2.1 [Prefixes](#21-prefixes)
   - 2.2 [FullTopic Pattern](#22-fulltopic-pattern)
   - 2.3 [Topic Tokens](#23-topic-tokens)
   - 2.4 [Special Topics](#24-special-topics)
3. [Command/Response Pattern](#3-commandresponse-pattern)
   - 3.1 [Sending Commands](#31-sending-commands)
   - 3.2 [Response Topics](#32-response-topics)
   - 3.3 [Query Pattern](#33-query-pattern)
   - 3.4 [Bidirectional Flow](#34-bidirectional-flow)
4. [Device Control Commands](#4-device-control-commands)
   - 4.1 [Power Control](#41-power-control)
   - 4.2 [Dimmer Control](#42-dimmer-control)
   - 4.3 [Color Control](#43-color-control)
   - 4.4 [Color Temperature Control](#44-color-temperature-control)
   - 4.5 [Status Queries](#45-status-queries)
5. [State Reporting](#5-state-reporting)
   - 5.1 [Immediate State (stat/)](#51-immediate-state-stat)
   - 5.2 [Periodic Telemetry (tele/)](#52-periodic-telemetry-tele)
   - 5.3 [STATE Message Structure](#53-state-message-structure)
   - 5.4 [RESULT Message Structure](#54-result-message-structure)
6. [State Reconciliation](#6-state-reconciliation)
   - 6.1 [Status Command](#61-status-command)
   - 6.2 [Reconnection Strategy](#62-reconnection-strategy)
   - 6.3 [Retained Messages](#63-retained-messages)
7. [Sensor Data](#7-sensor-data)
   - 7.1 [SENSOR Message Structure](#71-sensor-message-structure)
   - 7.2 [Common Sensor Types](#72-common-sensor-types)
   - 7.3 [Temperature Sensors](#73-temperature-sensors)
   - 7.4 [Humidity Sensors](#74-humidity-sensors)
8. [Telemetry](#8-telemetry)
   - 8.1 [TelePeriod](#81-teleperiod)
   - 8.2 [Telemetry Topics](#82-telemetry-topics)
9. [Configuration Commands](#9-configuration-commands)
   - 9.1 [SetOption Commands](#91-setoption-commands)
   - 9.2 [MQTT-Related SetOptions](#92-mqtt-related-setoptions)
10. [Error Handling](#10-error-handling)
    - 10.1 [Connection Return Codes](#101-connection-return-codes)
    - 10.2 [LWT (Last Will and Testament)](#102-lwt-last-will-and-testament)
    - 10.3 [Invalid Command Responses](#103-invalid-command-responses)
11. [Device Groups](#11-device-groups)
    - 11.1 [GroupTopic](#111-grouptopic)
    - 11.2 [DeviceGroup Commands](#112-devicegroup-commands)
12. [Timing Considerations](#12-timing-considerations)
    - 12.1 [Response Latency](#121-response-latency)
    - 12.2 [Reconnection Behavior](#122-reconnection-behavior)
    - 12.3 [QoS Considerations](#123-qos-considerations)
13. [HomeKit Mapping Reference](#13-homekit-mapping-reference)

---

## 1. Glossary

**cmnd** (command prefix) : The MQTT topic prefix used for sending commands to
Tasmota devices. Default value is `cmnd`.

**stat** (status prefix) : The MQTT topic prefix used by Tasmota to publish
command responses and immediate state changes. Default value is `stat`.

**tele** (telemetry prefix) : The MQTT topic prefix used by Tasmota to publish
periodic telemetry data including sensor readings and device state. Default
value is `tele`.

**%prefix%** : A token in FullTopic that is replaced with one of the three
prefixes (`cmnd`, `stat`, or `tele`) depending on message direction.

**%topic%** : A token in FullTopic that is replaced with the device's configured
topic name. Each device should have a unique topic.

**FullTopic** : The complete MQTT topic pattern used for communication.
Constructed from tokens that are substituted at runtime. Default pattern:
`%prefix%/%topic%/`.

**FallbackTopic** : An emergency topic (`DVES_XXXXXX_fb` where XXXXXX is derived
from MAC address) that works regardless of the configured Topic. Not subscribed
when FullTopic omits the `%topic%` token (see 2.3).

**GroupTopic** : A shared topic that multiple devices can subscribe to for
synchronized control. Default is `tasmotas`.

**LWT** (Last Will and Testament) : An MQTT feature that allows the broker to
publish a message when a device disconnects ungracefully. Tasmota uses
`tele/%topic%/LWT` with payloads `Online` or `Offline`.

**Retained Message** : An MQTT message with the retain flag set, stored by the
broker and delivered to new subscribers immediately upon subscription.

**TelePeriod** : The interval in seconds between automatic telemetry messages.
Default is 300 seconds (5 minutes). Range: 10-3600 seconds; 0 disables telemetry
and 1 resets the value to the firmware default (see 8.1).

---

## 2. Topic Structure

Tasmota organizes MQTT communication using a structured topic hierarchy with
three distinct prefixes for different message types.

### 2.1 Prefixes

Tasmota uses three prefixes to distinguish message direction and purpose (from
`MQTT.md`):

| Prefix | Direction   | Purpose                                  |
| ------ | ----------- | ---------------------------------------- |
| `cmnd` | To device   | Issue commands and query status          |
| `stat` | From device | Command responses, configuration changes |
| `tele` | From device | Periodic telemetry and sensor data       |

The prefix values can be customized using the `Prefix1`, `Prefix2`, and
`Prefix3` commands, but defaults are strongly recommended for compatibility.

### 2.2 FullTopic Pattern

The complete topic is constructed using the FullTopic pattern with token
substitution. The default pattern is:

```
%prefix%/%topic%/
```

**Examples with default FullTopic:**

```
cmnd/tasmota_switch/POWER     ← Command to turn power on/off
stat/tasmota_switch/POWER     ← Power state response
stat/tasmota_switch/RESULT    ← JSON command result
tele/tasmota_switch/STATE     ← Periodic state telemetry
tele/tasmota_switch/SENSOR    ← Sensor readings
tele/tasmota_switch/LWT       ← Connection status
```

**Custom FullTopic examples:**

```
FullTopic tasmota/%topic%/%prefix%/
  → cmnd topic: tasmota/bedroom_light/cmnd/POWER

FullTopic %prefix%/home/cellar/%topic%/
  → cmnd topic: cmnd/home/cellar/bedroom_light/POWER
```

### 2.3 Topic Tokens

Available substitution tokens in FullTopic (from `MQTT.md`):

| Token        | Description                             |
| ------------ | --------------------------------------- |
| `%prefix%`   | Replaced with `cmnd`, `stat`, or `tele` |
| `%topic%`    | Device's configured topic name          |
| `%hostname%` | Device hostname                         |
| `%id%`       | Device MAC address                      |

**Important:** If FullTopic does not contain `%topic%`, the device will not
subscribe to GroupTopic and FallbackTopic.

### 2.4 Special Topics

**FallbackTopic:**

```
DVES_XXXXXX_fb
```

Where `XXXXXX` is derived from the last 6 characters of the device's MAC
address. This provides emergency access when the configured topic is unknown.

**GroupTopic:**

```
Default: tasmotas
```

All devices with the same GroupTopic respond to commands sent to that topic.
Useful for firmware updates or synchronized control.

**LWT Topic:**

```
tele/%topic%/LWT
```

Published with `Online` on connection, broker publishes `Offline` on ungraceful
disconnect.

---

## 3. Command/Response Pattern

### 3.1 Sending Commands

Commands are sent to Tasmota using the `cmnd` prefix with the command name as
the final topic segment (from `MQTT.md`, `Commands.md`):

**Topic format:**

```
cmnd/%topic%/<command>
```

**Payload:**

```
<parameter>
```

**Rules:**

- Commands are case-insensitive (`POWER`, `Power`, `power` are equivalent)
- Empty payload sends a status query for that command
- Use `?` as payload if your MQTT client cannot send empty payloads
- Payloads `0`, `off`, `false` are equivalent
- Payloads `1`, `on`, `true` are equivalent
- Payloads `2`, `toggle` toggle the current state

**Backlog:** Several commands can be sent in a single message using the
`Backlog` command — up to 30 commands separated by `;`:

```
cmnd/%topic%/Backlog Power ON; Dimmer 50; CT 300
```

`Backlog0` executes the commands without the default delay between them, and a
`Backlog` without arguments clears a pending queue.

### 3.2 Response Topics

Tasmota responds to commands on two topics (from `MQTT.md`):

**Default behavior:**

```
stat/%topic%/RESULT  → JSON response with command result
stat/%topic%/<CMD>   → Simple response on command-specific topic
```

**Example - Power command:**

```
cmnd/tasmota/Power TOGGLE
  ↳ stat/tasmota/RESULT → {"POWER":"ON"}
  ↳ stat/tasmota/POWER → ON
```

**SetOption4 behavior:** When `SetOption4 1` is enabled, RESULT is replaced with
the command name:

```
cmnd/tasmota/PowerOnState
  ↳ stat/tasmota/POWERONSTATE → {"PowerOnState":3}
```

### 3.3 Query Pattern

To query current state, send a command with empty payload or `?`:

```
cmnd/tasmota/Power       ← empty payload
  ↳ stat/tasmota/RESULT → {"POWER":"OFF"}
  ↳ stat/tasmota/POWER → OFF

cmnd/tasmota/Dimmer ?
  ↳ stat/tasmota/RESULT → {"Dimmer":50}
```

### 3.4 Bidirectional Flow

**Complete request/response cycle diagram:**

```
┌──────────────┐                              ┌──────────────┐
│   Client     │                              │   Tasmota    │
│  (OpenHAP)   │                              │   Device     │
└──────┬───────┘                              └──────┬───────┘
       │                                             │
       │  cmnd/device/POWER ON                       │
       │────────────────────────────────────────────>│
       │                                             │
       │                    stat/device/RESULT       │
       │<────────────────────{"POWER":"ON"}──────────│
       │                                             │
       │                    stat/device/POWER        │
       │<─────────────────────────ON─────────────────│
       │                                             │
       │                                             │
       │  cmnd/device/Status 11                      │
       │────────────────────────────────────────────>│
       │                                             │
       │                stat/device/STATUS11         │
       │<─────────────{full state JSON}──────────────│
       │                                             │
       │                                             │
       │                 (TelePeriod elapsed)        │
       │                                             │
       │                  tele/device/STATE          │
       │<─────────────{periodic state JSON}──────────│
       │                                             │
       │                  tele/device/SENSOR         │
       │<────────────{sensor readings JSON}──────────│
       │                                             │
```

---

## 4. Device Control Commands

### 4.1 Power Control

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

### 4.2 Dimmer Control

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

### 4.3 Color Control

Controls RGB color for color-capable lights (from `Commands.md`, `Lights.md`).

#### 4.3.1 HSBColor (Hue, Saturation, Brightness)

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

#### 4.3.2 Color (RGB Hex)

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

#### 4.3.3 Channel Control

Direct control of individual PWM channels (from `Commands.md`):

| Command  | Payload  | Description                |
| -------- | -------- | -------------------------- |
| Channel1 | `0..100` | Red channel (or first PWM) |
| Channel2 | `0..100` | Green channel              |
| Channel3 | `0..100` | Blue channel               |
| Channel4 | `0..100` | White channel (RGBW)       |
| Channel5 | `0..100` | Cold/Warm white (RGBCCT)   |

### 4.4 Color Temperature Control

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

### 4.5 Status Queries

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

## 5. State Reporting

### 5.1 Immediate State (stat/)

Immediate state changes are published on `stat/` topics when:

- A command is received and executed
- Physical button/switch is pressed
- Rule triggers a state change

**Topics:**

```
stat/%topic%/RESULT   → JSON with command result
stat/%topic%/POWER    → Simple power state
stat/%topic%/POWER1   → Multi-relay power state
```

**PowerRetain setting:** When `PowerRetain 1` is enabled, power state messages
are published with MQTT retain flag.

**Button and switch events:** By default a physical button or switch toggles the
device's own relay and only the resulting `POWER` message is published. To
receive press events directly (e.g. for a HomeKit stateless programmable
switch), detach them from the relays:

- `SetOption73 1`: buttons stop controlling the relay and each press publishes
  `stat/%topic%/RESULT` with `{"Button<x>":{"Action":"SINGLE"}}`; actions are
  `SINGLE`, `DOUBLE`, `TRIPLE`, `QUAD`, `PENTA`, and `HOLD`
- `SetOption114 1`: switches are detached from all relays and publish
  `{"Switch<x>":{"Action":"TOGGLE"}}`, with the action depending on the
  configured SwitchMode

### 5.2 Periodic Telemetry (tele/)

Periodic telemetry is published at intervals defined by TelePeriod (from
`MQTT.md`).

**Topics:**

```
tele/%topic%/STATE    → Device state
tele/%topic%/SENSOR   → Sensor readings
tele/%topic%/LWT      → Connection status (Online/Offline)
```

**SetOption59:** When `SetOption59 1`: Additional `tele/%topic%/STATE` is sent
along with `stat/%topic%/RESULT` for Power commands.

### 5.3 STATE Message Structure

The STATE message includes complete device status (from `Commands.md`):

```json
{
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
  "White": 0,
  "CT": 300,
  "Channel": [100, 33, 0, 0, 0],
  "Scheme": 0,
  "Fade": "OFF",
  "Speed": 1,
  "LedTable": "ON",
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
```

**Field presence:** Not all fields are present in every STATE message. Fields
appear based on device configuration:

- `POWER`: Always present for devices with relays
- `POWER1`, `POWER2`, etc.: Multi-relay devices
- `Dimmer`: Present for dimmable lights
- `Color`, `HSBColor`, `Channel`: Present for RGB lights
- `CT`: Present for CCT/RGBCCT lights
- `White`: Present for RGBW/RGBCCT lights

### 5.4 RESULT Message Structure

RESULT messages contain the fields relevant to the executed command rather than
the full device status. Depending on the command and light type, the response
may include related fields whose values did not change (see the Color and CT
examples below), so the presence of a field in a RESULT does not imply that it
changed:

**Power change:**

```json
{ "POWER": "ON" }
```

**Dimmer change:**

```json
{ "Dimmer": 75 }
```

**Color change:**

```json
{
  "POWER": "ON",
  "Dimmer": 100,
  "Color": "FF550000",
  "HSBColor": "20,100,100",
  "Channel": [100, 33, 0, 0]
}
```

**CT change:**

```json
{
  "POWER": "ON",
  "Dimmer": 100,
  "CT": 300,
  "Channel": [0, 0, 0, 100, 50]
}
```

---

## 6. State Reconciliation

### 6.1 Status Command

To reconcile state after reconnection, use `Status 11` for full state (from
`Commands.md`):

```
cmnd/tasmota/Status 11
  ↳ stat/tasmota/STATUS11 → {full state JSON}
```

For sensor state:

```
cmnd/tasmota/Status 10
  ↳ stat/tasmota/STATUS10 → {sensor JSON}
```

### 6.2 Reconnection Strategy

Recommended state reconciliation after network interruption:

1. **Subscribe to all relevant topics:**

   ```
   stat/%topic%/RESULT
   stat/%topic%/POWER
   tele/%topic%/STATE
   tele/%topic%/SENSOR
   tele/%topic%/LWT
   ```

2. **Check LWT for device availability:**

   ```
   tele/%topic%/LWT = "Online"  → device is connected
   tele/%topic%/LWT = "Offline" → device is disconnected
   ```

3. **Query full state:**

   ```
   cmnd/%topic%/Status 11  → Full device state
   cmnd/%topic%/Status 10  → Sensor readings
   ```

4. **Force telemetry update:**
   ```
   cmnd/%topic%/TelePeriod  → Triggers immediate STATE and SENSOR
   ```

### 6.3 Retained Messages

Tasmota supports retained messages for specific data types (from `MQTT.md`):

| Command          | Description                 |
| ---------------- | --------------------------- |
| `PowerRetain 1`  | Retain power state messages |
| `SensorRetain 1` | Retain sensor telemetry     |
| `StateRetain 1`  | Retain STATE messages       |
| `StatusRetain 1` | Retain STATUS messages      |
| `InfoRetain 1`   | Retain INFO messages        |

**Warning about PowerRetain:** A retained power message will **always override
PowerOnState** setting on restart. This can cause "ghost switching" if a
retained OFF message exists when the device expects to power ON.

**Clearing retained messages:** Use an MQTT client to publish empty retained
messages to clear old values:

```
mosquitto_pub -t "cmnd/tasmota/POWER" -r -n
```

---

## 7. Sensor Data

### 7.1 SENSOR Message Structure

Sensor data is published on `tele/%topic%/SENSOR` (from `MQTT.md`):

```json
{
  "Time": "2021-01-01T12:00:00",
  "DS18B20": {
    "Temperature": 20.6
  },
  "DHT11": {
    "Temperature": 22.5,
    "Humidity": 45.0
  },
  "BME280": {
    "Temperature": 21.3,
    "Humidity": 55.0,
    "Pressure": 1013.25
  },
  "ENERGY": {
    "TotalStartTime": "2021-01-01T00:00:00",
    "Total": 123.456,
    "Yesterday": 1.234,
    "Today": 0.567,
    "Power": 100,
    "ApparentPower": 110,
    "ReactivePower": 45,
    "Factor": 0.91,
    "Voltage": 230,
    "Current": 0.435
  }
}
```

### 7.2 Common Sensor Types

**Temperature sensors:**

- `DS18B20`: Dallas 1-Wire temperature sensor
- `DS18S20`: Dallas 1-Wire temperature sensor (older)
- `AM2301`: DHT21/AM2301, DHT22/AM2302, AM2320, and AM2321 temperature/humidity
  (all variants report under the `AM2301` key)
- `DHT11`: DHT11 temperature/humidity
- `BME280`: Bosch temperature/humidity/pressure
- `BME680`: Bosch temperature/humidity/pressure/gas
- `BMP280`: Bosch temperature/pressure
- `SHT3X`: Sensirion temperature/humidity

**Power monitoring:**

- `ENERGY`: Power monitoring data

### 7.3 Temperature Sensors

**DS18B20 example:**

```json
{
  "Time": "2021-01-01T12:00:00",
  "DS18B20": {
    "Id": "01131B123456",
    "Temperature": 20.6
  }
}
```

**Multiple DS18B20 sensors:**

```json
{
  "Time": "2021-01-01T12:00:00",
  "DS18B20-1": {
    "Id": "01131B123456",
    "Temperature": 20.6
  },
  "DS18B20-2": {
    "Id": "01131B789ABC",
    "Temperature": 22.1
  }
}
```

**Temperature units:**

- Default: Celsius
- `SetOption8 1`: Use Fahrenheit
- SENSOR messages carry a top-level `TempUnit` field (`"C"` or `"F"`) indicating
  the unit in use; check it before converting for HomeKit

**Resolution:**

- `TempRes 0..3`: Set decimal places (default 1)

**Offset calibration:**

- `TempOffset -12.6..12.6`: Calibration offset applied to all sensors

### 7.4 Humidity Sensors

**AM2301 (DHT21/DHT22/AM2302) example:**

```json
{
  "Time": "2021-01-01T12:00:00",
  "AM2301": {
    "Temperature": 22.5,
    "Humidity": 45.0
  }
}
```

**BME280 example:**

```json
{
  "Time": "2021-01-01T12:00:00",
  "BME280": {
    "Temperature": 21.3,
    "Humidity": 55.0,
    "Pressure": 1013.25,
    "DewPoint": 11.5
  }
}
```

**Resolution:**

- `HumRes 0..3`: Set decimal places for humidity (default 1)
- `PressRes 0..3`: Set decimal places for pressure (default 1)

**Offset calibration:**

- `HumOffset -10.0..10.0`: Calibration offset for humidity

---

## 8. Telemetry

### 8.1 TelePeriod

The `TelePeriod` setting controls automatic telemetry publishing (from
`Commands.md`):

**Commands:**

| Command    | Payload    | Description                               |
| ---------- | ---------- | ----------------------------------------- |
| TelePeriod | (empty)    | Query current value and trigger telemetry |
| TelePeriod | `0`        | Disable telemetry (manual only)           |
| TelePeriod | `1`        | Reset to firmware default (300s)          |
| TelePeriod | `10..3600` | Set interval in seconds                   |

**Example:**

```
cmnd/tasmota/TelePeriod 60
  ↳ stat/tasmota/RESULT → {"TelePeriod":60}
```

Sending `TelePeriod` without payload also triggers immediate STATE and SENSOR
messages.

### 8.2 Telemetry Topics

Periodic telemetry uses `tele/` prefix:

```
tele/%topic%/STATE   → Published every TelePeriod
tele/%topic%/SENSOR  → Published every TelePeriod (if sensors present)
tele/%topic%/LWT     → Connection status (retained)
```

**Additional telemetry:**

Power monitoring threshold alerts:

```
tele/%topic%/POWER_LOW ON    → Power below threshold
tele/%topic%/POWER_LOW OFF   → Power above threshold
```

---

## 9. Configuration Commands

### 9.1 SetOption Commands

SetOptions control various device behaviors. Abbreviated form `SO` can be used
(e.g., `SO19 1` instead of `SetOption19 1`).

### 9.2 MQTT-Related SetOptions

From `Commands.md`:

| SetOption | Default | Description                           |
| --------- | ------- | ------------------------------------- |
| SO3       | 1       | Enable MQTT                           |
| SO4       | 0       | RESULT topic (0) vs command topic (1) |
| SO10      | 0       | Send "Offline" on topic change        |
| SO19      | 0       | Tasmota discovery for Home Assistant  |
| SO20      | 0       | Update Dimmer/Color without power on  |
| SO26      | 0       | Use POWER1 even for single relay      |
| SO59      | 0       | Send tele/STATE on RESULT             |
| SO90      | 0       | Send only JSON MQTT messages          |
| SO104     | 0       | Disable retained messages             |
| SO140     | 0       | Open persistent MQTT session          |

---

## 10. Error Handling

### 10.1 Connection Return Codes

MQTT connection return codes from PubSubClient (from `MQTT.md`):

| Code | Constant                     | Description                 |
| ---- | ---------------------------- | --------------------------- |
| -5   | MQTT_DNS_DISCONNECTED        | DNS server unreachable      |
| -4   | MQTT_CONNECTION_TIMEOUT      | Server timeout              |
| -3   | MQTT_CONNECTION_LOST         | Network connection broken   |
| -2   | MQTT_CONNECT_FAILED          | Network connection failed   |
| -1   | MQTT_DISCONNECTED            | Client disconnected cleanly |
| 0    | MQTT_CONNECTED               | Successfully connected      |
| 1    | MQTT_CONNECT_BAD_PROTOCOL    | Unsupported MQTT version    |
| 2    | MQTT_CONNECT_BAD_CLIENT_ID   | Client ID rejected          |
| 3    | MQTT_CONNECT_UNAVAILABLE     | Server unable to accept     |
| 4    | MQTT_CONNECT_BAD_CREDENTIALS | Bad username/password       |
| 5    | MQTT_CONNECT_UNAUTHORIZED    | Not authorized              |

**Console output example:**

```
MQT: Connect failed to broker:1883, rc 5. Retry in 10 sec
```

### 10.2 LWT (Last Will and Testament)

Tasmota configures LWT on connection (from `MQTT.md`):

**Topic:**

```
tele/%topic%/LWT
```

**Payloads:**

- `Online` - Published on successful connection (retained)
- `Offline` - Published by broker on ungraceful disconnect

**Monitoring:**

```bash
mosquitto_sub -t "tele/+/LWT"
# Output:
# Offline
# Online
```

### 10.3 Invalid Command Responses

When an invalid command or parameter is sent:

**Unknown command:**

```
cmnd/tasmota/InvalidCommand
  ↳ stat/tasmota/RESULT → {"Command":"Unknown"}
```

**Invalid parameter:**

```
cmnd/tasmota/Dimmer 150
  ↳ stat/tasmota/RESULT → {"Dimmer":100}  ← Capped to valid range
```

---

## 11. Device Groups

### 11.1 GroupTopic

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

### 11.2 DeviceGroup Commands

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

---

## 12. Timing Considerations

### 12.1 Response Latency

Typical response times (from practical experience):

| Operation               | Typical Latency |
| ----------------------- | --------------- |
| Power ON/OFF            | <50ms           |
| Dimmer change           | <50ms           |
| Color change            | <100ms          |
| Status query            | <100ms          |
| Sensor read (on-demand) | 100-500ms       |

### 12.2 Reconnection Behavior

MQTT reconnection settings (from `Commands.md`):

| Command           | Default | Description                            |
| ----------------- | ------- | -------------------------------------- |
| `MqttRetry`       | 10      | Retry interval in seconds (10-32000)   |
| `MqttKeepAlive`   | 30      | Keep-alive interval (1-100)            |
| `MqttTimeout`     | 4       | Socket timeout (1-100)                 |
| `MqttWifiTimeout` | 200     | WiFi connection timeout ms (100-20000) |

### 12.3 QoS Considerations

Tasmota uses QoS 0 for most messages by default:

- No delivery confirmation
- Best for high-frequency telemetry
- Lower broker overhead

For critical messages, retained messages provide persistence.

---

## 13. HomeKit Mapping Reference

Quick reference for translating between Tasmota and HomeKit:

| Tasmota                  | Value Range        | HomeKit                 | Value Range      |
| ------------------------ | ------------------ | ----------------------- | ---------------- |
| `POWER ON/OFF`           | ON, OFF            | On characteristic       | true, false      |
| `Dimmer`                 | 0-100              | Brightness              | 0-100            |
| `HSBColor1` (Hue)        | 0-360              | Hue                     | 0-360            |
| `HSBColor2` (Saturation) | 0-100              | Saturation              | 0-100            |
| `HSBColor3` (Brightness) | 0-100              | Brightness              | 0-100            |
| `CT`                     | 153-500 (mireds)   | ColorTemperature        | 140-500 (mireds) |
| Temperature sensor       | Celsius/Fahrenheit | CurrentTemperature      | Celsius          |
| Humidity sensor          | 0-100%             | CurrentRelativeHumidity | 0-100%           |

**Notes:**

- HomeKit expects temperature in Celsius; convert if Tasmota uses Fahrenheit
  (`SetOption8 1`)
- CT (Color Temperature) uses mireds in both protocols, ranges may differ
- HomeKit brightness is 0-100, matching Tasmota Dimmer directly
- Tasmota's `Power` maps directly to HomeKit's `On` characteristic

---

## Appendix: Quick Command Reference

### Essential Commands for HomeKit Bridge

**Power Control:**

```
cmnd/%topic%/Power          → Query/set power (payload: empty, 0, 1, 2)
cmnd/%topic%/Power1         → First relay
cmnd/%topic%/Power2         → Second relay
```

**Brightness:**

```
cmnd/%topic%/Dimmer         → Query/set 0-100
```

**Color (RGB):**

```
cmnd/%topic%/HSBColor       → Query/set "hue,sat,bri"
cmnd/%topic%/HSBColor1      → Hue only (0-360)
cmnd/%topic%/HSBColor2      → Saturation only (0-100)
cmnd/%topic%/Color          → Set hex color #RRGGBB
```

**Color Temperature:**

```
cmnd/%topic%/CT             → Query/set 153-500 mireds
```

**State Query:**

```
cmnd/%topic%/Status 11      → Full state JSON
cmnd/%topic%/Status 10      → Sensor readings
cmnd/%topic%/TelePeriod     → Trigger immediate telemetry
```

### Subscribe Topics

**Essential subscriptions:**

```
stat/%topic%/RESULT         → Command responses
stat/%topic%/POWER          → Power state changes
stat/%topic%/POWER1         → Multi-relay (POWER1, POWER2, ...); MQTT has
stat/%topic%/POWER2           no partial-level wildcard, so subscribe to
                              each relay topic or to stat/%topic%/+
tele/%topic%/STATE          → Periodic state
tele/%topic%/SENSOR         → Sensor readings
tele/%topic%/LWT            → Online/Offline status
```
