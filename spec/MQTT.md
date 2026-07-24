# Tasmota MQTT Protocol Specification

This document is the entry point to the Tasmota MQTT protocol reference. It is
intended for implementing a HomeKit bridge that translates between Tasmota MQTT
messages and Apple HomeKit. Detailed protocol information lives in the
`MQTT-*.md` topic files indexed below.

**Source References:** Information in these documents is primarily derived from
the Tasmota documentation files `MQTT.md`, `Commands.md`, `Lights.md`, and
`Buttons-and-Switches.md` in the Tasmota-Docs repository.

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
when FullTopic omits the `%topic%` token (see
[MQTT-Transport.md](MQTT-Transport.md) §1.3).

**GroupTopic** : A shared topic that multiple devices can subscribe to for
synchronized control. Default is `tasmotas`.

**LWT** (Last Will and Testament) : An MQTT feature that allows the broker to
publish a message when a device disconnects ungracefully. Tasmota uses
`tele/%topic%/LWT` with payloads `Online` or `Offline`.

**Retained Message** : An MQTT message with the retain flag set, stored by the
broker and delivered to new subscribers immediately upon subscription.

**TelePeriod** : The interval in seconds between automatic telemetry messages.
Default is 300 seconds (5 minutes). Range: 10-3600 seconds; 0 disables telemetry
and 1 resets the value to the firmware default (see
[MQTT-Sensors.md](MQTT-Sensors.md) §5.1).

---

## 2. Protocol Overview

Tasmota devices communicate over MQTT in these patterns:

1. **Topics** — Every message travels on a topic built from the FullTopic
   pattern, with prefixes `cmnd` (to device), `stat` (from device, immediate),
   and `tele` (from device, periodic). See
   [MQTT-Transport.md](MQTT-Transport.md).

2. **Command/Response** — Commands published to `cmnd/%topic%/<command>` are
   answered on `stat/%topic%/RESULT` (JSON) and `stat/%topic%/<CMD>` (simple
   value). An empty payload queries current state. See
   [MQTT-Transport.md](MQTT-Transport.md).

3. **Device Control** — Power, dimmer, color, and color temperature commands
   control relays and lights; `Status` queries return comprehensive state. See
   [MQTT-Control.md](MQTT-Control.md).

4. **State Reporting** — State changes are published immediately on `stat/`
   topics and periodically on `tele/%topic%/STATE`; after a disconnection, state
   is reconciled with `Status` queries. See [MQTT-State.md](MQTT-State.md).

5. **Sensors and Telemetry** — Sensor readings are published on
   `tele/%topic%/SENSOR` at TelePeriod intervals. See
   [MQTT-Sensors.md](MQTT-Sensors.md).

6. **Availability** — The retained `tele/%topic%/LWT` topic reports `Online` or
   `Offline` via MQTT Last Will and Testament. See
   [MQTT-Transport.md](MQTT-Transport.md).

---

## 3. Topic Files

Detailed protocol information is organized into these files:

| File                                   | Content                                                                       |
| -------------------------------------- | ----------------------------------------------------------------------------- |
| [MQTT-Transport.md](MQTT-Transport.md) | Topic structure, command/response pattern, SetOptions, errors, timing         |
| [MQTT-Control.md](MQTT-Control.md)     | Power, dimmer, color, color temperature, status queries, device groups        |
| [MQTT-State.md](MQTT-State.md)         | Immediate and periodic state reporting, STATE/RESULT messages, reconciliation |
| [MQTT-Sensors.md](MQTT-Sensors.md)     | SENSOR message structure, sensor types, TelePeriod telemetry                  |

---

## 4. HomeKit Mapping Reference

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

## 5. Quick Command Reference

### 5.1 Essential Commands for HomeKit Bridge

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

### 5.2 Subscribe Topics

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
