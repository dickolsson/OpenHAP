---
name: integration-tests
description:
  Run and debug the VM-based integration test suite. Use when asked to run
  integration tests, or to diagnose why an integration test fails. Requires QEMU
  (installed by make deps-develop) or an OpenBSD host.
---

# Run Integration Tests

## Objective

Run the end-to-end test suite in `t/openhap/integration/` against a real,
provisioned OpenBSD system and diagnose failures.

## Workflow

1. Run the full suite (provisions the VM, installs the current tree, runs all
   tests):

   ```sh
   make integration
   ```

2. To iterate on a single test without re-provisioning:

   ```sh
   bin/openhvf ssh 'cd /tmp && export OPENHAP_INTEGRATION_TEST=1 && \
       prove -I/usr/local/libdata/perl5/site_perl -v t/openhap/integration/daemon.t'
   ```

3. On an OpenBSD host with OpenHAP installed, skip the VM:

   ```sh
   export OPENHAP_INTEGRATION_TEST=1
   prove -l -v t/openhap/integration/
   ```

## Debugging failures

```sh
bin/openhvf ssh 'rcctl check openhapd && echo running || echo stopped'
bin/openhvf ssh 'tail -50 /var/log/daemon | grep openhapd'
bin/openhvf ssh 'hapctl -c /etc/openhapd.conf check'
```

Common causes:

- `OPENHAP_INTEGRATION_TEST` not set — export it before running.
- Daemon will not start — check `/etc/openhapd.conf` is valid, the `_openhap`
  user exists, and `/var/db/openhapd` permissions.
- MQTT tests fail — mosquitto not installed or not started
  (`rcctl start mosquitto`).
- mDNS tests fail — mdnsd not installed, not started, or its flags name a
  nonexistent interface (the openmdns package defaults to `em0`; mdnsd exits
  fatally on an unknown interface). Check `rcctl get mdnsd` and set the flags to
  the guest's real interface — `rcctl enable mdnsd` first, since rcctl refuses
  to set flags on a disabled daemon. The test helpers emit captured rcctl/syslog
  diagnostics when mdnsd will not stay up.

## CI verification procedure

The Integration workflow (`.github/workflows/integration.yml`) runs the suite in
an OpenBSD VM on pushes to main, PRs, a weekly schedule, and `workflow_dispatch`
against any branch. "Green" means repetition, not one run: **three consecutive
green workflow runs, at least one cold-cache and one warm-cache**, with wall
clock recorded against the job's 180-minute budget.

The workflow caches exactly one path, `~/.cache/openhvf`, keyed
`openhvf-v<N>-<arch>-<hash>`. `.openhvf` is ephemeral — openhvf rebuilds the
state directory from the cache on every run, so nothing depends on a previous
run's state. Two things live in that cache:

- the **installed OpenBSD image**, invalidated by `.openhvfrc`, `install.exp`
  and `share/openhvf/cache-generation`;
- the **provisioning layer** (`make deps` inside the guest), saved as snapshot
  `deps-<hash>` and invalidated by `deps/OpenBSD.txt`, `scripts/deps.sh`, the
  `cpanfile`, and the deps layer of `scripts/vm_provision.sh`.

The workflow key hashes all of those. That is required, not tidy: the cache
post-step saves only on a primary-key **miss**, so an input the workflow key
cannot see would rotate a cached name, rebuild it, and discard the result on
every run.

Producing each cache state on demand:

- **Cold cache** (fresh OpenBSD install from the miniroot): bump the `v<N>`
  suffix in the `openhvf-v<N>-*` cache key in the workflow, or delete the cache
  with `gh cache delete` (or the repository's Actions → Caches UI), then
  dispatch a run.
- **Warm cache**: re-run after a green run. The cache saves only when the job
  succeeds, so no warm cache exists until the suite first passes end-to-end.

On a warm run the log must show `Guest dependencies already present`, not a
re-run of `make deps`. Check the log, not the exit status: every provisioning
step is idempotent, so a broken cache still produces a green suite — just a slow
one. Compare job wall clock against the 180-minute budget.

See `openhvf(1)` for the cache layout, its invalidation inputs, and the `cache`
and `snapshot` subcommands.

## References

- `t/openhap/integration/CLAUDE.md` — test philosophy and how to write new
  integration tests
- `openhvf` skill — VM lifecycle and troubleshooting
- `lib/OpenHAP/Test/Integration.pod` — test helper module API
