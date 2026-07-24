---
name: spec-mqtt
description:
  Extract the Tasmota MQTT protocol from external/Tasmota-Docs into spec/MQTT.md
  plus topic files spec/MQTT-*.md. Use when asked to generate, regenerate, or
  update the MQTT spec documents. Requires external/ to be populated.
---

# Extract Tasmota MQTT Protocol

## Objective

Produce `spec/MQTT.md` plus topic files `spec/MQTT-*.md` documenting how Tasmota
devices communicate over MQTT. OpenHAP bridges Tasmota to HomeKit, so these
documents should enable accurate translation between the two protocols.

## Preconditions

If `external/Tasmota-Docs` is absent, run the `fetch-external` skill first.

## Primary Source

Read `external/Tasmota-Docs/docs/MQTT.md` thoroughly — this is the authoritative
source.

Supplement with:

- `external/Tasmota-Docs/docs/Commands.md` — Command syntax and parameters
- `external/Tasmota-Docs/docs/Lights.md` — Light-specific commands
- `external/Tasmota-Docs/docs/Buttons-and-Switches.md` — Input handling
- `external/Tasmota-Docs/docs/Status.md` — Status message format

When extracting specific values or behaviors, cite the source file (e.g., "from
`Commands.md`") to enable later verification and updates.

## What to Document

**Topic Structure** How Tasmota organizes MQTT topics (`cmnd/`, `stat/`,
`tele/`), the role of `%topic%` and `%prefix%`, and how FullTopic customization
works.

**Command/Response Pattern** How commands are sent, how responses come back, the
relationship between `cmnd/` commands and `stat/` responses. Include
bidirectional flow diagrams showing the complete request/response cycle with all
possible response topics.

**Device Control Commands** Document the commands needed to control devices
OpenHAP bridges:

- Power control (on/off/toggle for switches and relays)
- Dimmer control (brightness levels)
- Color control (RGB, HSB, color temperature)
- Status queries

For each command, document: topic, payload format, expected response. Also
document default behavior when optional payload fields are omitted.

**State Reporting** How Tasmota reports state changes — both immediate (`stat/`)
and periodic (`tele/`). Document the JSON structure of state messages.

**State Reconciliation** How to handle stale state after network interruptions.
Document strategies for re-querying device state on reconnection and handling
missed state changes.

**Sensor Data** How Tasmota reports sensor readings (temperature, humidity).
Document the JSON structure and common sensor types (DS18B20, DHT, BME280).

**Telemetry** The `tele/` topics, TelePeriod setting, and what data is sent
periodically.

**Configuration Commands** SetOption commands that affect MQTT behavior and are
relevant to integration.

**Error Handling** How Tasmota reports errors, connection failures, and invalid
commands. Document error codes and recovery strategies.

**Device Groups** How Tasmota handles device groups for synchronized control of
multiple devices.

**Timing Considerations** Response latencies, telemetry intervals, and
reconnection behavior that affect integration reliability.

## HomeKit Mapping Context

Keep in mind how Tasmota concepts map to HomeKit:

| Tasmota            | HomeKit                                     |
| ------------------ | ------------------------------------------- |
| Power ON/OFF       | Switch/Lightbulb On characteristic          |
| Dimmer 0-100       | Brightness characteristic                   |
| HSBColor           | Hue, Saturation, Brightness characteristics |
| CT                 | ColorTemperature characteristic             |
| Temperature sensor | TemperatureSensor service                   |
| Humidity sensor    | HumiditySensor service                      |

Document Tasmota's side of these mappings so the translation logic is clear.

## Scope Boundaries

**Include:** MQTT topics, commands, state messages, sensor readings, and
configuration relevant to HomeKit bridging.

**Exclude:** Web UI, console commands, OTA updates, rules, scripting, Zigbee,
RF, IR, and other functionality not needed for basic device control.

## Output Structure

Create the MQTT protocol specification as **multiple focused files** in `spec/`
rather than one monolithic document. This avoids context limits and makes the
specification easier to navigate and maintain.

**Required:** Create `spec/MQTT.md` as an index/overview that:

- Provides a glossary defining key terms (e.g., FullTopic, prefix, topic,
  telemetry, LWT, retained message) to ensure consistent terminology throughout
- Gives a high-level protocol overview
- Links to the topic-specific files for detailed information
- Carries the cross-cutting quick references (HomeKit mapping, essential
  commands and subscriptions)

**Topic files:** Break out detailed content into separate `spec/MQTT-*.md`
files. Split along the code's own boundaries — transport concerns (topics,
command/response, configuration, errors, timing) serve the MQTT client module,
while device-class concerns (control commands, state reporting, sensors) serve
the per-device Tasmota modules. Let the natural structure of the content guide
the exact split.

Each topic file should be self-contained enough to be useful on its own, but can
cross-reference other files in the spec.

## Formatting Guidelines

Use:

- **Numbered sections** (1, 1.1, 1.1.1) throughout for easy cross-referencing
- Actual topic patterns with examples
- Real command syntax with exact payloads
- JSON message structures as they actually appear
- Concrete examples for common operations (turn on light, set brightness, read
  temperature)
- Notes on timing, QoS, and retained messages where relevant

Aim for depth over brevity — document all payload variations, edge cases in
value ranges, and timing considerations. Include complete JSON examples showing
all fields that may appear in responses.

The specification should enable someone to write code that correctly sends
commands to and receives state from Tasmota devices.
