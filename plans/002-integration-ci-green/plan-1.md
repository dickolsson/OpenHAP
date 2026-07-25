# Phase 1 — Pairing state isolation

`pairing.t` and `tasmota-protocol.t` fail with `pair_setup error: 6`
(`kTLVError_Unavailable`) even though both call `ensure_unpaired` in setup. The
early-running `characteristics.t` and `events.t` pair cleanly, so the accessory
_can_ pair from a clean state; the late-running tests cannot. This phase finds
why and makes every pairing test deterministic.

## Hypotheses to confirm first

Do not fix blind — the run log shows every `/pair-setup` in the failing files
returns `6`, including the wrong-PIN case, which means the accessory believes it
is already paired (or a pair-setup is already in progress). Candidates:

- `ensure_unpaired` (`lib/OpenHAP/Test/Integration.pm`) only wipes when
  `-s pairings_file`; a pairing persisted elsewhere (e.g. in-memory across the
  stop/start, or a second state file) survives it.
- `pairing.t`'s raw M1 probe (test 2) opens a pair-setup session; the stop/start
  meant to release it does not, and the server rejects the next M1 with
  `Unavailable`. (Does not explain `tasmota-protocol.t`, which has no probe — so
  this is at most a second, additive cause.)
- The daemon does not reset a stale/incomplete pair-setup session, so once one
  is left dangling every later attempt is `Unavailable` until restart.

## Tasks

### 1.1 Reproduce and localize

- Run the two failing files in isolation and in suite order in a local VM
  (`make integration`, now fast with GMP) to see whether order alone triggers
  it.
- Capture `/var/db/openhapd/pairings` and the daemon log around a failing
  `pair_setup` to see the accessory's paired/in-progress state at M1.

### 1.2 Make `ensure_unpaired` authoritative

- Ensure it removes every persisted pairing artifact (pairings, any
  in-progress/session state) and that the daemon reloads a clean state — verify
  the daemon is actually stopped before the unlink and fully up after.
- Add a post-condition check: after `ensure_unpaired`, an unauthenticated
  `GET /accessories` returns 470 (unpaired), failing loudly if not.

### 1.3 Fix the server side if it is at fault

- If the daemon returns `Unavailable` because of a stale in-progress pair-setup
  rather than an established pairing, reset a prior incomplete session when a
  new M1 arrives (per HAP: a fresh M1 starts a new session), citing
  `spec/HAP-Pairing.md`. Keep the correct `Unavailable` when a real admin
  pairing already exists.

### 1.4 Harden the tests

- `pairing.t`: after the raw M1 probe, guarantee the session is released before
  the controller flow (explicit reset, not only a daemon bounce).
- Keep assertions spec-cited; do not weaken them to pass.

## Deliverables

- Root-cause note (in the PR description or commit body) distinguishing test bug
  vs. daemon bug.
- Fixes in `lib/OpenHAP/Test/Integration.pm` and/or the daemon pairing code
  and/or the two test files.

## Acceptance criteria

- `pairing.t` (18/18) and `tasmota-protocol.t` (11/11) pass in the Integration
  workflow, in suite order, on both cold and warm cache.
- `characteristics.t` and `events.t` still pass (no regression from changes to
  shared `ensure_unpaired`).
- `make check` stays green.
