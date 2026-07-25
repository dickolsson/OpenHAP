# Integration CI — Design

## Problem

The `Integration` workflow (`.github/workflows/integration.yml`) provisions an
OpenBSD guest under QEMU and runs `t/openhap/integration/*.t` on pushes to main,
pull requests targeting main, and manual dispatch. Standing the pipeline up
exposed a chain of defects. The harness defects (console/SSH addressing, install
halt, SSH-key provisioning, bounded shutdown, exit-code propagation) and the SRP
performance defect are fixed; what remains is to make the integration **suite**
pass reliably in that environment and keep it green.

Two properties of the execution environment shape the remaining work:

1. **No hardware virtualization in CI.** The `ubuntu-24.04-arm` runner has no
   `/dev/kvm`, so QEMU uses TCG software emulation — an order of magnitude
   slower than native, which is why CPU-bound crypto needed the GMP backend and
   why timing-sensitive tests are fragile.
2. **User-mode (SLIRP) networking — everywhere, not only in CI.** The harness
   has exactly one network backend (`-netdev user` with hostfwd, built in
   `lib/OpenHVF/VM.pm`), so the guest's network is identical on a developer host
   and in CI. SLIRP does not carry multicast off-host, but nothing the suite
   asserts requires a packet to leave the guest — mDNS registration is local
   `mdnsctl` IPC against `/var/run/mdnsd.sock` — so SLIRP is not established as
   a cause of any current failure.

## Current state (baseline for this plan)

One run of commit `796b1c6` (GMP backend landed) — a single-run baseline, so
per-phase acceptance requires stable repetition (see plan-4):

- Green: `environment`, `accessories`, **`characteristics` (16/16)**,
  `configuration`, `daemon`, `hap-protocol`, `hapctl`, `mqtt`.
- Failing: `pairing`, `tasmota-protocol`, `events`, `mdns`, `mdns-cleanup`.

The GMP fix worked: `characteristics.t` completes full pair-setup, pair-verify,
and encrypted reads/writes. Static review of the tree has since root-caused the
pairing and event failures (taxonomy below); the mDNS failure still needs
runtime diagnosis.

## Failure taxonomy

| Class                   | Tests                                     | Root cause                                                                                                                                                                                                                                                                                                                                              | Status                                                       |
| ----------------------- | ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| SRP performance         | (was `characteristics`, `pairing` crypto) | pure-Perl `Math::BigInt`; 3072-bit `bmodpow` ~2s native, far worse under TCG                                                                                                                                                                                                                                                                            | **Fixed** — `use Math::BigInt try => 'GMP'` + GMP dependency |
| Pairing state isolation | `pairing`, `tasmota-protocol`             | **Root-caused (static):** `ensure_unpaired` checks/unlinks `/var/db/openhapd/pairings` but the daemon persists to `pairings.db` (`lib/OpenHAP/Storage.pm`) — the helper has never wiped anything. `events.t` dies before its unpair teardown, and the leaked pairing makes every later `method=0` M1 return `kTLVError_Unavailable` (6) before SRP runs | Open — fixed by phase 1                                      |
| Event delivery          | `events` (assertions 5–6)                 | **Root-caused (static):** the daemon never emits events — `queue_event` (`lib/OpenHAP/HAP.pm`) has no callers; the `/characteristics` PUT handler sets values without notifying, and the device path dead-ends in the bridge forwarder                                                                                                                  | Open — fixed by phase 2                                      |
| mDNS availability       | `mdns`, `mdns-cleanup`                    | `mdnsd` is down at test time and the tests' own restart fails. Unconfirmed; leading hypothesis: mdnsd exits shortly after every start and provisioning's point-in-time verify races green. SLIRP multicast is refuted as an explanation (all failing assertions are guest-local)                                                                        | Open — diagnosed and fixed by phase 3                        |
| Provisioning noise      | (none failing)                            | `make install`'s `[ ! -e <glob> ]` guard errors when the glob matches multiple files                                                                                                                                                                                                                                                                    | Open — fixed by phase 4                                      |

## Goals

1. The full `t/openhap/integration/*.t` suite passes in the workflow,
   repeatably, on both a cold cache (fresh install) and a warm cache (reused
   disk) — verified by the procedure phase 4 defines.
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
- Fixing `hapctl status`'s pairing readout (`bin/hapctl` calls Storage methods
  that do not exist, so it always prints "unknown") — a latent defect noted
  during review; it causes no test failure and is tracked separately.

## Strategy

Four independently shippable phases, each ending with a named set of integration
files green in CI. Order is by blast radius and independence:

- **Phase 1 — Pairing state isolation.** Fix the root-caused `ensure_unpaired`
  no-op (wrong filename), make the wipe authoritative and verified by a probe
  that can actually fail, and start each run from a clean state directory.
  Unblocks `pairing.t`/`tasmota-protocol.t` and immunizes the suite against any
  earlier file dying before its unpair teardown.
- **Phase 2 — Event delivery.** Wire the daemon's dead event-emission path into
  the write handlers, prove it host-side with a trigger-driven conformance test,
  and make the event read fail cleanly instead of dying on an undef body.
- **Phase 3 — mDNS in the test VM.** Diagnose at test time — with captured
  output — why `mdnsd` is down, fix the in-guest lifecycle cause, and treat any
  network-backend change as a separately planned last resort rather than
  weakening the tests.
- **Phase 4 — Cleanup, guards, and verification.** Fix the `make install` glob
  guard, gate the GMP backend with a hard environment assertion, make failure
  diagnostics reachable, define the cold/warm-cache procedure, and add a
  scheduled run so "green" stays observed.

## Contracts for the target state

- **Crypto backend.** `OpenHAP::SRP` and the controller SRP obtain the GMP
  `Math::BigInt` backend in the guest; a missing backend is a hard, visible
  integration failure (`environment.t`), not a silent multi-minute pair-setup.
- **Pairing isolation.** After `ensure_unpaired`, the accessory is verifiably
  unpaired (`POST /identify` returns 204) and `/pair-setup` from a fresh
  controller reaches M6 regardless of what earlier tests did — or died doing.
- **Events.** A controller subscribed to a characteristic receives an
  `EVENT/1.0` notification after a value change from another connection, within
  the emulated-timing budget; emission is exercised host-side by a conformance
  test that drives the write handler, not the emitter directly.
- **mDNS.** `mdnsd` is running and answering `mdnsctl` for the duration of the
  mDNS tests, on the interface its flags configure.

Once a phase's acceptance criteria hold in CI, the code, tests, and
`t/openhap/integration/CLAUDE.md` are the source of truth; this plan records
intent at the time of writing.
