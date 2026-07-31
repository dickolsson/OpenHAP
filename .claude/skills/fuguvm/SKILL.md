---
name: fuguvm
description:
  Drive fuguvm, the utility that installs and manages OpenBSD VMs under QEMU:
  bring a VM up or down, provision it, run commands over SSH, watch logs, and
  troubleshoot. Use when starting, provisioning, debugging, or scripting an
  OpenBSD VM, or when a fuguvm command fails.
---

# Operate an OpenBSD VM

## Objective

Drive an OpenBSD VM with `bin/fuguvm`: lifecycle, provisioning, ad-hoc commands,
and troubleshooting. In this repository the VM defined in `.fuguvmrc` is the one
the integration suite runs against, so the workflow below uses it; the commands
are not specific to that use.

## Workflow

1. Bring the VM up and wait until it accepts SSH:

   ```sh
   make vm-up                      # idempotent; wraps fuguvm up + wait
   ```

   or directly:

   ```sh
   bin/fuguvm up && bin/fuguvm wait --timeout=300
   ```

2. Install the current OpenHAP tree into the VM (build, copy, `make install`,
   enable services):

   ```sh
   make vm-provision
   ```

   Provisioning is two layers. The guest's packages and Perl modules
   (`make deps`) are cached as the fuguvm snapshot `deps-<hash>`, keyed on
   `deps/OpenBSD.txt`, `scripts/deps`, the `cpanfile`, and the deps layer of
   `scripts/vm-provision`; the OpenHAP install runs every time. A warm run
   prints `Guest dependencies already present` instead of re-running
   `make deps`. Print the key with `scripts/deps-key`.

3. Run ad-hoc commands in the VM:

   ```sh
   bin/fuguvm ssh 'rcctl restart openhapd'
   bin/fuguvm ssh 'tail -f /var/log/daemon'
   bin/fuguvm ssh 'uname -a'
   ```

4. For scripted console interaction (no SSH yet), run an expect script:

   ```sh
   bin/fuguvm expect share/fuguvm/expect/command.exp
   ```

## Troubleshooting

- `fuguvm status` prints the VM state, `ssh_port`, and `console_port`.
- "Not in a FuguVM project" — run from the repo root (the project is
  auto-discovered via `.fuguvmrc`) or pass `--project`.
- SSH failures after an unclean shutdown — `bin/fuguvm disk check`, then
  `bin/fuguvm disk repair` with the VM stopped.
- Start over from a clean slate: `bin/fuguvm destroy && make vm-provision`.
  `destroy` deletes the working disk only; the next `up` rebuilds it from the
  cached installed image, so this is a cheap factory reset rather than a
  reinstall.
- To force a real reinstall — when debugging the installer itself, or when a
  cached base is suspect — use `bin/fuguvm up --no-cache`, or drop the cached
  bases with `bin/fuguvm cache clear`. `bin/fuguvm cache list` shows what is
  cached and which entry the current configuration uses.
- On aarch64 hosts without hardware acceleration, pass `--emulate`.

## References

- `fuguvm(1)` — full command, option, and exit-code reference:
  `mandoc man/fuguvm/fuguvm.1 | less`
- `bin/fuguvm help` — quick usage
- `t/openhap/integration/CLAUDE.md` — running the integration suite in the VM
