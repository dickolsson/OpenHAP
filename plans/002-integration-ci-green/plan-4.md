# Phase 4 — Cleanup, guards, and verification procedure

With Phases 1–3 landed the integration suite is green. This phase removes the
scaffolding added while chasing the failures, guards against silent regressions,
repairs the failure-diagnostics path, and defines the procedure that actually
verifies "green" — repeatably, on cold and warm caches.

## Tasks

### 4.1 Fix the `make install` glob guard

- `Makefile`: `[ ! -e lib/OpenHAP/Test/*.pm ] || install ...` errors with
  `[: ...: unexpected operator/operand` when the glob matches more than one file
  (it now matches `Controller.pm` and `Integration.pm`). Rewrite so the guard
  works with zero, one, or many matches (e.g. a `for` loop, or `set --` on the
  glob and test `$#`), and produces no stderr noise. Confirm the `Test/` and
  `Test/Controller/` modules still install.

### 4.2 Guard the GMP backend — hard failure, not a warning

- The `try => 'GMP'` selection falls back silently to pure-Perl `Math::BigInt`,
  which under TCG reintroduces multi-minute pair-setups — exactly the
  "slow-but-green" outcome design goal 2 forbids. A daemon log warning cannot
  guard this: integration tests never parse logs, and nothing reads the guest
  console on a green run.
- Add a hard assertion to `t/openhap/integration/environment.t` (which runs
  first) that `Math::BigInt->config->{lib}` is the GMP backend, updating its
  `tests =>` plan (10 → 11). `make check` on hosts without GMP is unaffected:
  the integration tier is not part of `make test`.
- Close the delivery hole: the guest heredocs in `scripts/vm_provision.sh` and
  `scripts/integration.sh` run without `set -e`, so a failed
  `pkg_add`/`make deps` still reports a provisioned guest. Make them fail fast
  and loudly.

### 4.3 Repair and trim diagnostics

- `scripts/integration.sh`: the failure log-capture block after the test heredoc
  is unreachable today — `set -e` aborts the script at the failing `vm_run`
  before `result=$?` runs. Restructure so the capture executes on failure, and
  extend it to include `/var/db/openhapd` contents (pairing state) and
  mdnsd/rcctl status alongside the daemon log.
- `.github/workflows/integration.yml`: gate the VM diagnostics step on
  `always() && !success()` so a `timeout-minutes` cancellation still runs it;
  correct the disk-cache comment (saving is gated on job success, not on the
  shutdown step); drop the foreground-`mdnsd` provisioning diagnostics once
  Phase 3 resolves mDNS, keeping only what a normal run needs.

### 4.4 Verification procedure and keep-it-green mechanism

- Document how to produce each cache state on demand, in the `integration-tests`
  skill: cold via a cache-version suffix in the disk-cache key (bump to
  invalidate) or `gh cache delete`; warm via a re-run after a green run (the
  cache saves only on success, so no warm cache exists until the suite first
  passes end-to-end).
- "Green" is repetition, not one run: three consecutive green workflow runs
  (dispatch re-runs count), at least one cold-cache and one warm-cache, with
  wall clock recorded against the job's 180-minute budget.
- Add a weekly `schedule:` trigger to the Integration workflow so regressions
  surface between pushes.
- Confirm the `workflow_dispatch` path still runs against an arbitrary branch.

## Deliverables

- `Makefile` glob fix; `environment.t` GMP assertion; fail-fast provisioning
  heredocs; reachable and extended failure diagnostics; corrected workflow
  comment; scheduled run; cache procedure documented in the `integration-tests`
  skill.

## Acceptance criteria

- `make install` runs with no stderr noise and installs all shipped modules.
- A missing GMP backend fails the suite loudly at `environment.t`, verified once
  by forcing the pure-Perl backend in a dispatch run.
- Failure diagnostics demonstrably print on a red run, verified once by a
  deliberately failed dispatch run.
- Three consecutive green Integration runs, including one cold-cache and one
  warm-cache run produced by the documented procedure, within the time budget.
- `make check` stays green.
