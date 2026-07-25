# Phase 5 — Integration suite upgrade

Use `OpenHAP::Test::Controller` (Phase 4) inside the OpenBSD VM to light up the
untested paired half of the protocol end to end, and close the MQTT↔HAP loop.
Follows the integration rules: real interfaces, no SKIP, no log parsing.

## Tasks

### 5.1 Helper integration

- `OpenHAP::Test::Integration`: add `get_controller` (constructs a
  `Test::Controller` for the configured host/port/PIN, reading the setup code
  from `/etc/openhapd.conf`), `ensure_unpaired` (removes stored pairings via the
  controller, or resets `/var/db/openhapd` state through `rcctl` stop/start when
  unpairable), and socket tracking for controller connections in `teardown`.
- `scripts/integration.sh`: ship `lib/OpenHAP/Test/` (and `t/lib/`) to the VM
  alongside `t/openhap/integration/`; keep the explicit file order with
  `environment.t` first and a new `zz-unpair.t`-style guarantee replaced by
  per-file `ensure_unpaired` in setup — every file starts unpaired unless it
  pairs itself.

### 5.2 `pairing.t` — complete the flows

- Replace the M1-only probes: full pair-setup with the real PIN
  (`[HAP-Pairing §2]`), wrong-PIN rejection + attempt counting (`§2.6`, `§8`),
  pair-verify (`§3`), re-pair after remove, add/list/remove pairings over the
  wire (`§7`), unpair in teardown.
- Keep the "0x"-prefix regression assertion, now citing `[HAP-Pairing §2.4]`.

### 5.3 New `characteristics.t` — authenticated data plane

- Absorb the unreachable 200-branches from `accessories.t`: paired GET
  `/accessories` JSON structure (`[HAP-HTTP §7]`, bridge aid=1 per
  `[HAP §3.1]`), GET/PUT `/characteristics` with real values and status codes
  200/204/207 (`§8–§9`), write-response `r:true`, timed write via `/prepare` +
  `pid` (`§10`), invalid iid → HAP status −70409 (`§12`).
- `accessories.t` keeps only the unpaired-gating (470) assertions.

### 5.4 New `events.t` — notifications

- Subscribe (`ev:true`), change a value via a second controller connection or
  MQTT, assert an `EVENT/1.0` message arrives with the new value
  (`[HAP-HTTP §14]`); assert subscriptions are per-connection (a second,
  unsubscribed controller receives nothing).

### 5.5 MQTT↔HAP round trips

- `tasmota-protocol.t` becomes real: for each simulated device message (POWER,
  STATE, SENSOR, LWT), publish on the broker and assert the mapped
  characteristic changed via paired GET `/characteristics` — citing both the
  MQTT section (`[MQTT-State §1]` etc.) and the mapping (`[MQTT §4]`).
- Reverse direction: PUT a characteristic, assert the expected
  `cmnd/<topic>/...` publish is observed on a broker subscription
  (`[MQTT-Control §1–§4]`).
- LWT Offline → accessory unavailable behavior, Online → `Status 11` query
  observed (`[MQTT-Transport §1.4]`).

### 5.6 mDNS dynamic semantics

- `mdns.t`: after pairing, assert `sf` flips to 0 in the browsed TXT record;
  after a device add + restart, assert `c#` incremented and persisted
  (`[HAP-mDNS §3]`, `§8`) — via `mdnsctl`, not logs.

### 5.7 Suite ordering and state

- Document in `t/openhap/integration/CLAUDE.md`: files own their pairing
  lifecycle (pair in setup if needed, unpair in teardown); the shared daemon is
  never left paired between files; `prove` runs the explicit ordered list from
  `scripts/integration.sh`.

## Deliverables

- New: `t/openhap/integration/characteristics.t`, `events.t`.
- Modified: `OpenHAP::Test::Integration` (+`.pod`), `scripts/integration.sh`,
  integration `pairing.t`, `accessories.t`, `tasmota-protocol.t`, `mdns.t`,
  `t/openhap/integration/CLAUDE.md`.

## Acceptance criteria

- `make integration` passes in the VM with every file starting and ending
  unpaired.
- No `ok(1)` placeholders or unreachable assertion branches remain under
  `t/openhap/integration/`.
- `make spec-coverage` shows integration citations for `HAP-HTTP §7–§10`, `§14`,
  `HAP-Pairing §2/§3/§7`, `HAP-mDNS §3/§8`, and both MQTT round-trip directions.
- A full MQTT→HAP→MQTT loop (publish `stat` → GET characteristic; PUT
  characteristic → observe `cmnd`) is asserted for at least the Lightbulb and
  Sensor device types.
