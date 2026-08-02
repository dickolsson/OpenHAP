# Phase 5 — Event loop

This phase extracts the select loop from `OpenHAP::HAP::run` into
`FuguLib::EventLoop` and restructures `run` as registrations. It gives the
daemon a real shutdown path. HAP endpoint behavior does not change.

## Tasks

### 5.1 FuguLib::EventLoop

- `new(log => ...)`; single-threaded, `IO::Select` based, no threads, per the
  project rules.
- Handles: `add_fd($fh, read => sub {...})` and `remove_fd($fh)`; the loop
  dispatches readable handles to their callbacks.
- Timers: `every($seconds, sub {...})` and `after($seconds, sub {...})` return
  timer handles; `cancel($handle)`. The select timeout derives from the next
  timer deadline, not from a hardcoded poll interval.
- Stop: `stop` method, plus optional integration with a `FuguLib::Signal` object
  (`signal => $sig`) so an interrupt flag ends the loop after the current pass.
- `run` loops until stopped; each pass is bounded and timing-tolerant, so tests
  stay resilient to scheduling variation.

### 5.2 OpenHAP::HAP::run becomes registrations

- The listener socket registers a read callback that accepts and registers the
  client socket; each client callback owns that connection's buffer and framing
  (from phase 4).
- The MQTT tick becomes `every($tick_interval, ...)`; the 30-second reconnect
  backoff becomes a timer instead of an epoch comparison.
- Event flushing (`flush_events`, HAP-HTTP coalescing) becomes an `after` timer
  scheduled on demand; the coalescing policy stays in `OpenHAP::HAP`.
- `while (1)` dies: the loop stops on the Signal interrupt flag, `run` returns,
  and `bin/openhapd` exits through the normal cleanup path instead of inside a
  signal handler.
- Key client sessions and event subscriptions by `fileno`, not by stringified
  references, so subscription purge is a delete, not a sweep.

### 5.3 Documentation and tests

- New `man/fugulib/EventLoop.3p`; extend `MAN3P`.
- New `t/fugulib/eventloop.t`: fd dispatch, timer ordering, `after` versus
  `every`, stop via signal flag; written against pipes, tolerant of timing
  variation.
- Update `lib/OpenHAP/HAP.pod` for the new `run` structure.
- `man/openhap/openhapd.8`: describe the clean shutdown (signals end the loop
  and cleanups run), replacing the exit-from-handler behavior.

## Deliverables

- `lib/FuguLib/EventLoop.pm`, `man/fugulib/EventLoop.3p`,
  `t/fugulib/eventloop.t`
- Reworked `lib/OpenHAP/HAP.pm` (+ `.pod`), `bin/openhapd`
- Updated `Makefile`, `man/openhap/openhapd.8`, `web/fugulib.body.html`

## Acceptance criteria

- `make check` and the conformance tier are green: pairing, encrypted sessions,
  characteristic reads and writes, and event delivery behave as before through
  the new loop.
- Event coalescing timing per HAP-HTTP holds under the timer implementation; the
  conformance tests that cite it pass unchanged.
- SIGTERM ends `openhapd` through the cleanup path: mDNS withdraws, the PID file
  is removed, and the exit is visible in the log — verified in the integration
  tier.
- MQTT keeps ticking and reconnecting with the same observable cadence (tick
  interval and backoff values unchanged).
- No `while (1)` remains in `lib/OpenHAP`.
