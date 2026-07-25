# Phase 4 — Cleanup and regression guards

With Phases 1–3 landed the integration suite is green. This phase removes the
scaffolding added while chasing the failures and guards against silent
regressions, so a future change cannot quietly re-break what was fixed.

## Tasks

### 4.1 Fix the `make install` glob guard

- `Makefile`: `[ ! -e lib/OpenHAP/Test/*.pm ] || install ...` errors with
  `[: ...: unexpected operator/operand` when the glob matches more than one file
  (it now matches `Integration.pm` and others). Rewrite so the guard works with
  zero, one, or many matches (e.g. a `for` loop, or a `set --` on the glob and
  test `$#`), and produces no stderr noise. Confirm the `Test/` and
  `Test/Controller/` modules still install.

### 4.2 Guard the GMP backend in the guest

- The `try => 'GMP'` selection falls back silently to pure-Perl `Math::BigInt`,
  which under TCG reintroduces multi-minute pair-setups. Make the loss of GMP
  visible where it matters: e.g. an integration/environment assertion that
  `Math::BigInt->config->{lib}` is the GMP backend in the VM, or a daemon
  startup warning. Keep `make check` on hosts without GMP green (the guard is a
  warning/CI assertion, not a hard `require`).

### 4.3 Remove temporary diagnostics

- `scripts/vm_provision.sh`: drop the foreground-`mdnsd` diagnostic block once
  Phase 3 resolves mDNS, keeping only what a normal run needs.
- `.github/workflows/integration.yml`: keep the failure-only VM diagnostics step
  (it is cheap and useful) but prune anything made redundant.

### 4.4 Full-suite verification

- Confirm a **cold-cache** run (cache miss → fresh install) and a **warm-cache**
  run (reused disk) are both fully green — the warm path was rarely exercised
  while every change invalidated the disk cache.
- Confirm the workflow's `workflow_dispatch` path still runs against an
  arbitrary branch.

## Deliverables

- `Makefile` glob fix; GMP-presence guard; trimmed provisioning/workflow.

## Acceptance criteria

- `make install` runs with no stderr noise and installs all shipped modules.
- The Integration workflow is green end-to-end on cold and warm cache, and a
  missing GMP backend fails or warns visibly rather than silently slowing the
  run.
- `make check` stays green.
