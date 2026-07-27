# Phase 1 — Pairing state isolation

`pairing.t` and `tasmota-protocol.t` fail with `pair_setup error: 6`
(`kTLVError_Unavailable`) on every attempt, including the wrong-PIN case. Static
review has settled why; this phase fixes it and locks the fix in.

## Root cause (established by code reading; confirm, don't rediscover)

- `ensure_unpaired` (`lib/OpenHAP/Test/Integration.pm`) checks and unlinks
  `/var/db/openhapd/pairings`, but the daemon persists pairings to `pairings.db`
  (`lib/OpenHAP/Storage.pm`, same `db_path`). Nothing ever creates a file named
  `pairings`, so the `-s` guard is always false and the stop/wipe/restart body
  has never executed — the helper is, and always has been, a no-op.
- The pairing that trips the late files leaks from `events.t`, which dies at its
  event assertion (line 74, fixed in phase 2) before its `remove_pairing`
  teardown. The daemon's already-paired check runs before any SRP processing and
  returns error 6 to every `method=0` M1 while `pairings.db` is non-empty
  (`lib/OpenHAP/Pairing.pm`) — which is why even wrong-PIN attempts see 6 rather
  than `kTLVError_Authentication`.
- `pairing.t` fails in isolation too: its own test 3 pairs, and the mid-file
  `ensure_unpaired` calls before tests 8 and 9 no-op, so those assertions and
  the teardown fail even on a clean disk.
- Refuted hypotheses (do not spend time here): a stale or concurrent pair-setup
  session returns `kTLVError_Busy` (7), never 6, and the pair-setup lock is
  per-process state, released on connection close and by any daemon restart. No
  server-side pairing change is needed for this failure class — the daemon's
  `spec/HAP-Pairing.md` §2.4 behavior is correct as-is. If the confirmation run
  contradicts any of this, stop and re-plan rather than patching forward.

## Tasks

### 1.1 Confirm the diagnosis (cheap)

- In one failing CI or local-VM run, capture `/var/db/openhapd/pairings.db` and
  the daemon log around a failing M1; confirm the file is non-empty and the log
  shows the already-paired rejection. This is confirmation of a known cause, not
  discovery.

### 1.2 Fix `ensure_unpaired`

- Point it at the real pairings file, and make "unpaired" content-based: after
  its first save the daemon always leaves comment headers in `pairings.db`, so a
  size check would bounce the daemon on every call (slow under TCG) — parse for
  non-comment entries instead.
- Wipe every pairing artifact — pairings and `auth_attempts`, unconditionally,
  checking the unlink return values — with the daemon verifiably stopped before
  the wipe and verifiably up afterwards.
- Update `lib/OpenHAP/Test/Integration.pod` for the changed semantics.

### 1.3 Post-condition that can actually fail

- After `ensure_unpaired`, probe pairing state with `POST /identify`: 204 when
  unpaired, 400 with `{"status":-70401}` when still paired (`spec/HAP-HTTP.md`
  §3 — identify only works when unpaired). Fail loudly on the paired answer.
- An unauthenticated `GET /accessories` cannot serve here: 470 means "no
  verified session" and is returned identically in both pairing states.
  `hapctl status` is also unusable today (its pairing readout is broken — see
  design non-goals).

### 1.4 Start clean regardless of history

- Provisioning removes `/etc/openhapd.conf` "to ensure fresh installation for
  testing" but preserves `/var/db/openhapd` (as does `make uninstall`), so a
  warm-cached disk carries the previous run's pairing state into file 1. Have
  `scripts/vm-provision` remove the pairing state (`pairings.db`,
  `auth_attempts` — keep the accessory identity keys) so every run starts
  unpaired even on a reused disk.
- `pairing.t` hygiene: close the raw M1 probe's socket right after test 2
  instead of leaving it registered until teardown. The daemon bounce already
  releases the pair-setup lock; this only removes the lingering connection.

## Deliverables

- Fixes in `lib/OpenHAP/Test/Integration.pm` (+ its `.pod`),
  `scripts/vm-provision`, and `t/openhap/integration/pairing.t`.
- Root-cause note in the commit body distinguishing the harness bug (the no-op
  wipe) from the seeding test bug (`events.t` dying before teardown, owned by
  phase 2).

## Acceptance criteria

- `pairing.t` (all 18 assertions; update the `tests =>` plan if the
  post-condition adds any) and `tasmota-protocol.t` (11/11) pass in the
  Integration workflow in suite order, and `pairing.t` also passes in isolation
  in a local VM run.
- `characteristics.t` still passes, and `events.t` still pairs cleanly and fails
  no earlier than its event assertions (assertions 1–4 pass) — its full pass is
  phase 2's criterion.
- `make check` stays green.
