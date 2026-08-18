# HAP Services

A **service** represents a specific function of an accessory (e.g., a lightbulb,
thermostat, or sensor). Each service contains one or more characteristics that
define its state and capabilities.

---

## 1. Service Structure

Services are identified by a UUID and contain:

- **Instance ID (iid)**: Unique within the accessory
- **Type**: UUID identifying the service type
- **Primary**: Boolean indicating if this is the primary service
- **Hidden**: Boolean indicating if the service is hidden from the UI
- **Linked**: Array of instance IDs for related services
- **Characteristics**: Array of characteristic objects

---

## 2. UUID Format

Service UUIDs use the HAP base UUID:

```
XXXXXXXX-0000-1000-8000-0026BB765291
```

Where `XXXXXXXX` is the 32-bit service type identifier in hexadecimal.

Short form (hex prefix only) may be used in JSON responses.

---

## 3. Mandatory Services

### AccessoryInformation (0x3E)

Required as the first service of every accessory. Provides identification
information.

| UUID | `0000003E-0000-1000-8000-0026BB765291` |
| ---- | -------------------------------------- |

**Required Characteristics:**

- Identify (0x14)
- Manufacturer (0x20)
- Model (0x21)
- Name (0x23)
- SerialNumber (0x30)
- FirmwareRevision (0x52)

**Optional Characteristics:**

- HardwareRevision (0x53)
- SoftwareRevision (0x54)
- AccessoryFlags (0xA6)
- ProductData (0x220)
- HardwareFinish (0x26C)

---

### ProtocolInformation (0xA2)

Required on every accessory. For a bridge, only the bridge accessory object
itself (`aid=1`) carries this service; bridged accessories do not.

| UUID | `000000A2-0000-1000-8000-0026BB765291` |
| ---- | -------------------------------------- |

**Required Characteristics:**

- Version (0x37) — the HAP version; HAP-NodeJS reports `1.1.0`, HAP-python the
  equivalent zero-padded `01.01.00`

---

## 4. Service Catalog

The following table lists the standard HAP services most relevant to this
project, with their UUIDs and required/optional characteristics. Apple defines
further services (remote control, Siri, Wi-Fi router, data stream management,
and others) that are out of scope here.

### Lights, Power, and Switches

| Service                         | UUID | Required                                      | Optional                                                            |
| ------------------------------- | ---- | --------------------------------------------- | ------------------------------------------------------------------- |
| **LightBulb**                   | 0x43 | On                                            | Brightness, Hue, Saturation, ColorTemperature, Name, ConfiguredName |
| **Switch**                      | 0x49 | On                                            | Name, ConfiguredName                                                |
| **Outlet**                      | 0x47 | On, OutletInUse                               | Name, ConfiguredName                                                |
| **BatteryService**              | 0x96 | BatteryLevel, ChargingState, StatusLowBattery | Name, ConfiguredName                                                |
| **StatelessProgrammableSwitch** | 0x89 | ProgrammableSwitchEvent                       | Name, ServiceLabelIndex                                             |

### HVAC (Heating, Ventilation, Air Conditioning)

| Service                    | UUID | Required                                                                                                              | Optional                                                                                                                                                     |
| -------------------------- | ---- | --------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Thermostat**             | 0x4A | CurrentHeatingCoolingState, TargetHeatingCoolingState, CurrentTemperature, TargetTemperature, TemperatureDisplayUnits | CurrentRelativeHumidity, TargetRelativeHumidity, CoolingThresholdTemperature, HeatingThresholdTemperature, Name, ConfiguredName                              |
| **HeaterCooler**           | 0xBC | Active, CurrentHeaterCoolerState, TargetHeaterCoolerState, CurrentTemperature                                         | RotationSpeed, TemperatureDisplayUnits, SwingMode, CoolingThresholdTemperature, HeatingThresholdTemperature, LockPhysicalControls, Name, ConfiguredName      |
| **HumidifierDehumidifier** | 0xBD | Active, CurrentHumidifierDehumidifierState, TargetHumidifierDehumidifierState, CurrentRelativeHumidity                | RelativeHumidityDehumidifierThreshold, RelativeHumidityHumidifierThreshold, RotationSpeed, SwingMode, WaterLevel, LockPhysicalControls, Name, ConfiguredName |
| **Fan** (v2)               | 0xB7 | Active                                                                                                                | CurrentFanState, TargetFanState, RotationDirection, RotationSpeed, SwingMode, LockPhysicalControls, Name, ConfiguredName                                     |
| **Fan** (legacy)           | 0x40 | On                                                                                                                    | RotationDirection, RotationSpeed, Name                                                                                                                       |
| **AirPurifier**            | 0xBB | Active, CurrentAirPurifierState, TargetAirPurifierState                                                               | RotationSpeed, SwingMode, LockPhysicalControls, Name, ConfiguredName                                                                                         |
| **FilterMaintenance**      | 0xBA | FilterChangeIndication                                                                                                | FilterLifeLevel, ResetFilterIndication, Name, ConfiguredName                                                                                                 |
| **Slat**                   | 0xB9 | CurrentSlatState, SlatType                                                                                            | SwingMode, CurrentTiltAngle, TargetTiltAngle, Name, ConfiguredName                                                                                           |

### Sensors

| Service                  | UUID | Required                 | Optional                                                                                                                                                                                                                       |
| ------------------------ | ---- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **TemperatureSensor**    | 0x8A | CurrentTemperature       | StatusActive, StatusFault, StatusLowBattery, StatusTampered, Name, ConfiguredName                                                                                                                                              |
| **HumiditySensor**       | 0x82 | CurrentRelativeHumidity  | StatusActive, StatusFault, StatusTampered, StatusLowBattery, Name, ConfiguredName                                                                                                                                              |
| **LightSensor**          | 0x84 | CurrentAmbientLightLevel | StatusActive, StatusFault, StatusTampered, StatusLowBattery, Name, ConfiguredName                                                                                                                                              |
| **MotionSensor**         | 0x85 | MotionDetected           | StatusActive, StatusFault, StatusTampered, StatusLowBattery, Name, ConfiguredName                                                                                                                                              |
| **ContactSensor**        | 0x80 | ContactSensorState       | StatusActive, StatusFault, StatusTampered, StatusLowBattery, Name, ConfiguredName                                                                                                                                              |
| **OccupancySensor**      | 0x86 | OccupancyDetected        | StatusActive, StatusFault, StatusTampered, StatusLowBattery, Name, ConfiguredName                                                                                                                                              |
| **LeakSensor**           | 0x83 | LeakDetected             | StatusActive, StatusFault, StatusTampered, StatusLowBattery, Name, ConfiguredName                                                                                                                                              |
| **SmokeSensor**          | 0x87 | SmokeDetected            | StatusActive, StatusFault, StatusTampered, StatusLowBattery, Name, ConfiguredName                                                                                                                                              |
| **CarbonMonoxideSensor** | 0x7F | CarbonMonoxideDetected   | StatusActive, StatusFault, StatusLowBattery, StatusTampered, CarbonMonoxideLevel, CarbonMonoxidePeakLevel, Name, ConfiguredName                                                                                                |
| **CarbonDioxideSensor**  | 0x97 | CarbonDioxideDetected    | StatusActive, StatusFault, StatusLowBattery, StatusTampered, CarbonDioxideLevel, CarbonDioxidePeakLevel, Name, ConfiguredName                                                                                                  |
| **AirQualitySensor**     | 0x8D | AirQuality               | StatusActive, StatusFault, StatusTampered, StatusLowBattery, OzoneDensity, NitrogenDioxideDensity, SulphurDioxideDensity, PM2.5Density, PM10Density, VOCDensity, CarbonMonoxideLevel, CarbonDioxideLevel, Name, ConfiguredName |

### Doors, Locks, and Windows

| Service              | UUID  | Required                                               | Optional                                                                                                                                                          |
| -------------------- | ----- | ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Door**             | 0x81  | CurrentPosition, TargetPosition, PositionState         | HoldPosition, ObstructionDetected, Name, ConfiguredName                                                                                                           |
| **Window**           | 0x8B  | CurrentPosition, TargetPosition, PositionState         | HoldPosition, ObstructionDetected, Name, ConfiguredName                                                                                                           |
| **WindowCovering**   | 0x8C  | CurrentPosition, TargetPosition, PositionState         | HoldPosition, CurrentHorizontalTiltAngle, TargetHorizontalTiltAngle, CurrentVerticalTiltAngle, TargetVerticalTiltAngle, ObstructionDetected, Name, ConfiguredName |
| **LockMechanism**    | 0x45  | LockCurrentState, LockTargetState                      | Name, ConfiguredName                                                                                                                                              |
| **LockManagement**   | 0x44  | LockControlPoint, Version                              | Logs, AudioFeedback, LockManagementAutoSecurityTimeout, AdministratorOnlyAccess, LockLastKnownAction, CurrentDoorState, MotionDetected, Name                      |
| **GarageDoorOpener** | 0x41  | CurrentDoorState, TargetDoorState, ObstructionDetected | LockCurrentState, LockTargetState, Name, ConfiguredName                                                                                                           |
| **Doorbell**         | 0x121 | ProgrammableSwitchEvent                                | Brightness, Volume, Name, ConfiguredName                                                                                                                          |

### Water Systems

| Service              | UUID | Required                   | Optional                                                                                           |
| -------------------- | ---- | -------------------------- | -------------------------------------------------------------------------------------------------- |
| **Faucet**           | 0xD7 | Active                     | Name, StatusFault, ConfiguredName                                                                  |
| **Valve**            | 0xD0 | Active, InUse, ValveType   | SetDuration, RemainingDuration, IsConfigured, ServiceLabelIndex, StatusFault, Name, ConfiguredName |
| **IrrigationSystem** | 0xCF | Active, ProgramMode, InUse | RemainingDuration, StatusFault, Name, ConfiguredName                                               |

### Security

| Service            | UUID | Required                                              | Optional                                                                   |
| ------------------ | ---- | ----------------------------------------------------- | -------------------------------------------------------------------------- |
| **SecuritySystem** | 0x7E | SecuritySystemCurrentState, SecuritySystemTargetState | StatusFault, StatusTampered, SecuritySystemAlarmType, Name, ConfiguredName |

### Television and Media

| Service               | UUID  | Required                                                              | Optional                                                                                                                  |
| --------------------- | ----- | --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| **Television**        | 0xD8  | Active, ActiveIdentifier, ConfiguredName, SleepDiscoveryMode          | Brightness, ClosedCaptions, DisplayOrder, CurrentMediaState, TargetMediaState, PictureMode, PowerModeSelection, RemoteKey |
| **InputSource**       | 0xD9  | ConfiguredName, InputSourceType, IsConfigured, CurrentVisibilityState | Identifier, InputDeviceType, TargetVisibilityState, Name                                                                  |
| **TelevisionSpeaker** | 0x113 | Mute                                                                  | Active, Volume, VolumeControlType, VolumeSelector, Name, ConfiguredName                                                   |

### Audio

| Service        | UUID  | Required     | Optional     |
| -------------- | ----- | ------------ | ------------ |
| **Speaker**    | 0x113 | Mute         | Name, Volume |
| **Microphone** | 0x112 | Volume, Mute | Name         |

### Camera and Video

| Service                       | UUID  | Required                                                                                                                                                         | Optional |
| ----------------------------- | ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| **CameraRTPStreamManagement** | 0x110 | SupportedVideoStreamConfiguration, SupportedAudioStreamConfiguration, SupportedRTPConfiguration, SelectedRTPStreamConfiguration, StreamingStatus, SetupEndpoints | Name     |

### Miscellaneous

| Service          | UUID  | Required                                                                   | Optional |
| ---------------- | ----- | -------------------------------------------------------------------------- | -------- |
| **ServiceLabel** | 0xCC  | ServiceLabelNamespace                                                      | Name     |
| **NFCAccess**    | 0x266 | ConfigurationState, NFCAccessControlPoint, NFCAccessSupportedConfiguration |          |

---

## 5. Service Relationships

### Primary Service

Each accessory should have exactly one service marked as primary. This service:

- Represents the main function of the accessory
- Is displayed prominently in the Home app
- Is used for Siri voice commands

### Linked Services

Services can be linked to establish relationships:

```json
{
  "iid": 10,
  "type": "D8",
  "linked": [11, 12],
  "characteristics": [...]
}
```

Common linking patterns:

- **Television** → **InputSource** (for input selection)
- **Television** → **TelevisionSpeaker** (for volume control)
- **IrrigationSystem** → **Valve** (for zone control)
- **Faucet** → **Valve** (for tap control)
- **AirPurifier** → **FilterMaintenance** (for filter status)
- **StatelessProgrammableSwitch** → **ServiceLabel** (for button numbering)

---

## 6. Complete Service UUID Table

| Service                     | Short UUID | Full UUID                            |
| --------------------------- | ---------- | ------------------------------------ |
| AccessoryInformation        | 3E         | 0000003E-0000-1000-8000-0026BB765291 |
| AirPurifier                 | BB         | 000000BB-0000-1000-8000-0026BB765291 |
| AirQualitySensor            | 8D         | 0000008D-0000-1000-8000-0026BB765291 |
| BatteryService              | 96         | 00000096-0000-1000-8000-0026BB765291 |
| CameraRTPStreamManagement   | 110        | 00000110-0000-1000-8000-0026BB765291 |
| CarbonDioxideSensor         | 97         | 00000097-0000-1000-8000-0026BB765291 |
| CarbonMonoxideSensor        | 7F         | 0000007F-0000-1000-8000-0026BB765291 |
| ContactSensor               | 80         | 00000080-0000-1000-8000-0026BB765291 |
| Door                        | 81         | 00000081-0000-1000-8000-0026BB765291 |
| Doorbell                    | 121        | 00000121-0000-1000-8000-0026BB765291 |
| Fan                         | 40         | 00000040-0000-1000-8000-0026BB765291 |
| Fanv2                       | B7         | 000000B7-0000-1000-8000-0026BB765291 |
| Faucet                      | D7         | 000000D7-0000-1000-8000-0026BB765291 |
| FilterMaintenance           | BA         | 000000BA-0000-1000-8000-0026BB765291 |
| GarageDoorOpener            | 41         | 00000041-0000-1000-8000-0026BB765291 |
| HeaterCooler                | BC         | 000000BC-0000-1000-8000-0026BB765291 |
| HumidifierDehumidifier      | BD         | 000000BD-0000-1000-8000-0026BB765291 |
| HumiditySensor              | 82         | 00000082-0000-1000-8000-0026BB765291 |
| InputSource                 | D9         | 000000D9-0000-1000-8000-0026BB765291 |
| IrrigationSystem            | CF         | 000000CF-0000-1000-8000-0026BB765291 |
| LeakSensor                  | 83         | 00000083-0000-1000-8000-0026BB765291 |
| LightBulb                   | 43         | 00000043-0000-1000-8000-0026BB765291 |
| LightSensor                 | 84         | 00000084-0000-1000-8000-0026BB765291 |
| LockManagement              | 44         | 00000044-0000-1000-8000-0026BB765291 |
| LockMechanism               | 45         | 00000045-0000-1000-8000-0026BB765291 |
| Microphone                  | 112        | 00000112-0000-1000-8000-0026BB765291 |
| MotionSensor                | 85         | 00000085-0000-1000-8000-0026BB765291 |
| NFCAccess                   | 266        | 00000266-0000-1000-8000-0026BB765291 |
| OccupancySensor             | 86         | 00000086-0000-1000-8000-0026BB765291 |
| Outlet                      | 47         | 00000047-0000-1000-8000-0026BB765291 |
| ProtocolInformation         | A2         | 000000A2-0000-1000-8000-0026BB765291 |
| SecuritySystem              | 7E         | 0000007E-0000-1000-8000-0026BB765291 |
| ServiceLabel                | CC         | 000000CC-0000-1000-8000-0026BB765291 |
| Slat                        | B9         | 000000B9-0000-1000-8000-0026BB765291 |
| SmokeSensor                 | 87         | 00000087-0000-1000-8000-0026BB765291 |
| Speaker                     | 113        | 00000113-0000-1000-8000-0026BB765291 |
| StatelessProgrammableSwitch | 89         | 00000089-0000-1000-8000-0026BB765291 |
| Switch                      | 49         | 00000049-0000-1000-8000-0026BB765291 |
| Television                  | D8         | 000000D8-0000-1000-8000-0026BB765291 |
| TelevisionSpeaker           | 113        | 00000113-0000-1000-8000-0026BB765291 |
| TemperatureSensor           | 8A         | 0000008A-0000-1000-8000-0026BB765291 |
| Thermostat                  | 4A         | 0000004A-0000-1000-8000-0026BB765291 |
| Valve                       | D0         | 000000D0-0000-1000-8000-0026BB765291 |
| Window                      | 8B         | 0000008B-0000-1000-8000-0026BB765291 |
| WindowCovering              | 8C         | 0000008C-0000-1000-8000-0026BB765291 |

---

## 7. JSON Representation

Example service in accessory database:

```json
{
  "iid": 8,
  "type": "43",
  "characteristics": [
    {
      "iid": 9,
      "type": "25",
      "perms": ["pr", "pw", "ev"],
      "format": "bool",
      "value": false
    },
    {
      "iid": 10,
      "type": "8",
      "perms": ["pr", "pw", "ev"],
      "format": "int",
      "value": 100,
      "minValue": 0,
      "maxValue": 100,
      "minStep": 1,
      "unit": "percentage"
    }
  ],
  "primary": true
}
```

---

## 8. Notes

1. **AccessoryInformation is required**: Every accessory must have exactly one
   AccessoryInformation service as its first service.

2. **Instance IDs**: Each service and characteristic must have a unique iid
   within the accessory. IDs are stable across reboots.

3. **Service types are case-insensitive**: The Home app accepts both uppercase
   and lowercase hex digits in type strings.

4. **Custom services**: Vendors may define custom services using their own UUIDs
   outside the Apple base range.

5. **Deprecated services**: The legacy Fan service (0x40) is deprecated in favor
   of Fanv2 (0xB7).
