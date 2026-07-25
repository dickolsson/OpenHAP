# Integration CI — Design

## Problem

The `Integration` workflow (`.github/workflows/integration.yml`) provisions an
OpenBSD guest under QEMU and runs `t/openhap/integration/*.t` on every push and
pull request. Standing the pipeline up exposed a chain of defects. The harness
defects (console/SSH addressing, install halt, SSH-key provisioning, bounded
shutdown, exit-code propagation) and the SRP performance defect are fixed; what
remains is to make the integration **suite** pass reliably in that environment
and keep it green.

Two properties of the CI environment shape the remaining failures:

1. **No hardware virtualization.** The `ubuntu-24.04-arm` runner has no
   `/dev/kvm`, so QEMU uses TCG software emulation — an order of magnitude
   slower than native, which is why CPU-bound crypto needed the GMP backend and
   why timing-sensitive tests are fragile.
2. **User-mode (SLIRP) networking.** The guest reaches the network through
   QEMU's user-mode stack, which does not forward link-local multicast — the
   transport mDNS relies on.

## Current state (baseline for this plan)

Run of commit `796b1c6` (GMP backend landed):

- Green: `environment`, `accessories`, **`characteristics` (16/16)**,
  `configuration`, `daemon`, `hap-protocol`, `hapctl`, `mqtt`.
- Failing: `pairing`, `tasmota-protocol`, `events`, `mdns`, `mdns-cleanup`.

The GMP fix worked: `characteristics.t` now completes full pair-setup,
pair-verify, and encrypted reads/writes. The remaining failures are no longer
about crypto speed.

## Failure taxonomy

| Class                   | Tests                                     | Root cause                                                                                                                                                             | Status                                                       |
| ----------------------- | ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| SRP performance         | (was `characteristics`, `pairing` crypto) | pure-Perl `Math::BigInt`; 3072-bit `bmodpow` ~2s native, far worse under TCG                                                                                           | **Fixed** — `use Math::BigInt try => 'GMP'` + GMP dependency |
| Pairing state isolation | `pairing`, `tasmota-protocol`             | `pair_setup` returns `kTLVError_Unavailable` (6) in the late-running tests, though both call `ensure_unpaired`; early tests (`characteristics`, `events`) pair cleanly | Open                                                         |
| Event delivery          | `events` (subtests 5–6)                   | a subscribed controller never receives the async `EVENT/1.0` notification; the body then decodes as undef and the test dies                                            | Open                                                         |
| mDNS availability       | `mdns`, `mdns-cleanup`                    | `mdnsd` is not running at test time (suspected SLIRP multicast limitation; not yet confirmed)                                                                          | Open                                                         |
| Provisioning noise      | (none failing)                            | `make install`'s `[ ! -e <glob> ]` guard errors when the glob matches multiple files                                                                                   | Open                                                         |

## Goals

1. The full `t/openhap/integration/*.t` suite passes in the workflow, on both a
   cold cache (fresh install) and a warm cache (reused disk).
2. Failures stay legible: no silent fallback that turns a broken environment
   into a slow-but-green or falsely-green run.
3. `t/openhap/integration/CLAUDE.md` rules hold — tests never `skip`; a missing
   prerequisite is a hard, diagnosed failure or a capability the harness
   genuinely provides.

## Non-goals

- Changing the HAP or MQTT protocol implementations beyond what a test failure
  proves is wrong.
- Restructuring the test tiers or conformance suite (owned by plan 001).
- Making the integration job fast; TCG is inherently slow and the generous
  timeouts stand.
- Real Apple-device or certified-controller interop.

## Strategy

Four independently shippable phases, each ending with a named set of integration
files green in CI. Order is by blast radius and independence:

- **Phase 1 — Pairing state isolation.** Root-cause the `kTLVError_Unavailable`
  returned to the late-running tests and make every pairing test start from a
  genuinely unpaired accessory. Unblocks the largest group and everything that
  pairs first.
- **Phase 2 — Event delivery.** Determine why the subscribed controller does not
  receive the `EVENT/1.0` push, fix it, and make the event read fail cleanly
  instead of dying on an undef body.
- **Phase 3 — mDNS under emulated networking.** Confirm why `mdnsd` does not
  survive to test time, then either make it run under the guest's network or
  give the harness a network mode that carries multicast — rather than weakening
  the tests.
- **Phase 4 — Cleanup and regression guards.** Fix the `make install` glob
  guard, guard against a silent regression to the pure-Perl bigint backend,
  remove the temporary diagnostics added while chasing these failures, and
  confirm cold- and warm-cache runs are both green.

## Contracts for the target state

- **Crypto backend.** `OpenHAP::SRP` and the controller SRP obtain the GMP
  `Math::BigInt` backend in the guest; a missing backend is a visible error, not
  a silent multi-minute pair-setup.
- **Pairing isolation.** After `ensure_unpaired`, `/pair-setup` from a fresh
  controller reaches M6 regardless of what earlier tests did.
- **Events.** A controller subscribed to a characteristic receives an
  `EVENT/1.0` notification after a value change, within the emulated-timing
  budget.
- **mDNS.** `mdnsd` is running and answering `mdnsctl` for the duration of the
  mDNS tests, on the interface `openhapd` advertises on.

Once a phase's acceptance criteria hold in CI, the code, tests, and
`t/openhap/integration/CLAUDE.md` are the source of truth; this plan records
intent at the time of writing.
