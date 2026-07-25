# Tasmota MQTT Transport

This document describes the transport layer of the Tasmota MQTT protocol: topic
structure, the command/response pattern, MQTT-related configuration, error
handling, and timing. See [MQTT.md](MQTT.md) for the index and glossary.

---

## 1. Topic Structure

Tasmota organizes MQTT communication using a structured topic hierarchy with
three distinct prefixes for different message types.

### 1.1 Prefixes

Tasmota uses three prefixes to distinguish message direction and purpose (from
`MQTT.md`):

| Prefix | Direction   | Purpose                                  |
| ------ | ----------- | ---------------------------------------- |
| `cmnd` | To device   | Issue commands and query status          |
| `stat` | From device | Command responses, configuration changes |
| `tele` | From device | Periodic telemetry and sensor data       |

The prefix values can be customized using the `Prefix1`, `Prefix2`, and
`Prefix3` commands, but defaults are strongly recommended for compatibility.

### 1.2 FullTopic Pattern

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

### 1.3 Topic Tokens

Available substitution tokens in FullTopic (from `MQTT.md`):

| Token        | Description                             |
| ------------ | --------------------------------------- |
| `%prefix%`   | Replaced with `cmnd`, `stat`, or `tele` |
| `%topic%`    | Device's configured topic name          |
| `%hostname%` | Device hostname                         |
| `%id%`       | Device MAC address                      |

**Important:** If FullTopic does not contain `%topic%`, the device will not
subscribe to GroupTopic and FallbackTopic.

### 1.4 Special Topics

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

## 2. Command/Response Pattern

### 2.1 Sending Commands

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

### 2.2 Response Topics

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

### 2.3 Query Pattern

To query current state, send a command with empty payload or `?`:

```
cmnd/tasmota/Power       ← empty payload
  ↳ stat/tasmota/RESULT → {"POWER":"OFF"}
  ↳ stat/tasmota/POWER → OFF

cmnd/tasmota/Dimmer ?
  ↳ stat/tasmota/RESULT → {"Dimmer":50}
```

### 2.4 Bidirectional Flow

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

## 3. Configuration Commands

### 3.1 SetOption Commands

SetOptions control various device behaviors. Abbreviated form `SO` can be used
(e.g., `SO19 1` instead of `SetOption19 1`).

### 3.2 MQTT-Related SetOptions

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

## 4. Error Handling

### 4.1 Connection Return Codes

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

### 4.2 LWT (Last Will and Testament)

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

### 4.3 Invalid Command Responses

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

## 5. Timing Considerations

### 5.1 Response Latency

Typical response times (from practical experience):

| Operation               | Typical Latency |
| ----------------------- | --------------- |
| Power ON/OFF            | <50ms           |
| Dimmer change           | <50ms           |
| Color change            | <100ms          |
| Status query            | <100ms          |
| Sensor read (on-demand) | 100-500ms       |

### 5.2 Reconnection Behavior

MQTT reconnection settings (from `Commands.md`):

| Command           | Default | Description                            |
| ----------------- | ------- | -------------------------------------- |
| `MqttRetry`       | 10      | Retry interval in seconds (10-32000)   |
| `MqttKeepAlive`   | 30      | Keep-alive interval (1-100)            |
| `MqttTimeout`     | 4       | Socket timeout (1-100)                 |
| `MqttWifiTimeout` | 200     | WiFi connection timeout ms (100-20000) |

### 5.3 QoS Considerations

Tasmota uses QoS 0 for most messages by default:

- No delivery confirmation
- Best for high-frequency telemetry
- Lower broker overhead

For critical messages, retained messages provide persistence.
