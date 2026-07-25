# Phase 2 — Event delivery

With pairing fixed (Phase 1) and GMP in place, `events.t` reaches its event
assertions: subtests 1–4 pass (subscription accepted, second controller verifies
its session, value changed), but subtest 5
`[HAP-HTTP §14] EVENT/1.0 message received` fails and the test then dies:

```
malformed JSON string, neither array, object, number, string or atom,
at character offset 0 ... at t/openhap/integration/events.t line 74
```

So the subscribed controller never receives the asynchronous `EVENT/1.0`
notification, and the code then tries to JSON-decode an undef/empty body and
dies instead of failing the assertion cleanly.

## Tasks

### 2.1 Determine why the event is not received

- Confirm the daemon actually emits the event: change a value from a second
  connection (as the test does) and watch the daemon log / the subscriber
  socket. Establish whether the push is never sent, sent on the wrong
  connection, or sent but not read in time.
- Check the controller's event read path
  (`OpenHAP::Test::Controller::next_event` and the `inbuf` handling in
  `request`) for a timing or framing issue: under TCG the event may arrive after
  a short read window that is too tight.

### 2.2 Fix the delivery gap

- If it is a controller-side read/timing issue, extend the event wait using the
  same `OPENHAP_TEST_TIMEOUT` knob as the request path and ensure a back-to-back
  event framed after a response is not dropped.
- If the daemon does not push events to a subscribed session, fix the daemon
  (cite `spec/HAP-HTTP.md §14`) and add/extend a conformance test so the
  regression is caught host-side, not only in the VM.

### 2.3 Make the read fail cleanly

- `events.t` line ~74: never feed an undef/empty body to the JSON decoder;
  assert the event was received first and `diag` the raw bytes on failure, so a
  missed event is a clean `not ok`, not a `die`.

## Deliverables

- Fix in the controller and/or daemon event path; hardened `events.t`.
- If a daemon bug is found, a host-side conformance assertion covering it.

## Acceptance criteria

- `events.t` (8/8) passes in the Integration workflow on both cold and warm
  cache, and does not die on a missing event.
- No new flakiness: the event wait is bounded by `OPENHAP_TEST_TIMEOUT`, not a
  fixed short sleep.
- `make check` stays green.
