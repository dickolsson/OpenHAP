# Tasmota MQTT State Reporting

This document describes how Tasmota reports device state — immediately on
`stat/` topics and periodically on `tele/` topics — and how to reconcile state
after a disconnection. See [MQTT.md](MQTT.md) for the index and glossary.

---

## 1. Immediate State (stat/)

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

## 2. Periodic Telemetry (tele/)

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

## 3. STATE Message Structure

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

## 4. RESULT Message Structure

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

## 5. State Reconciliation

### 5.1 Status Command

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

### 5.2 Reconnection Strategy

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

### 5.3 Retained Messages

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
