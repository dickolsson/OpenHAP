# Phase 5 — Controller and the documentation pass

This phase completes the library with the controller side, retargets the
conformance suite to it, and finishes the documentation. After it, `OpenHAP`
contains only product code.

## Tasks

### 5.1 Merge the SRP controller role

- Move the client-side computation from `OpenHAP::Test::Controller::SRP` into
  `Protocol::HAP::SRP`, next to the accessory role. One module holds both sides
  of the exchange; the conformance vectors exercise them against each other.
- Delete `OpenHAP::Test::Controller::SRP`.

### 5.2 Create Protocol::HAP::Controller

- Move `OpenHAP::Test::Controller` to `Protocol::HAP::Controller`: pair-setup,
  pair-verify, session encryption, and plain and encrypted requests.
- The controller is the documented sans-IO exception: a blocking convenience
  client that owns its TCP socket. Embedders with an event loop use the codec
  modules directly.
- Add the `logger` argument like every other class; delete any `FuguLib::Log`
  use.
- Write the `.pod` sidecar, including one complete pair-and-read example — the
  shortest path for a new implementer to a working controller.
- Delete `OpenHAP::Test::Controller`.

### 5.3 Retarget the tests

- Move `t/openhap/test-controller.t` to `t/protocol/controller.t`.
- Update the conformance suite to `Protocol::HAP::Controller`:
  `hap-pairing-exchange.t`, `hap-encryption-exchange.t`, and any other file that
  imports the test controller.
- Where an exchange test can run sans-IO — controller codec against engine
  `output` capture — prefer that form. No socket-based conformance flow exists
  today; add exactly one, against a listening `OpenHAP::Server`, to cover the
  blocking client itself.

### 5.4 Documentation pass

- Root `CLAUDE.md`: the namespace list gains `Protocol::` with a one-line
  concern statement; the Layout and Commands sections reflect `t/protocol/` and
  the final `lib/OpenHAP/` contents; the commit-scope list gains `protocol`.
- `README.md`: a short section states that the HAP protocol lives in
  `Protocol::HAP`, is host-neutral, and awaits a CPAN release; it points to
  `Protocol/HAP.pod`. No restatement of the pod.
- `t/CLAUDE.md`: the tier table row for `t/protocol/` gets its final wording;
  the shared-mock note keeps pointing at `t/lib/`.
- `TODO.md`: confirm the "Protocol::HAP CPAN release" section lists PAUSE
  registration of `Protocol-HAP`, `$VERSION` policy, distribution tooling, and
  the `spec/` redistribution-license review as release preconditions.
- Verify `web/` renders the new pods; adjust `t/web/site.t` expectations.

## Deliverables

- `lib/Protocol/HAP/Controller.pm` and its `.pod`; the SRP controller role in
  `Protocol::HAP::SRP`.
- `lib/OpenHAP/Test/Controller.pm` and `Controller/SRP.pm` deleted with their
  pods.
- Retargeted conformance suite; `t/protocol/controller.t`.
- Final `CLAUDE.md`, `README.md`, `t/CLAUDE.md`, `TODO.md`, and web updates.

## Acceptance criteria

- `make check` passes; `make spec-coverage` reports no stale citations.
- `grep -r 'OpenHAP::Test::Controller' lib bin t` finds nothing.
- `lib/OpenHAP/` contains exactly: `Server`, `Storage`, `DeviceLoader`,
  `Tasmota/*`, `Test/Integration` — the product, nothing generic.
- The controller pod example runs as written against a local `openhapd`.
- `make integration` passes in the VM.
