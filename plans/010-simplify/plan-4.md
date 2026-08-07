# Phase 4 — The App::OpenHAP sweep

This phase removes about 700 lines from `lib/App/OpenHAP/`, `bin/openhapd`, and
`bin/hapctl`, plus about 330 lines from the integration tier and the drifted
sections of `openhapd.conf.5`. It executes decisions 2, 3, 8, 9, 11, 14, and 19,
and fixes two bugs (the hue `%`, the SIGPIPE hole). Phases 1–3 must land first:
phase 2 deleted the `identify` hook this phase's `blink` grep would otherwise
match, and phase 3 provides the shared write loop that 4.4 uses.

Every deletion re-verifies with a grep across `lib/ bin/ t/ etc/ man/ share/`
first.

## Tasks

### 4.1 The Tasmota surface

`App::OpenHAP::Devices` is the only production constructor of device objects.
Everything its argument list cannot reach goes:

- `fulltopic` and its `_build_topic` token substitution: with the fixed default,
  the method is one interpolated string. The `setoption26` branches in
  `_get_power_key` and `_get_power_topic` go the same way. Users, verified:
  `fulltopic` pass-throughs in all four subclasses; `setoption26` in `Heater`,
  `Thermostat`, `Lightbulb` (not `Sensor`); `t/conformance/mqtt-transport.t` and
  `mqtt-control.t:95,106`. Decision 15 applies: `mqtt-transport.t:50,70,152`
  carry the only `[MQTT-Transport §1.2]`, `[§1.3]`, `[§3.1]`, `[§3.2]`
  citations; the §1.x subtests re-target the fixed-default `_build_topic`, and
  the §3.x citations drop with the feature — list them in the commit with the
  matrix diff.
- Decision 3: the color pipeline stays; fix the hue bug at `Lightbulb.pm:496` —
  Perl's `%` truncates, so red-dominant colors get hue 0; use a floating-point
  modulus. Keep `_parse_color`, `_rgb_to_hsb`, and the `[MQTT-Control §3.2]`
  subtest. Delete the outbound surface nothing calls: `set_color`,
  `dimmer_step`, `dimmer_min`, `dimmer_max`, `toggle_power`, `blink`,
  `force_telemetry`. Test fallout, verified: `t/openhap/tasmota.t:88` (`can`
  list) and `:148-163` (direct `_rgb_to_hsb` calls — these stay, now asserting
  the fixed hue), and `t/conformance/mqtt-control.t:71-78` (the BLINK/BLINKOFF
  asserts inside the §1 subtest go; the set_power asserts keep the citation).
- The `_on_availability_changed` hook: zero overrides, so the hook and its
  change-detection go.
- The write-only `sensor_id` field, its three `Id` extractions, and the no-op
  "auto-detected humidity support" branch beside them (decision 2: it sets
  nothing and cannot add a service after construction).
- `Host.pm`: the `loop => $args{loop}` pass-through nothing supplies.
- Decision 2: document `has_humidity` — it already works. One paragraph in
  `openhapd.conf.5`, one line in the sample config. No new key.

### 4.2 Dead code and drifted documentation

- Delete `Host::stop` (zero callers; shutdown runs on signal flags),
  `Tasmota::Device::get_availability`, and the merged-but-never-read
  `last_state` hash.
- Delete the Exporter plumbing of `App::OpenHAP::Test::Integration`, and its
  orphaned helpers `clear_logs`, `get_log_lines`, `_count_log_lines`, and the
  `log_baseline` capture. `SYSLOG_FILE` stays for `_read_syslog_tail`.
- `openhapd.conf.5`: delete the six thermostat options no code reads and the
  `min_temp`/`max_temp` example rows (decision 9); delete `hap_model` and
  `hap_manufacturer` with their two sample lines (decision 8).
- Delete the unreachable `_device_type_name` fallback. Keep the `Host::listen`
  memoization — `hap-pairing-exchange.t` forks after binding port 0 and the
  guard is what keeps the child on the parent's port.

### 4.3 Decision 11 — one spelling per log level

This decision spans two tiers, so it lands here whole:

- `lib/Fugu/Log.pm`: the vocabulary becomes the five method names (`debug`,
  `info`, `notice`, `warning`, `error`). The `warn`/`err` alias rows,
  `_canonical_level`, and the `crit` rows go. The facility rows stay — `daemon`,
  `local0`–`local7`, `user` are documented operator surface.
- `bin/openhapd` validates `log_level` and `log_facility` against the accepted
  sets at config load and fails closed with the offending value, before
  daemonize. `Fugu::Log` keeps its internal defaults; the boundary owns the
  validation.
- `man/openhap/openhapd.conf.5:138` changes to list exactly the five levels — it
  currently promises `err`, `crit`, `alert`, and `emerg`, two of which the code
  never accepted. The facility line and its `log_facility = local0` example
  stay. `man/fugu/Log.3p` matches.
- `t/fugu/log.t` updates: the alias subtests go; the one-name-per-level
  assertions stay; `t/openhap/` gains a config-validation case (bad level, bad
  facility → fatal, named value).

### 4.4 Defensive checks in the host and the commands

- Decision 19: rebuild `Host::_write`. None of its three guards handles SIGPIPE
  — no `$SIG{PIPE}` exists anywhere on the daemon path — and the `syswrite`
  return is discarded, so a controller closing mid-write can kill the daemon or
  truncate a frame. Replace the body with `Fugu::File`'s shared write loop (from
  phase 3) under a `local $SIG{PIPE} = 'IGNORE'`, dropping the connection on
  failure.
- `Host.pm`: delete the ternary chains over the `by_fileno`/`connections` pair
  that `_accept` installs together, the `ref $socket` guard in `shutdown`, the
  `can('subscribe_mqtt')` probe, and the five pre-declared `undef` fields.
  Collapse the two-stage mDNS guard to one condition.
- `bin/openhapd`: read `hap_pin` once. The read stays where the first one is now
  — before the `-n` exit and before daemonize — so the fatal setup-code error
  from phase 2 keeps reaching the terminal.
- `bin/hapctl`: fold the two printf blocks into one formatter over a field list;
  inline the two option-wrapper subs. Keep both `uptime` checks (shape and
  future-timestamp — different faults) and keep `openhapd -n` (decision 13).
- Keep the `Devices.pm` eval: it guards a runtime `require` and a constructor of
  config-named classes, after daemonize. Deduplicate only the `%DEVICE` lookup
  that `_is_supported_device` and `_instantiate_device` both perform.

### 4.5 Base-class dedup across Tasmota/\*.pm

- One `_handle_status_sns($payload, $label)` in `Tasmota::Device` with an
  overridable extractor replaces the four copies of the STATUS8/STATUS10 handler
  pair.
- `Thermostat::_find_temperature` becomes a call into the sensor walk it is a
  subset of; `SENSOR_TYPES` moves to `Tasmota::Device`.
- One `_subscribe_plain_power($field, $iid)` base helper replaces the three
  copies of the plain-text POWER subscription.
- One `_decode($payload, $label)` helper replaces the eight
  `eval { decode_json } / if ($@)` wrappers.
- The four subclass constructors pass `%args` through:
  `$class->SUPER::new(%args, model => ...)`. `relay_index` defaults once.
- The `add_characteristic` boilerplate in `Lightbulb` and `Thermostat` becomes a
  spec table and a loop; the CT clamp becomes one helper; the three capability
  booleans become mask tests.
- `Devices.pm`: the four lightbulb-family `%DEVICE` closures become one entry
  shape with a `caps` bitmask; the two duplicate entries become aliases.

### 4.6 The integration tier

- Add to `App::OpenHAP::Test::Integration`: `status($response)`,
  `find_char($type)`, `wait_value`, `browse`/`browse_txt`, and `restart_daemon`.
  Replace the seventeen fully-qualified `parse_http_response` calls, the four
  `find_char` copies, the two poll loops, the three `browse` definitions, the
  hand-rolled port wait in `shutdown.t`, and the eleven restart incantations.
- `_parse_config` calls `App::OpenHAP::Devices->devices($config)`;
  `get_device_topics` derives from `get_devices`.
- Decision 14: delete the eleven status-disjunction subtests in
  `hap-protocol.t`, the `_verify_system` restatement in `environment.t` (the GMP
  assertion stays), the disjunction and repeat tests in `hapctl.t`, and the
  `configuration.t` tests that duplicate `hapctl.t` and `daemon.t`. The commit
  lists, per deleted subtest, its surviving duplicate or why it could not fail.

### 4.7 Documentation

- Update the sidecars: `Host.pod`, `Devices.pod`, `Tasmota/*.pod`,
  `Test/Integration.pod`.
- `openhapd.conf.5` changes land in one commit: `has_humidity` in, the drifted
  sections out, the log vocabulary corrected.

## Deliverables

- Smaller `lib/App/OpenHAP/{Host,Devices}.pm`, `Tasmota/*.pm`, and
  `Test/Integration.pm`, with updated sidecars.
- `lib/Fugu/Log.pm` and `man/fugu/Log.3p` (decision 11).
- Smaller `bin/openhapd` (with the new config validation) and `bin/hapctl`.
- Corrected `man/openhap/openhapd.conf.5` and sample config.
- A leaner `t/openhap/integration/` tier and updated `t/fugu/log.t`.

## Acceptance criteria

- `make check` passes; `make integration` passes in CI.
- `scripts/spec-coverage` matrix diff is attached; the only dropped citations
  are the `setoption26`/`blink` rows the commit lists.
- `git grep -n 'fulltopic\|setoption26\|set_color\|toggle_power\|blink\|force_telemetry' lib bin t`
  finds nothing.
- `git grep -n 'get_log_lines\|clear_logs\|log_baseline' lib t` finds nothing.
- `git grep -rn 'min_temp\|hap_model' man share` finds nothing.
- `git grep -nE '\b(warn|err|crit)\b' lib/Fugu/Log.pm` finds nothing, and
  `openhapd -n` on a config with `log_level err` or `log_facility local9` fails
  naming the value; `log_facility local0` passes.
- A config with `has_humidity 1` on a sensor block builds a HumiditySensor
  service, proven through the config path in `t/conformance/mqtt-sensors.t`.
- RGB(255,128,0) through `_rgb_to_hsb` yields hue 30, asserted in
  `t/openhap/tasmota.t`.
- `git grep -n 'parse_http_response' t/openhap/integration` finds only the
  module and the `status` wrapper.
