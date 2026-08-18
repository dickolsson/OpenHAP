# HAP Accessory Categories

Accessory categories determine the icon displayed in the Home app during pairing
and in accessory lists. The category is a hint to the UI — it does not restrict
which services can be implemented.

---

## 1. Category Identifiers

From `const.py:23-50` and `Categories.md`:

| ID  | Constant                       | Name                |
| --- | ------------------------------ | ------------------- |
| 1   | `CATEGORY_OTHER`               | Other               |
| 2   | `CATEGORY_BRIDGE`              | Bridge              |
| 3   | `CATEGORY_FAN`                 | Fan                 |
| 4   | `CATEGORY_GARAGE_DOOR_OPENER`  | Garage Door Opener  |
| 5   | `CATEGORY_LIGHTBULB`           | Lightbulb           |
| 6   | `CATEGORY_DOOR_LOCK`           | Door Lock           |
| 7   | `CATEGORY_OUTLET`              | Outlet              |
| 8   | `CATEGORY_SWITCH`              | Switch              |
| 9   | `CATEGORY_THERMOSTAT`          | Thermostat          |
| 10  | `CATEGORY_SENSOR`              | Sensor              |
| 11  | `CATEGORY_ALARM_SYSTEM`        | Security System     |
| 12  | `CATEGORY_DOOR`                | Door                |
| 13  | `CATEGORY_WINDOW`              | Window              |
| 14  | `CATEGORY_WINDOW_COVERING`     | Window Covering     |
| 15  | `CATEGORY_PROGRAMMABLE_SWITCH` | Programmable Switch |
| 16  | `CATEGORY_RANGE_EXTENDER`      | Range Extender      |
| 17  | `CATEGORY_CAMERA`              | IP Camera           |
| 18  | `CATEGORY_VIDEO_DOOR_BELL`     | Video Doorbell      |
| 19  | `CATEGORY_AIR_PURIFIER`        | Air Purifier        |
| 20  | `CATEGORY_HEATER`              | Heater              |
| 21  | `CATEGORY_AIR_CONDITIONER`     | Air Conditioner     |
| 22  | `CATEGORY_HUMIDIFIER`          | Humidifier          |
| 23  | `CATEGORY_DEHUMIDIFIER`        | Dehumidifier        |
| 26  | `CATEGORY_SPEAKER`             | Speaker             |
| 28  | `CATEGORY_SPRINKLER`           | Sprinkler           |
| 29  | `CATEGORY_FAUCET`              | Faucet              |
| 30  | `CATEGORY_SHOWER_HEAD`         | Shower Head         |
| 31  | `CATEGORY_TELEVISION`          | Television          |
| 32  | `CATEGORY_TARGET_CONTROLLER`   | Remote Controller   |

Note: IDs 24, 25 and 27 are marked Reserved in the public specification and are
absent from HAP-python; HAP-NodeJS defines them as the Apple-only device types
`APPLE_TV` (24), `HOMEPOD` (25) and `AIRPORT` (27). Later protocol revisions add
four more categories, defined in HAP-NodeJS:

| ID  | Constant (HAP-NodeJS) | Name               |
| --- | --------------------- | ------------------ |
| 33  | `ROUTER`              | Wi-Fi Router       |
| 34  | `AUDIO_RECEIVER`      | Audio Receiver     |
| 35  | `TV_SET_TOP_BOX`      | TV Set Top Box     |
| 36  | `TV_STREAMING_STICK`  | TV Streaming Stick |

---

## 2. Category Name List (HomeSpan)

From `Categories.md`, the category names HomeSpan supports (not a complete list
— HomeSpan omits Range Extender (16), Speaker (26) and Remote Controller (32),
which appear in the identifier table above):

- AirConditioners
- AirPurifiers
- Bridges
- Dehumidifiers
- Doors
- Fans
- Faucets
- GarageDoorOpeners
- Heaters
- Humidifiers
- IPCameras
- Lighting
- Locks
- Other
- Outlets
- ProgrammableSwitches
- SecuritySystems
- Sensors
- ShowerSystems
- Sprinklers
- Switches
- Television
- Thermostats
- VideoDoorbells
- WindowCoverings
- Windows

---

## 3. Usage

The category is specified in the mDNS TXT record `ci` field:

```
ci=5
```

This indicates a Lightbulb accessory.

---

## 4. Category Selection Guidelines

| Accessory Type               | Recommended Category     |
| ---------------------------- | ------------------------ |
| Bridge with multiple devices | Bridge (2)               |
| Smart light                  | Lightbulb (5)            |
| Smart plug/outlet            | Outlet (7)               |
| On/off switch                | Switch (8)               |
| Temperature sensor           | Sensor (10)              |
| Motion sensor                | Sensor (10)              |
| Contact sensor               | Sensor (10)              |
| Thermostat/HVAC              | Thermostat (9)           |
| Door lock                    | Door Lock (6)            |
| Garage door                  | Garage Door Opener (4)   |
| Ceiling fan                  | Fan (3)                  |
| Window blinds                | Window Covering (14)     |
| Security alarm               | Security System (11)     |
| Button/remote                | Programmable Switch (15) |
| TV                           | Television (31)          |

---

## 5. Notes

1. **Category vs Services**: The category is purely cosmetic — it only affects
   the icon shown in the Home app. An accessory with category "Lightbulb" can
   implement any services.

2. **Bridges**: A bridge (category 2) aggregates multiple accessories. The
   bridge's category should always be 2, regardless of what types of accessories
   it bridges. Bridged accessories have no advertised category of their own:
   HomeKitADK assigns them category 0 (`kHAPAccessoryCategory_BridgedAccessory`,
   "accessory that is accessed through a bridge"); only the bridge's category
   appears in the `ci` TXT record.

3. **Unknown categories**: If the Home app encounters an unknown category ID, it
   falls back to the "Other" icon.

4. **Persistence**: The category should not change after initial pairing, as
   this may confuse users.

5. **Obsolete categories**: Range Extender (16) is obsolete since HAP
   specification R10 — HomeKitADK marks it "Obsolete since R10" and HomeSpan
   omits it entirely. Do not use it for new accessories.
