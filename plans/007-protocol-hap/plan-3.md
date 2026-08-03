# Phase 3 — Pairing, session, and the store contract

This phase moves the pairing state machines and the session codec, defines the
store contract, and deletes every piece of package-level mutable state.

## Tasks

### 3.1 Define the store contract

- Document the twelve store methods in a `Protocol/HAP/Store.pod` reference:
  names, arguments, return values, and the c# increment rule — the mutating
  pairing methods increment the configuration number themselves, as
  `OpenHAP::Storage` does today. A store that skips the increment, or an engine
  that adds one on top, breaks c# in opposite directions.
- Write `Protocol::HAP::Store::Memory`: the contract over plain hashes, no
  files, including the increment rule. Tests and embedders start here.
- `OpenHAP::Storage` already provides the twelve methods; it stays in OpenHAP
  and keeps its on-disk layout. Add a `t/openhap/storage.t` subtest that asserts
  `can` for every contract method, so drift fails loudly.

### 3.2 Move OpenHAP::Pairing to Protocol::HAP::Pairing

- `git mv`, rename the package, retarget imports to
  `Protocol::HAP::{TLV,SRP, Crypto,PIN}`.
- Delete the package globals `$pairing_in_progress`, `$pairing_session_id`, and
  `$failed_auth_attempts`. They become instance state. Two `Pairing` objects in
  one process must not share a lock or a counter.
- `clear_pairing_state` and `reset_auth_attempts` become instance methods.
  Update the callers in `OpenHAP::HAP`.
- Rename the `storage` constructor argument to `store`, matching the contract
  name. The argument is required: the counter rule of [HAP-Pairing §8] needs
  persistence, and a silent in-memory fallback would fail open.
- The instance restores the attempt counter from the store at construction and
  persists every change, exactly as the global does today. The limit survives
  restarts and a rebuilt instance over the same store.
- Add the `logger` argument, defaulting to the null logger.

### 3.3 Move OpenHAP::Session to Protocol::HAP::Session

- `git mv`, rename the package, retarget the crypto import.
- Delete the `socket` member and the `$next_id` package counter. The session id
  becomes a required `id` constructor argument, allocated by `OpenHAP::HAP` from
  an instance counter.
- `OpenHAP::HAP` files each connection in a map keyed by the session id: the
  session and its socket together. A fileno index resolves reads to the session
  id. The kernel reuses descriptors; session ids never repeat — the same
  reasoning the current `$next_id` comment records.
- Add the `logger` argument.
- Update `OpenHAP::HAP`: `shutdown` and `send_event` read the socket from the
  connection map, not from the session.

### 3.4 Tests

- Move `t/openhap/pairing.t` and `session.t` to `t/protocol/`, rewritten over
  `Protocol::HAP::Store::Memory` instead of a temporary directory.
- Add a `t/protocol/pairing.t` subtest: two `Pairing` instances hold independent
  locks and counters.
- Update every test that names the deleted API. The full list today:
  `t/conformance/hap-pairing.t`, `hap-encryption.t`, `hap-tlv8.t`, `hap-http.t`,
  `hap-pairing-exchange.t`, `hap-encryption-exchange.t`, `t/openhap/hap.t`, and
  `t/openhap/test-controller.t`. The acceptance grep is the authority, not this
  list.
- These are rewrites where they touch deleted API, not import swaps:
  `Session->new` loses `socket` and requires `id`; `storage` becomes `store`;
  the class-method `clear_pairing_state` resets between subtests become calls on
  the pairing instance. The exchange tests keep their in-process transport over
  `$hap->_dispatch` in this phase; phase 4 replaces that transport.
- Spec citations do not change; `make spec-coverage` proves it.

## Deliverables

- `lib/Protocol/HAP/Pairing.pm`, `Session.pm`, `Store/Memory.pm`, with `.pod`
  sidecars and `Store.pod`.
- `t/protocol/pairing.t`, `t/protocol/session.t`.
- Updated `OpenHAP::HAP`, `OpenHAP::Test::Controller`, conformance imports.

## Acceptance criteria

- `make check` passes.
- `grep -r 'OpenHAP::Pairing\|OpenHAP::Session' lib bin t` finds nothing.
- `grep -rn '^our ' lib/Protocol/` shows `@ISA` and constants only — no mutable
  package variables.
- The two-instance independence subtest passes.
- `Protocol::HAP::Session` holds no socket: the word `socket` does not appear in
  the module.
