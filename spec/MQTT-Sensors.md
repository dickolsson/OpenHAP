# Tasmota MQTT Sensors and Telemetry

This document describes how Tasmota reports sensor readings on
`tele/%topic%/SENSOR` and how the TelePeriod setting controls periodic
telemetry. See [MQTT.md](MQTT.md) for the index and glossary.

---

## 1. SENSOR Message Structure

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

## 2. Common Sensor Types

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

## 3. Temperature Sensors

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

## 4. Humidity Sensors

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

## 5. Telemetry

### 5.1 TelePeriod

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

### 5.2 Telemetry Topics

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
