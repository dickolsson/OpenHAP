# Phase 2 — Data model

This phase moves the accessory data model to `Protocol::HAP` and introduces the
logger contract. The Tasmota drivers and the device loader retarget their
imports and keep their behavior.

## Tasks

### 2.1 Move the four model modules

- `git mv` and rename: `OpenHAP::Accessory`, `Service`, `Characteristic`, and
  `Bridge` become `Protocol::HAP::Accessory`, `Service`, `Characteristic`, and
  `Bridge`.
- Move each `.pod` sidecar with its module.
- Move `t/openhap/accessory.t`, `service.t`, `characteristic.t`, and `bridge.t`
  to `t/protocol/`.

### 2.2 Inject the logger

- Remove `use FuguLib::Log` from `Characteristic` and `Bridge`, the two model
  modules that log.
- Add the `logger` constructor argument to all four modules. The default is the
  null logger from `Protocol::HAP`. An object passes its logger only to the
  objects it creates itself: the `Bridge` to its own `ProtocolInformation`
  service, an `Accessory` to the services and characteristics it builds.
  `add_bridged_accessory` never touches the logger of an accessory it receives —
  no stamping, no fallback.
- The production log lines live in `Characteristic::set_value` and
  `enable_events`, and the Tasmota drivers create those characteristics. The
  drivers and `OpenHAP::DeviceLoader` therefore pass
  `logger => FuguLib::Log->default` to every accessory, service, and
  characteristic they create. `OpenHAP::HAP` does the same for the bridge. With
  both paths wired, the daemon's log output does not change.

### 2.3 JSON

- Replace `JSON::XS` with core `JSON::PP` inside the moved modules. The
  `\1`/`\0` boolean references encode the same way in both.
- The Tasmota drivers and `DeviceLoader` stay on `JSON::XS`; they remain OpenHAP
  code.

### 2.4 Retarget the consumers

- Update the imports and `our @ISA` lines: `OpenHAP::Tasmota::Base` extends
  `Protocol::HAP::Accessory`; the drivers and `DeviceLoader` use
  `Protocol::HAP::Service` and `Protocol::HAP::Characteristic`.
- Update `OpenHAP::HAP` and the conformance tests that name the model classes
  (`hap-categories.t`, `hap-characteristics.t`, `hap-services.t`).

## Deliverables

- `lib/Protocol/HAP/{Accessory,Service,Characteristic,Bridge}.pm` with `.pod`
  sidecars that document the `logger` argument.
- `t/protocol/{accessory,service,characteristic,bridge}.t`.
- Retargeted `OpenHAP::Tasmota::*`, `OpenHAP::DeviceLoader`, `OpenHAP::HAP`, and
  conformance tests.

## Acceptance criteria

- `make check` passes.
- `grep -r 'OpenHAP::Accessory\|OpenHAP::Service\|OpenHAP::Characteristic\|OpenHAP::Bridge' lib bin t`
  finds nothing.
- `t/protocol/boundary.t` passes: the model modules load no FuguLib code.
- A model test proves the default logger is silent and an injected logger
  receives the messages.
- `t/openhap/tasmota.t` asserts that a characteristic a driver creates carries
  the injected logger, so the write and subscription debug lines survive.
- `t/openhap/tasmota.t` and `t/openhap/device-loading.t` pass unchanged in what
  they assert otherwise.
