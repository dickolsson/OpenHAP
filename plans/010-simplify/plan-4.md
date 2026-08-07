# Phase 4 — The App::OpenHAP sweep

This phase removes about 740 lines from `lib/App/OpenHAP/`, `bin/openhapd`, and
`bin/hapctl`, plus about 330 lines from the integration tier and the drifted
sections of `openhapd.conf.5`. It wires in the humidity option and deletes the
unreachable Tasmota surface (design decisions 2, 8, 9, 14). Phase 1 must land
first. Phases 2, 3, and 5 are independent of it.

Every deletion re-verifies with a grep across `lib/ bin/ t/ etc/ man/ share/`
first.

## Tasks

### 4.1 The unreachable Tasmota surface

`App::OpenHAP::Devices` is the only production constructor of device objects.
Everything its argument list cannot reach goes:

- `fulltopic` and its `_build_topic` token substitution: with the fixed default,
  the method is one interpolated string. The `setoption26` branches in
  `_get_power_key` and `_get_power_topic` go the same way. Users of both: the
  four subclass pass-throughs and `t/conformance/mqtt-transport.t`.
- The color pipeline nothing drives: `_parse_color`, `_rgb_to_hsb` (with its
  integer-`%` hue bug), `set_color`, `dimmer_step`, `dimmer_min`, `dimmer_max`.
  HAP writes hue and saturation as separate characteristics; no path constructs
  a `Color` command.
- `toggle_power`, `blink`, `force_telemetry`: no HAP path calls them.
- The `_on_availability_changed` hook: zero overrides in the repo, so the hook
  and its change-detection go.
- The write-only `sensor_id` field and its three `Id` extractions.
- `Host.pm`: the `loop => $args{loop}` pass-through nothing supplies.

Wire in `has_humidity` instead of deleting it (decision 2): a `humidity` option
on the sensor block in `Devices.pm`, one paragraph in `openhapd.conf.5`, one
line in the sample config.

### 4.2 Dead code and drifted documentation

- Delete `Host::stop` (zero callers; shutdown runs on signal flags),
  `Tasmota::Device::get_availability`, and the merged-but-never-read
  `last_state` hash.
- Delete the Exporter plumbing of `App::OpenHAP::Test::Integration`; no test
  imports a symbol. Delete `clear_logs`, `get_log_lines`, `_count_log_lines`,
  and the `log_baseline` capture — orphaned when plan 001 moved the assertions
  to `mdnsctl browse`. `SYSLOG_FILE` stays for `_read_syslog_tail`.
- `openhapd.conf.5`: delete the six thermostat options that no code reads and
  the `min_temp`/`max_temp` example rows (decision 9); delete `hap_model` and
  `hap_manufacturer` and their two sample lines (decision 8).
- Delete the unreachable `_device_type_name` fallback and the memoization guard
  on `Host::listen`.

### 4.3 Base-class dedup across Tasmota/\*.pm

- One `_handle_status_sns($payload, $label)` in `Tasmota::Device` with an
  overridable extractor replaces the four copies of the STATUS8/STATUS10 handler
  pair.
- `Thermostat::_find_temperature` becomes a call into the sensor walk it is a
  subset of; `SENSOR_TYPES` moves to `Tasmota::Device`.
- One `_subscribe_plain_power($field, $iid)` base helper replaces the three
  copies of the plain-text POWER subscription; the thermostat keeps its change
  guard as an argument.
- One `_decode($payload, $label)` helper replaces the eight
  `eval { decode_json } / if ($@)` wrappers.
- The four subclass constructors pass `%args` through:
  `$class->SUPER::new(%args, model => ...)` replaces the retyped key lists.
  `relay_index` defaults once, in `Tasmota::Device`.
- The `add_characteristic` boilerplate in `Lightbulb` and `Thermostat` becomes a
  spec table and a loop; the CT clamp becomes one helper; the three derived
  capability booleans become mask tests at the use sites.
- `Devices.pm`: the four lightbulb-family `%DEVICE` closures become one entry
  shape with a `caps` bitmask, and the two duplicate entries become aliases.
  `_is_supported_device` and `_instantiate_device` share one lookup, which
  removes the `eval` that guarded only the impossible miss.

### 4.4 Defensive checks in the host and the commands

- `Host.pm`: delete the ternary chains over the `by_fileno`/`connections` pair
  that `_accept` installs together, the `ref $socket` guard in `shutdown`, two
  of the three failure layers in `_write`, the `can('subscribe_mqtt')` probe,
  and the five pre-declared `undef` fields. Collapse the two-stage mDNS guard to
  one condition.
- `bin/openhapd`: read `hap_pin` once; hoist the duplicated `set_mqtt_client`
  call out of the MQTT-connect branches.
- `bin/hapctl`: delete the double validation in `uptime`; fold the two printf
  blocks into one formatter over a field list; inline the two option-wrapper
  subs. `openhapd -n` stays (decision 13).

### 4.5 The integration tier

- Add to `App::OpenHAP::Test::Integration`: a `status($response)` wrapper, a
  `find_char($type)` lookup, a `wait_value` poll, a `browse` / `browse_txt`
  pair, and a `restart_daemon` method. Replace the seventeen fully-qualified
  `parse_http_response` calls, the four `find_char` copies, the two poll loops,
  the three `browse` definitions, the hand-rolled port wait in `shutdown.t`, and
  the eleven restart incantations.
- `_parse_config` calls `App::OpenHAP::Devices->devices($config)` — the
  duplication its own comment warns against — and `get_device_topics` derives
  from `get_devices`.
- Delete the non-falsifiable subtests (decision 14): the eleven
  status-disjunction tests in `hap-protocol.t`, the `_verify_system` restatement
  in `environment.t` (the GMP assertion stays), the disjunction and repeat tests
  in `hapctl.t`, and the `configuration.t` tests that duplicate `hapctl.t` and
  `daemon.t`. Integration tests never skip; these never fail, which is the same
  defect mirrored.

### 4.6 Documentation

- Update the sidecars: `Host.pod`, `Devices.pod`, `Tasmota/*.pod`,
  `Test/Integration.pod`.
- `openhapd.conf.5` gains the `humidity` option and loses the drifted sections
  (4.2).

## Deliverables

- Smaller `lib/App/OpenHAP/{Host,Devices}.pm`, `Tasmota/*.pm`, and
  `Test/Integration.pm`, with updated sidecars.
- Smaller `bin/openhapd` and `bin/hapctl`.
- Corrected `man/openhap/openhapd.conf.5` and sample config.
- A leaner `t/openhap/integration/` tier.

## Acceptance criteria

- `make check` passes; `make spec-coverage` reports no stale citation.
- `make integration` passes in CI.
- `grep -rn 'fulltopic\|setoption26\|_rgb_to_hsb\|set_color\|blink' lib bin t`
  finds nothing.
- `grep -rn 'get_log_lines\|clear_logs\|log_baseline' lib t` finds nothing.
- `grep -n 'min_temp\|hap_model' man/openhap/openhapd.conf.5 share` finds
  nothing.
- A config with `humidity 1` on a sensor block builds a HumiditySensor service;
  `t/conformance/mqtt-sensors.t` proves it through the config path rather than
  direct construction.
- `grep -rn 'parse_http_response' t/openhap/integration` finds only the module
  and the `status` wrapper.
- Every deleted integration subtest either had a duplicate that stays or could
  not fail; the commit message lists which, per subtest.
