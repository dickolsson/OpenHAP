# Phase 2 — Event delivery

With GMP in place `events.t` reaches its event assertions (assertions 1–4 pass),
then assertion 5 `[HAP-HTTP §14] EVENT/1.0 message received` fails and the file
dies decoding the undef body at line 74:

```
malformed JSON string, neither array, object, number, string or atom,
at character offset 0 ... at t/openhap/integration/events.t line 74
```

Static review has settled why; this phase wires the daemon's event path, proves
it host-side, and makes the test fail cleanly.

## Root cause (established by code reading)

The daemon never sends events. `queue_event` (`lib/OpenHAP/HAP.pm`) has no
callers anywhere in `lib/` or `bin/`:

- The `/characteristics` PUT handler calls `set_value` and returns; nothing
  notifies subscribers (`lib/OpenHAP/Characteristic.pm` only stores the value
  and runs `on_set`).
- The device path dead-ends: Tasmota devices call `notify_change`, whose only
  registered callback forwards to the Bridge while discarding the device `$aid`
  (`lib/OpenHAP/Bridge.pm`), and nothing subscribes to the Bridge's own callback
  list — `send_event`/`flush_events` stay unreachable.
- Existing coverage is why this shipped: the unit test asserts only
  `can('queue_event')` and the conformance test calls `send_event` directly,
  bypassing the trigger chain.

Controller-side timing is not the cause — no bytes are ever written to the
subscriber's socket, so no wait extension can turn assertion 5 green. The
controller has real but secondary weaknesses, fixed below.

## Tasks

### 2.1 Wire event emission in the daemon

- HTTP path: after a successful value write in the `/characteristics` PUT
  handler, call `queue_event` for each changed characteristic (cite
  `spec/HAP-HTTP.md` §14).
- Device path: forward `notify_change` through the bridge into `queue_event`
  with the correct device `$aid` (fix the forwarder that currently discards it).
- While in the file: align `IMMEDIATE_EVENT_TYPES` with §14's list (the spec
  names four types; the constant has two) and purge a connection's
  `event_subscriptions` on disconnect.
- Delivery scope: §14 as extracted does not state the upstream rule that the
  originating controller must not receive its own event. Do not implement an
  uncitable behavior — regenerate the spec first (`spec-hap` skill; needs
  `external/` fetched) and follow what it yields, recording the outcome in the
  commit body. (`events.t` is insensitive either way: its writer is not
  subscribed.)

### 2.2 Host-side conformance test (unconditional)

- Extend `t/conformance/hap-http.t`: drive the `/characteristics` PUT handler on
  a subscribed mock session and assert a decryptable `EVENT/1.0` message reaches
  the subscriber's socket — and none reaches an unsubscribed one. This replaces
  the vacuous `can('queue_event')`-style assertions in `t/openhap/hap.t` that
  let the dead path count as §14 coverage.

### 2.3 Controller event-read hardening

- `next_event` (`lib/OpenHAP/Test/Controller.pm`): honor `OPENHAP_TEST_TIMEOUT`
  for the positive wait instead of the hardcoded 5 s default that callers
  override with literals.
- Fix the partial-frame weakness: `next_event` decrypts each `sysread` chunk in
  isolation, so an event frame split across reads returns undef and desyncs the
  nonce counter — accumulate and retry as `_round_trip` already does.
- Keep the negative probe (`next_event(2)` on the unsubscribed connection) short
  and fixed: it always runs to its full window, and it executes after the
  subscriber's event has already arrived, which bounds delivery latency
  observationally.

### 2.4 Make `events.t` fail cleanly

- Assert the event was received before decoding; on failure `diag` the raw
  buffered bytes and continue as a normal `not ok`, so the teardown
  (`remove_pairing`) always runs and later files start unpaired even when this
  file fails. Update the `tests =>` plan if assertions change.

## Deliverables

- Daemon wiring and conformance assertions; controller fixes; hardened
  `events.t`; `.pod` update for the changed `next_event` semantics; spec-gap
  resolution (regenerated spec or documented decision) for the delivery-scope
  rule.

## Acceptance criteria

- `events.t` (all 8 assertions; update the `tests =>` plan if the count changes)
  passes in the Integration workflow in suite order and no longer dies on a
  missed event — the clean-fail path is exercised host-side, where a miss can be
  induced deterministically.
- The new conformance assertions pass in `make test` on the host.
- The positive event wait is bounded by `OPENHAP_TEST_TIMEOUT`; the negative
  probe stays a short fixed window.
- `characteristics.t` still passes.
- `make check` stays green.
