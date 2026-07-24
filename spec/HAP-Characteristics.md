# HAP Characteristics

A **characteristic** is an individual data point within a service. Each
characteristic has a type, format, permissions, and value.

---

## 1. Characteristic Structure

Each characteristic has the following properties:

| Property             | Required    | Description                           |
| -------------------- | ----------- | ------------------------------------- |
| `iid`                | Yes         | Instance ID, unique within accessory  |
| `type`               | Yes         | UUID (short or full form)             |
| `format`             | Yes         | Data type of the value                |
| `perms`              | Yes         | Array of permission strings           |
| `value`              | Conditional | Current value (if readable)           |
| `minValue`           | No          | Minimum allowed value                 |
| `maxValue`           | No          | Maximum allowed value                 |
| `minStep`            | No          | Minimum step increment                |
| `unit`               | No          | Unit of measurement                   |
| `description`        | No          | Human-readable description            |
| `maxLen`             | No          | Maximum string length (default 64)    |
| `maxDataLen`         | No          | Maximum data length for `data` format |
| `valid-values`       | No          | Array of valid values for enums       |
| `valid-values-range` | No          | Array of [min, max] for valid range   |

---

## 2. Data Formats

| Format   | Description                       | JSON Type |
| -------- | --------------------------------- | --------- |
| `bool`   | Boolean, true or false            | boolean   |
| `uint8`  | Unsigned 8-bit integer (0–255)    | number    |
| `uint16` | Unsigned 16-bit integer (0–65535) | number    |
| `uint32` | Unsigned 32-bit integer           | number    |
| `uint64` | Unsigned 64-bit integer           | number    |
| `int`    | Signed 32-bit integer             | number    |
| `float`  | IEEE 754 floating point           | number    |
| `string` | UTF-8 string                      | string    |
| `tlv8`   | Base64-encoded TLV8 data          | string    |
| `data`   | Base64-encoded binary data        | string    |

---

## 3. Permissions

| Permission | Description                                   |
| ---------- | --------------------------------------------- |
| `pr`       | Paired Read — value can be read               |
| `pw`       | Paired Write — value can be written           |
| `ev`       | Events — value changes sent as notifications  |
| `aa`       | Additional Authorization required             |
| `tw`       | Timed Write required                          |
| `hd`       | Hidden — not shown in Home app                |
| `wr`       | Write Response — value returned in reply body |

---

## 4. Units

| Unit         | Description            |
| ------------ | ---------------------- |
| `celsius`    | Temperature in Celsius |
| `percentage` | Percentage (0-100)     |
| `arcdegrees` | Angle in degrees       |
| `lux`        | Light level in lux     |
| `seconds`    | Duration in seconds    |

---

## 5. Complete Characteristic Catalog

### Identification

| Characteristic       | UUID  | Format | Permissions | Range/Values                     |
| -------------------- | ----- | ------ | ----------- | -------------------------------- |
| **Identify**         | 0x14  | bool   | pw          | -                                |
| **Manufacturer**     | 0x20  | string | pr          | -                                |
| **Model**            | 0x21  | string | pr          | -                                |
| **Name**             | 0x23  | string | pr          | -                                |
| **SerialNumber**     | 0x30  | string | pr          | max 64 chars                     |
| **FirmwareRevision** | 0x52  | string | pr          | x.y.z format                     |
| **HardwareRevision** | 0x53  | string | pr          | x.y.z format                     |
| **AccessoryFlags**   | 0xA6  | uint32 | pr, ev      | bit 0: requires additional setup |
| **ConfiguredName**   | 0xE3  | string | pr, pw, ev  | -                                |
| **ProductData**      | 0x220 | data   | pr          | -                                |

### On/Off and Active

| Characteristic   | UUID | Format | Permissions | Values                        |
| ---------------- | ---- | ------ | ----------- | ----------------------------- |
| **On**           | 0x25 | bool   | pr, pw, ev  | false=Off, true=On            |
| **Active**       | 0xB0 | uint8  | pr, pw, ev  | 0=Inactive, 1=Active          |
| **InUse**        | 0xD2 | uint8  | pr, ev      | 0=NotInUse, 1=InUse           |
| **IsConfigured** | 0xD6 | uint8  | pr, pw, ev  | 0=NotConfigured, 1=Configured |
| **OutletInUse**  | 0x26 | bool   | pr, ev      | -                             |

### Brightness and Color

| Characteristic       | UUID | Format | Permissions | Range   | Unit       |
| -------------------- | ---- | ------ | ----------- | ------- | ---------- |
| **Brightness**       | 0x08 | int    | pr, pw, ev  | 0–100   | percentage |
| **Hue**              | 0x13 | float  | pr, pw, ev  | 0–360   | arcdegrees |
| **Saturation**       | 0x2F | float  | pr, pw, ev  | 0–100   | percentage |
| **ColorTemperature** | 0xCE | uint32 | pr, pw, ev  | 140–500 | -          |

ColorTemperature values are expressed in mireds (reciprocal megakelvins), but
`mired` is not a defined HAP unit (see section 4); the `unit` field is omitted
for this characteristic.

### Temperature

| Characteristic                  | UUID | Format | Permissions | Range                   | Unit    |
| ------------------------------- | ---- | ------ | ----------- | ----------------------- | ------- |
| **CurrentTemperature**          | 0x11 | float  | pr, ev      | -273.1–1000             | celsius |
| **TargetTemperature**           | 0x35 | float  | pr, pw, ev  | 10–38                   | celsius |
| **CoolingThresholdTemperature** | 0x0D | float  | pr, pw, ev  | 10–35                   | celsius |
| **HeatingThresholdTemperature** | 0x12 | float  | pr, pw, ev  | 0–25                    | celsius |
| **TemperatureDisplayUnits**     | 0x36 | uint8  | pr, pw, ev  | 0=Celsius, 1=Fahrenheit |

### Heating/Cooling State

| Characteristic                 | UUID | Format | Permissions | Values                                   |
| ------------------------------ | ---- | ------ | ----------- | ---------------------------------------- |
| **CurrentHeatingCoolingState** | 0x0F | uint8  | pr, ev      | 0=Off, 1=Heat, 2=Cool                    |
| **TargetHeatingCoolingState**  | 0x33 | uint8  | pr, pw, ev  | 0=Off, 1=Heat, 2=Cool, 3=Auto            |
| **CurrentHeaterCoolerState**   | 0xB1 | uint8  | pr, ev      | 0=Inactive, 1=Idle, 2=Heating, 3=Cooling |
| **TargetHeaterCoolerState**    | 0xB2 | uint8  | pr, pw, ev  | 0=Auto, 1=Heat, 2=Cool                   |

### Humidity

| Characteristic                            | UUID | Format | Permissions | Range                                              | Unit       |
| ----------------------------------------- | ---- | ------ | ----------- | -------------------------------------------------- | ---------- |
| **CurrentRelativeHumidity**               | 0x10 | float  | pr, ev      | 0–100                                              | percentage |
| **TargetRelativeHumidity**                | 0x34 | float  | pr, pw, ev  | 0–100                                              | percentage |
| **RelativeHumidityDehumidifierThreshold** | 0xC9 | float  | pr, pw, ev  | 0–100                                              | percentage |
| **RelativeHumidityHumidifierThreshold**   | 0xCA | float  | pr, pw, ev  | 0–100                                              | percentage |
| **CurrentHumidifierDehumidifierState**    | 0xB3 | uint8  | pr, ev      | 0=Inactive, 1=Idle, 2=Humidifying, 3=Dehumidifying |
| **TargetHumidifierDehumidifierState**     | 0xB4 | uint8  | pr, pw, ev  | 0=Auto, 1=Humidify, 2=Dehumidify                   |

### Fan

| Characteristic           | UUID | Format | Permissions | Range/Values                     |
| ------------------------ | ---- | ------ | ----------- | -------------------------------- |
| **RotationDirection**    | 0x28 | int    | pr, pw, ev  | 0=Clockwise, 1=Counter-clockwise |
| **RotationSpeed**        | 0x29 | float  | pr, pw, ev  | 0–100 percentage                 |
| **CurrentFanState**      | 0xAF | uint8  | pr, ev      | 0=Inactive, 1=Idle, 2=Blowing    |
| **TargetFanState**       | 0xBF | uint8  | pr, pw, ev  | 0=Manual, 1=Auto                 |
| **SwingMode**            | 0xB6 | uint8  | pr, pw, ev  | 0=Disabled, 1=Enabled            |
| **LockPhysicalControls** | 0xA7 | uint8  | pr, pw, ev  | 0=Disabled, 1=Enabled            |

### Air Quality

| Characteristic             | UUID | Format | Permissions | Range                                                      |
| -------------------------- | ---- | ------ | ----------- | ---------------------------------------------------------- |
| **AirQuality**             | 0x95 | uint8  | pr, ev      | 0=Unknown, 1=Excellent, 2=Good, 3=Fair, 4=Inferior, 5=Poor |
| **OzoneDensity**           | 0xC3 | float  | pr, ev      | 0–1000 μg/m³                                               |
| **NitrogenDioxideDensity** | 0xC4 | float  | pr, ev      | 0–1000 μg/m³                                               |
| **SulphurDioxideDensity**  | 0xC5 | float  | pr, ev      | 0–1000 μg/m³                                               |
| **PM2.5Density**           | 0xC6 | float  | pr, ev      | 0–1000 μg/m³                                               |
| **PM10Density**            | 0xC7 | float  | pr, ev      | 0–1000 μg/m³                                               |
| **VOCDensity**             | 0xC8 | float  | pr, ev      | 0–1000 μg/m³                                               |
| **AirParticulateDensity**  | 0x64 | float  | pr, ev      | 0–1000 μg/m³                                               |
| **AirParticulateSize**     | 0x65 | uint8  | pr, ev      | 0=2.5μm, 1=10μm                                            |

### Air Purifier

| Characteristic              | UUID | Format | Permissions | Values                          |
| --------------------------- | ---- | ------ | ----------- | ------------------------------- |
| **CurrentAirPurifierState** | 0xA9 | uint8  | pr, ev      | 0=Inactive, 1=Idle, 2=Purifying |
| **TargetAirPurifierState**  | 0xA8 | uint8  | pr, pw, ev  | 0=Manual, 1=Auto                |
| **FilterChangeIndication**  | 0xAC | uint8  | pr, ev      | 0=OK, 1=ChangeNeeded            |
| **FilterLifeLevel**         | 0xAB | float  | pr, ev      | 0–100 percentage                |
| **ResetFilterIndication**   | 0xAD | uint8  | pw          | 1=Reset                         |

### Carbon Dioxide

| Characteristic             | UUID | Format | Permissions | Range/Values         |
| -------------------------- | ---- | ------ | ----------- | -------------------- |
| **CarbonDioxideDetected**  | 0x92 | uint8  | pr, ev      | 0=Normal, 1=Abnormal |
| **CarbonDioxideLevel**     | 0x93 | float  | pr, ev      | 0–100000 ppm         |
| **CarbonDioxidePeakLevel** | 0x94 | float  | pr, ev      | 0–100000 ppm         |

### Carbon Monoxide

| Characteristic              | UUID | Format | Permissions | Range/Values         |
| --------------------------- | ---- | ------ | ----------- | -------------------- |
| **CarbonMonoxideDetected**  | 0x69 | uint8  | pr, ev      | 0=Normal, 1=Abnormal |
| **CarbonMonoxideLevel**     | 0x90 | float  | pr, ev      | 0–100 ppm            |
| **CarbonMonoxidePeakLevel** | 0x91 | float  | pr, ev      | 0–100 ppm            |

### Sensors

| Characteristic               | UUID | Format | Permissions | Values                                                  |
| ---------------------------- | ---- | ------ | ----------- | ------------------------------------------------------- |
| **ContactSensorState**       | 0x6A | uint8  | pr, ev      | 0=ContactDetected (closed), 1=ContactNotDetected (open) |
| **LeakDetected**             | 0x70 | uint8  | pr, ev      | 0=NotDetected, 1=Detected                               |
| **MotionDetected**           | 0x22 | bool   | pr, ev      | -                                                       |
| **OccupancyDetected**        | 0x71 | uint8  | pr, ev      | 0=NotDetected, 1=Detected                               |
| **SmokeDetected**            | 0x76 | uint8  | pr, ev      | 0=NotDetected, 1=Detected                               |
| **CurrentAmbientLightLevel** | 0x6B | float  | pr, ev      | 0.0001–100000 lux                                       |

### Status

| Characteristic          | UUID | Format | Permissions | Values                    |
| ----------------------- | ---- | ------ | ----------- | ------------------------- |
| **StatusActive**        | 0x75 | bool   | pr, ev      | -                         |
| **StatusFault**         | 0x77 | uint8  | pr, ev      | 0=NoFault, 1=GeneralFault |
| **StatusJammed**        | 0x78 | uint8  | pr, ev      | 0=NotJammed, 1=Jammed     |
| **StatusLowBattery**    | 0x79 | uint8  | pr, ev      | 0=Normal, 1=Low           |
| **StatusTampered**      | 0x7A | uint8  | pr, ev      | 0=NotTampered, 1=Tampered |
| **ObstructionDetected** | 0x24 | bool   | pr, ev      | -                         |

### Battery

| Characteristic    | UUID | Format | Permissions | Range/Values                               |
| ----------------- | ---- | ------ | ----------- | ------------------------------------------ |
| **BatteryLevel**  | 0x68 | uint8  | pr, ev      | 0–100 percentage                           |
| **ChargingState** | 0x8F | uint8  | pr, ev      | 0=NotCharging, 1=Charging, 2=NotChargeable |

### Position (Doors, Windows, Blinds)

| Characteristic      | UUID | Format | Permissions | Range/Values                          |
| ------------------- | ---- | ------ | ----------- | ------------------------------------- |
| **CurrentPosition** | 0x6D | uint8  | pr, ev      | 0–100 percentage                      |
| **TargetPosition**  | 0x7C | uint8  | pr, pw, ev  | 0–100 percentage                      |
| **PositionState**   | 0x72 | uint8  | pr, ev      | 0=Decreasing, 1=Increasing, 2=Stopped |
| **HoldPosition**    | 0x6F | bool   | pw          | -                                     |

### Tilt Angle

| Characteristic                 | UUID | Format | Permissions | Range  | Unit       |
| ------------------------------ | ---- | ------ | ----------- | ------ | ---------- |
| **CurrentHorizontalTiltAngle** | 0x6C | int    | pr, ev      | -90–90 | arcdegrees |
| **TargetHorizontalTiltAngle**  | 0x7B | int    | pr, pw, ev  | -90–90 | arcdegrees |
| **CurrentVerticalTiltAngle**   | 0x6E | int    | pr, ev      | -90–90 | arcdegrees |
| **TargetVerticalTiltAngle**    | 0x7D | int    | pr, pw, ev  | -90–90 | arcdegrees |
| **CurrentTiltAngle**           | 0xC1 | int    | pr, ev      | -90–90 | arcdegrees |
| **TargetTiltAngle**            | 0xC2 | int    | pr, pw, ev  | -90–90 | arcdegrees |

### Slat

| Characteristic       | UUID | Format | Permissions | Values                        |
| -------------------- | ---- | ------ | ----------- | ----------------------------- |
| **SlatType**         | 0xC0 | uint8  | pr          | 0=Horizontal, 1=Vertical      |
| **CurrentSlatState** | 0xAA | uint8  | pr, ev      | 0=Fixed, 1=Jammed, 2=Swinging |

### Doors and Locks

| Characteristic                        | UUID | Format | Permissions | Values                                                                                                                                                                          |
| ------------------------------------- | ---- | ------ | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **CurrentDoorState**                  | 0x0E | uint8  | pr, ev      | 0=Open, 1=Closed, 2=Opening, 3=Closing, 4=Stopped                                                                                                                               |
| **TargetDoorState**                   | 0x32 | uint8  | pr, pw, ev  | 0=Open, 1=Closed                                                                                                                                                                |
| **LockCurrentState**                  | 0x1D | uint8  | pr, ev      | 0=Unsecured, 1=Secured, 2=Jammed, 3=Unknown                                                                                                                                     |
| **LockTargetState**                   | 0x1E | uint8  | pr, pw, ev  | 0=Unsecured, 1=Secured                                                                                                                                                          |
| **LockControlPoint**                  | 0x19 | tlv8   | pw          | -                                                                                                                                                                               |
| **LockLastKnownAction**               | 0x1C | uint8  | pr, ev      | 0=SecuredInterior, 1=UnsecuredInterior, 2=SecuredExterior, 3=UnsecuredExterior, 4=SecuredKeypad, 5=UnsecuredKeypad, 6=SecuredRemotely, 7=UnsecuredRemotely, 8=AutoSecureTimeout |
| **LockManagementAutoSecurityTimeout** | 0x1A | uint32 | pr, pw, ev  | seconds                                                                                                                                                                         |

### Security System

| Characteristic                 | UUID | Format | Permissions | Values                                                         |
| ------------------------------ | ---- | ------ | ----------- | -------------------------------------------------------------- |
| **SecuritySystemCurrentState** | 0x66 | uint8  | pr, ev      | 0=StayArm, 1=AwayArm, 2=NightArm, 3=Disarmed, 4=AlarmTriggered |
| **SecuritySystemTargetState**  | 0x67 | uint8  | pr, pw, ev  | 0=StayArm, 1=AwayArm, 2=NightArm, 3=Disarm                     |
| **SecuritySystemAlarmType**    | 0x8E | uint8  | pr, ev      | 0=Known, 1=Unknown                                             |

### Programmable Switch

| Characteristic              | UUID | Format | Permissions | Values                                    |
| --------------------------- | ---- | ------ | ----------- | ----------------------------------------- |
| **ProgrammableSwitchEvent** | 0x73 | uint8  | pr, ev      | 0=SinglePress, 1=DoublePress, 2=LongPress |
| **ServiceLabelIndex**       | 0xCB | uint8  | pr          | 1–255                                     |
| **ServiceLabelNamespace**   | 0xCD | uint8  | pr          | 0=Dots, 1=ArabicNumerals                  |

### Valve and Irrigation

| Characteristic        | UUID | Format | Permissions | Range/Values                                    |
| --------------------- | ---- | ------ | ----------- | ----------------------------------------------- |
| **ValveType**         | 0xD5 | uint8  | pr, ev      | 0=Generic, 1=Irrigation, 2=ShowerHead, 3=Faucet |
| **SetDuration**       | 0xD3 | uint32 | pr, pw, ev  | 0–3600 seconds                                  |
| **RemainingDuration** | 0xD4 | uint32 | pr, ev      | 0–3600 seconds                                  |
| **ProgramMode**       | 0xD1 | uint8  | pr, ev      | 0=None, 1=Scheduled, 2=ScheduleOverriden        |

### Television

| Characteristic             | UUID  | Format | Permissions | Values                                                                                                                                 |
| -------------------------- | ----- | ------ | ----------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| **ActiveIdentifier**       | 0xE7  | uint32 | pr, pw, ev  | -                                                                                                                                      |
| **Identifier**             | 0xE6  | uint32 | pr          | -                                                                                                                                      |
| **InputSourceType**        | 0xDB  | uint8  | pr, ev      | 0=Other, 1=HomeScreen, 2=Tuner, 3=HDMI, 4=CompositeVideo, 5=SVideo, 6=ComponentVideo, 7=DVI, 8=AirPlay, 9=USB, 10=Application          |
| **InputDeviceType**        | 0xDC  | uint8  | pr, ev      | 0=Other, 1=TV, 2=Recording, 3=Tuner, 4=Playback, 5=AudioSystem                                                                         |
| **SleepDiscoveryMode**     | 0xE8  | uint8  | pr, ev      | 0=NotDiscoverable, 1=AlwaysDiscoverable                                                                                                |
| **CurrentVisibilityState** | 0x135 | uint8  | pr, ev      | 0=Shown, 1=Hidden                                                                                                                      |
| **TargetVisibilityState**  | 0x134 | uint8  | pr, pw, ev  | 0=Shown, 1=Hidden                                                                                                                      |
| **ClosedCaptions**         | 0xDD  | uint8  | pr, pw, ev  | 0=Disabled, 1=Enabled                                                                                                                  |
| **DisplayOrder**           | 0x136 | tlv8   | pr, pw, ev  | -                                                                                                                                      |
| **CurrentMediaState**      | 0xE0  | uint8  | pr, ev      | 0=Play, 1=Pause, 2=Stop, 3=Unknown                                                                                                     |
| **TargetMediaState**       | 0x137 | uint8  | pr, pw, ev  | 0=Play, 1=Pause, 2=Stop                                                                                                                |
| **PictureMode**            | 0xE2  | uint8  | pr, pw, ev  | 0=Other, 1=Standard, 2=Calibrated, ...                                                                                                 |
| **PowerModeSelection**     | 0xDF  | uint8  | pw          | 0=Show, 1=Hide                                                                                                                         |
| **RemoteKey**              | 0xE1  | uint8  | pw          | 0=Rewind, 1=FastForward, 2=NextTrack, 3=PreviousTrack, 4=Up, 5=Down, 6=Left, 7=Right, 8=Select, 9=Back, 10=Exit, 11=PlayPause, 15=Info |

### Audio

| Characteristic        | UUID  | Format | Permissions | Range/Values                                          |
| --------------------- | ----- | ------ | ----------- | ----------------------------------------------------- |
| **Volume**            | 0x119 | uint8  | pr, pw, ev  | 0–100 percentage                                      |
| **Mute**              | 0x11A | bool   | pr, pw, ev  | -                                                     |
| **VolumeControlType** | 0xE9  | uint8  | pr, ev      | 0=None, 1=Relative, 2=RelativeWithCurrent, 3=Absolute |
| **VolumeSelector**    | 0xEA  | uint8  | pw          | 0=Increment, 1=Decrement                              |
| **AudioFeedback**     | 0x05  | bool   | pr, pw, ev  | -                                                     |

### Camera

| Characteristic                        | UUID  | Format | Permissions |
| ------------------------------------- | ----- | ------ | ----------- |
| **SupportedVideoStreamConfiguration** | 0x114 | tlv8   | pr          |
| **SupportedAudioStreamConfiguration** | 0x115 | tlv8   | pr          |
| **SupportedRTPConfiguration**         | 0x116 | tlv8   | pr          |
| **SelectedRTPStreamConfiguration**    | 0x117 | tlv8   | pr, pw      |
| **SetupEndpoints**                    | 0x118 | tlv8   | pr, pw      |
| **StreamingStatus**                   | 0x120 | tlv8   | pr, ev      |
| **DigitalZoom**                       | 0x11D | float  | pr, pw, ev  |
| **OpticalZoom**                       | 0x11C | float  | pr, pw, ev  |
| **ImageMirroring**                    | 0x11F | bool   | pr, pw, ev  |
| **ImageRotation**                     | 0x11E | float  | pr, pw, ev  |
| **NightVision**                       | 0x11B | bool   | pr, pw, ev  |

### Water Level

| Characteristic | UUID | Format | Permissions | Range | Unit       |
| -------------- | ---- | ------ | ----------- | ----- | ---------- |
| **WaterLevel** | 0xB5 | float  | pr, ev      | 0–100 | percentage |

### Pairing (Internal)

| Characteristic      | UUID | Format | Permissions |
| ------------------- | ---- | ------ | ----------- |
| **PairSetup**       | 0x4C | tlv8   | pr, pw      |
| **PairVerify**      | 0x4E | tlv8   | pr, pw      |
| **PairingFeatures** | 0x4F | uint8  | pr          |
| **PairingPairings** | 0x50 | tlv8   | pr, pw      |

### Miscellaneous

| Characteristic                       | UUID  | Format | Permissions |
| ------------------------------------ | ----- | ------ | ----------- |
| **Version**                          | 0x37  | string | pr, ev      |
| **Logs**                             | 0x1F  | tlv8   | pr, ev      |
| **AdministratorOnlyAccess**          | 0x01  | bool   | pr, pw, ev  |
| **HardwareFinish**                   | 0x26C | tlv8   | pr          |
| **ActiveTransitionCount**            | 0x24B | uint8  | pr, ev      |
| **TransitionControl**                | 0x143 | tlv8   | pr, pw, wr  |
| **SupportedTransitionConfiguration** | 0x144 | tlv8   | pr          |
| **ConfigurationState**               | 0x263 | uint16 | pr, ev      |
| **NFCAccessControlPoint**            | 0x264 | tlv8   | pr, pw, wr  |
| **NFCAccessSupportedConfiguration**  | 0x265 | tlv8   | pr          |

---

## 6. UUID Table

| Characteristic                        | Short | Full UUID                            |
| ------------------------------------- | ----- | ------------------------------------ |
| AdministratorOnlyAccess               | 01    | 00000001-0000-1000-8000-0026BB765291 |
| AudioFeedback                         | 05    | 00000005-0000-1000-8000-0026BB765291 |
| Brightness                            | 08    | 00000008-0000-1000-8000-0026BB765291 |
| CoolingThresholdTemperature           | 0D    | 0000000D-0000-1000-8000-0026BB765291 |
| CurrentDoorState                      | 0E    | 0000000E-0000-1000-8000-0026BB765291 |
| CurrentHeatingCoolingState            | 0F    | 0000000F-0000-1000-8000-0026BB765291 |
| CurrentRelativeHumidity               | 10    | 00000010-0000-1000-8000-0026BB765291 |
| CurrentTemperature                    | 11    | 00000011-0000-1000-8000-0026BB765291 |
| HeatingThresholdTemperature           | 12    | 00000012-0000-1000-8000-0026BB765291 |
| Hue                                   | 13    | 00000013-0000-1000-8000-0026BB765291 |
| Identify                              | 14    | 00000014-0000-1000-8000-0026BB765291 |
| LockControlPoint                      | 19    | 00000019-0000-1000-8000-0026BB765291 |
| LockManagementAutoSecurityTimeout     | 1A    | 0000001A-0000-1000-8000-0026BB765291 |
| LockLastKnownAction                   | 1C    | 0000001C-0000-1000-8000-0026BB765291 |
| LockCurrentState                      | 1D    | 0000001D-0000-1000-8000-0026BB765291 |
| LockTargetState                       | 1E    | 0000001E-0000-1000-8000-0026BB765291 |
| Logs                                  | 1F    | 0000001F-0000-1000-8000-0026BB765291 |
| Manufacturer                          | 20    | 00000020-0000-1000-8000-0026BB765291 |
| Model                                 | 21    | 00000021-0000-1000-8000-0026BB765291 |
| MotionDetected                        | 22    | 00000022-0000-1000-8000-0026BB765291 |
| Name                                  | 23    | 00000023-0000-1000-8000-0026BB765291 |
| ObstructionDetected                   | 24    | 00000024-0000-1000-8000-0026BB765291 |
| On                                    | 25    | 00000025-0000-1000-8000-0026BB765291 |
| OutletInUse                           | 26    | 00000026-0000-1000-8000-0026BB765291 |
| RotationDirection                     | 28    | 00000028-0000-1000-8000-0026BB765291 |
| RotationSpeed                         | 29    | 00000029-0000-1000-8000-0026BB765291 |
| Saturation                            | 2F    | 0000002F-0000-1000-8000-0026BB765291 |
| SerialNumber                          | 30    | 00000030-0000-1000-8000-0026BB765291 |
| TargetDoorState                       | 32    | 00000032-0000-1000-8000-0026BB765291 |
| TargetHeatingCoolingState             | 33    | 00000033-0000-1000-8000-0026BB765291 |
| TargetRelativeHumidity                | 34    | 00000034-0000-1000-8000-0026BB765291 |
| TargetTemperature                     | 35    | 00000035-0000-1000-8000-0026BB765291 |
| TemperatureDisplayUnits               | 36    | 00000036-0000-1000-8000-0026BB765291 |
| Version                               | 37    | 00000037-0000-1000-8000-0026BB765291 |
| PairSetup                             | 4C    | 0000004C-0000-1000-8000-0026BB765291 |
| PairVerify                            | 4E    | 0000004E-0000-1000-8000-0026BB765291 |
| PairingFeatures                       | 4F    | 0000004F-0000-1000-8000-0026BB765291 |
| PairingPairings                       | 50    | 00000050-0000-1000-8000-0026BB765291 |
| FirmwareRevision                      | 52    | 00000052-0000-1000-8000-0026BB765291 |
| HardwareRevision                      | 53    | 00000053-0000-1000-8000-0026BB765291 |
| AirParticulateDensity                 | 64    | 00000064-0000-1000-8000-0026BB765291 |
| AirParticulateSize                    | 65    | 00000065-0000-1000-8000-0026BB765291 |
| SecuritySystemCurrentState            | 66    | 00000066-0000-1000-8000-0026BB765291 |
| SecuritySystemTargetState             | 67    | 00000067-0000-1000-8000-0026BB765291 |
| BatteryLevel                          | 68    | 00000068-0000-1000-8000-0026BB765291 |
| CarbonMonoxideDetected                | 69    | 00000069-0000-1000-8000-0026BB765291 |
| ContactSensorState                    | 6A    | 0000006A-0000-1000-8000-0026BB765291 |
| CurrentAmbientLightLevel              | 6B    | 0000006B-0000-1000-8000-0026BB765291 |
| CurrentHorizontalTiltAngle            | 6C    | 0000006C-0000-1000-8000-0026BB765291 |
| CurrentPosition                       | 6D    | 0000006D-0000-1000-8000-0026BB765291 |
| CurrentVerticalTiltAngle              | 6E    | 0000006E-0000-1000-8000-0026BB765291 |
| HoldPosition                          | 6F    | 0000006F-0000-1000-8000-0026BB765291 |
| LeakDetected                          | 70    | 00000070-0000-1000-8000-0026BB765291 |
| OccupancyDetected                     | 71    | 00000071-0000-1000-8000-0026BB765291 |
| PositionState                         | 72    | 00000072-0000-1000-8000-0026BB765291 |
| ProgrammableSwitchEvent               | 73    | 00000073-0000-1000-8000-0026BB765291 |
| StatusActive                          | 75    | 00000075-0000-1000-8000-0026BB765291 |
| SmokeDetected                         | 76    | 00000076-0000-1000-8000-0026BB765291 |
| StatusFault                           | 77    | 00000077-0000-1000-8000-0026BB765291 |
| StatusJammed                          | 78    | 00000078-0000-1000-8000-0026BB765291 |
| StatusLowBattery                      | 79    | 00000079-0000-1000-8000-0026BB765291 |
| StatusTampered                        | 7A    | 0000007A-0000-1000-8000-0026BB765291 |
| TargetHorizontalTiltAngle             | 7B    | 0000007B-0000-1000-8000-0026BB765291 |
| TargetPosition                        | 7C    | 0000007C-0000-1000-8000-0026BB765291 |
| TargetVerticalTiltAngle               | 7D    | 0000007D-0000-1000-8000-0026BB765291 |
| SecuritySystemAlarmType               | 8E    | 0000008E-0000-1000-8000-0026BB765291 |
| ChargingState                         | 8F    | 0000008F-0000-1000-8000-0026BB765291 |
| CarbonMonoxideLevel                   | 90    | 00000090-0000-1000-8000-0026BB765291 |
| CarbonMonoxidePeakLevel               | 91    | 00000091-0000-1000-8000-0026BB765291 |
| CarbonDioxideDetected                 | 92    | 00000092-0000-1000-8000-0026BB765291 |
| CarbonDioxideLevel                    | 93    | 00000093-0000-1000-8000-0026BB765291 |
| CarbonDioxidePeakLevel                | 94    | 00000094-0000-1000-8000-0026BB765291 |
| AirQuality                            | 95    | 00000095-0000-1000-8000-0026BB765291 |
| AccessoryFlags                        | A6    | 000000A6-0000-1000-8000-0026BB765291 |
| LockPhysicalControls                  | A7    | 000000A7-0000-1000-8000-0026BB765291 |
| TargetAirPurifierState                | A8    | 000000A8-0000-1000-8000-0026BB765291 |
| CurrentAirPurifierState               | A9    | 000000A9-0000-1000-8000-0026BB765291 |
| CurrentSlatState                      | AA    | 000000AA-0000-1000-8000-0026BB765291 |
| FilterLifeLevel                       | AB    | 000000AB-0000-1000-8000-0026BB765291 |
| FilterChangeIndication                | AC    | 000000AC-0000-1000-8000-0026BB765291 |
| ResetFilterIndication                 | AD    | 000000AD-0000-1000-8000-0026BB765291 |
| CurrentFanState                       | AF    | 000000AF-0000-1000-8000-0026BB765291 |
| Active                                | B0    | 000000B0-0000-1000-8000-0026BB765291 |
| CurrentHeaterCoolerState              | B1    | 000000B1-0000-1000-8000-0026BB765291 |
| TargetHeaterCoolerState               | B2    | 000000B2-0000-1000-8000-0026BB765291 |
| CurrentHumidifierDehumidifierState    | B3    | 000000B3-0000-1000-8000-0026BB765291 |
| TargetHumidifierDehumidifierState     | B4    | 000000B4-0000-1000-8000-0026BB765291 |
| WaterLevel                            | B5    | 000000B5-0000-1000-8000-0026BB765291 |
| SwingMode                             | B6    | 000000B6-0000-1000-8000-0026BB765291 |
| TargetFanState                        | BF    | 000000BF-0000-1000-8000-0026BB765291 |
| SlatType                              | C0    | 000000C0-0000-1000-8000-0026BB765291 |
| CurrentTiltAngle                      | C1    | 000000C1-0000-1000-8000-0026BB765291 |
| TargetTiltAngle                       | C2    | 000000C2-0000-1000-8000-0026BB765291 |
| OzoneDensity                          | C3    | 000000C3-0000-1000-8000-0026BB765291 |
| NitrogenDioxideDensity                | C4    | 000000C4-0000-1000-8000-0026BB765291 |
| SulphurDioxideDensity                 | C5    | 000000C5-0000-1000-8000-0026BB765291 |
| PM2.5Density                          | C6    | 000000C6-0000-1000-8000-0026BB765291 |
| PM10Density                           | C7    | 000000C7-0000-1000-8000-0026BB765291 |
| VOCDensity                            | C8    | 000000C8-0000-1000-8000-0026BB765291 |
| RelativeHumidityDehumidifierThreshold | C9    | 000000C9-0000-1000-8000-0026BB765291 |
| RelativeHumidityHumidifierThreshold   | CA    | 000000CA-0000-1000-8000-0026BB765291 |
| ServiceLabelIndex                     | CB    | 000000CB-0000-1000-8000-0026BB765291 |
| ServiceLabelNamespace                 | CD    | 000000CD-0000-1000-8000-0026BB765291 |
| ColorTemperature                      | CE    | 000000CE-0000-1000-8000-0026BB765291 |
| ProgramMode                           | D1    | 000000D1-0000-1000-8000-0026BB765291 |
| InUse                                 | D2    | 000000D2-0000-1000-8000-0026BB765291 |
| SetDuration                           | D3    | 000000D3-0000-1000-8000-0026BB765291 |
| RemainingDuration                     | D4    | 000000D4-0000-1000-8000-0026BB765291 |
| ValveType                             | D5    | 000000D5-0000-1000-8000-0026BB765291 |
| IsConfigured                          | D6    | 000000D6-0000-1000-8000-0026BB765291 |
| InputSourceType                       | DB    | 000000DB-0000-1000-8000-0026BB765291 |
| InputDeviceType                       | DC    | 000000DC-0000-1000-8000-0026BB765291 |
| ClosedCaptions                        | DD    | 000000DD-0000-1000-8000-0026BB765291 |
| PowerModeSelection                    | DF    | 000000DF-0000-1000-8000-0026BB765291 |
| CurrentMediaState                     | E0    | 000000E0-0000-1000-8000-0026BB765291 |
| RemoteKey                             | E1    | 000000E1-0000-1000-8000-0026BB765291 |
| PictureMode                           | E2    | 000000E2-0000-1000-8000-0026BB765291 |
| ConfiguredName                        | E3    | 000000E3-0000-1000-8000-0026BB765291 |
| Identifier                            | E6    | 000000E6-0000-1000-8000-0026BB765291 |
| ActiveIdentifier                      | E7    | 000000E7-0000-1000-8000-0026BB765291 |
| SleepDiscoveryMode                    | E8    | 000000E8-0000-1000-8000-0026BB765291 |
| VolumeControlType                     | E9    | 000000E9-0000-1000-8000-0026BB765291 |
| VolumeSelector                        | EA    | 000000EA-0000-1000-8000-0026BB765291 |
| SupportedVideoStreamConfiguration     | 114   | 00000114-0000-1000-8000-0026BB765291 |
| SupportedAudioStreamConfiguration     | 115   | 00000115-0000-1000-8000-0026BB765291 |
| SupportedRTPConfiguration             | 116   | 00000116-0000-1000-8000-0026BB765291 |
| SelectedRTPStreamConfiguration        | 117   | 00000117-0000-1000-8000-0026BB765291 |
| SetupEndpoints                        | 118   | 00000118-0000-1000-8000-0026BB765291 |
| Volume                                | 119   | 00000119-0000-1000-8000-0026BB765291 |
| Mute                                  | 11A   | 0000011A-0000-1000-8000-0026BB765291 |
| NightVision                           | 11B   | 0000011B-0000-1000-8000-0026BB765291 |
| OpticalZoom                           | 11C   | 0000011C-0000-1000-8000-0026BB765291 |
| DigitalZoom                           | 11D   | 0000011D-0000-1000-8000-0026BB765291 |
| ImageRotation                         | 11E   | 0000011E-0000-1000-8000-0026BB765291 |
| ImageMirroring                        | 11F   | 0000011F-0000-1000-8000-0026BB765291 |
| StreamingStatus                       | 120   | 00000120-0000-1000-8000-0026BB765291 |
| TargetVisibilityState                 | 134   | 00000134-0000-1000-8000-0026BB765291 |
| CurrentVisibilityState                | 135   | 00000135-0000-1000-8000-0026BB765291 |
| DisplayOrder                          | 136   | 00000136-0000-1000-8000-0026BB765291 |
| TargetMediaState                      | 137   | 00000137-0000-1000-8000-0026BB765291 |
| TransitionControl                     | 143   | 00000143-0000-1000-8000-0026BB765291 |
| SupportedTransitionConfiguration      | 144   | 00000144-0000-1000-8000-0026BB765291 |
| ActiveTransitionCount                 | 24B   | 0000024B-0000-1000-8000-0026BB765291 |
| ConfigurationState                    | 263   | 00000263-0000-1000-8000-0026BB765291 |
| NFCAccessControlPoint                 | 264   | 00000264-0000-1000-8000-0026BB765291 |
| NFCAccessSupportedConfiguration       | 265   | 00000265-0000-1000-8000-0026BB765291 |
| HardwareFinish                        | 26C   | 0000026C-0000-1000-8000-0026BB765291 |

---

## 7. JSON Example

```json
{
  "iid": 10,
  "type": "8",
  "perms": ["pr", "pw", "ev"],
  "format": "int",
  "value": 75,
  "minValue": 0,
  "maxValue": 100,
  "minStep": 1,
  "unit": "percentage"
}
```

---

## 8. Notes

1. **Events permission (ev)**: Characteristics with this permission can send
   unsolicited notifications to subscribed controllers.

2. **Null values**: If a characteristic is not readable or has no current value,
   `value` may be omitted or null.

3. **Custom characteristics**: Vendors can define custom characteristics using
   UUIDs outside the Apple base range.

4. **Value constraints**: `valid-values` and `valid-values-range` constrain the
   allowed values for enumerated types.

5. **Units**: The `unit` field is informational; the actual value is always in
   the native unit (Celsius for temperature, etc.).
