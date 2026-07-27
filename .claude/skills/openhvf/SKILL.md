---
name: openhvf
description:
  Operate the openhvf QEMU VM harness used for OpenBSD integration testing:
  bring the VM up or down, provision it, run commands over SSH, watch logs,
  and troubleshoot. Use when starting, provisioning, debugging, or scripting
  the test VM, or when an openhvf command fails.
---

# Operate the Test VM

## Objective

Drive the OpenBSD test VM with `bin/openhvf` during development: lifecycle,
provisioning, ad-hoc commands, and troubleshooting.

## Workflow

1. Bring the VM up and wait until it accepts SSH:

   ```sh
   make vm-up                      # idempotent; wraps openhvf up + wait
   ```

   or directly:

   ```sh
   bin/openhvf up && bin/openhvf wait --timeout=300
   ```

2. Install the current tree into the VM (build, copy, `make install`, enable
   services):

   ```sh
   make vm-provision
   ```

   Provisioning is two layers. The guest's packages and Perl modules
   (`make deps`) are cached as the openhvf snapshot `deps-<hash>`, keyed on
   `deps/OpenBSD.txt`, `scripts/deps.sh`, the `cpanfile`, and the deps layer of
   `scripts/vm_provision.sh`; the OpenHAP install runs every time. A warm run
   prints `Guest dependencies already present` instead of re-running
   `make deps`. Print the key with `scripts/deps_key.sh`.

3. Run ad-hoc commands in the VM:

   ```sh
   bin/openhvf ssh 'rcctl restart openhapd'
   bin/openhvf ssh 'tail -f /var/log/daemon'
   bin/openhvf ssh 'uname -a'
   ```

4. For scripted console interaction (no SSH yet), run an expect script:

   ```sh
   bin/openhvf expect share/openhvf/expect/command.exp
   ```

## Troubleshooting

- `openhvf status` prints the VM state, `ssh_port`, and `console_port`.
- "Not in an OpenHVF project" — run from the repo root (the project is
  auto-discovered via `.openhvfrc`) or pass `--project`.
- SSH failures after an unclean shutdown — `bin/openhvf disk check`, then
  `bin/openhvf disk repair` with the VM stopped.
- Start over from a clean slate: `bin/openhvf destroy && make vm-provision`.
  `destroy` deletes the working disk only; the next `up` rebuilds it from the
  cached installed image, so this is a cheap factory reset rather than a
  reinstall.
- To force a real reinstall — when debugging the installer itself, or when a
  cached base is suspect — use `bin/openhvf up --no-cache`, or drop the cached
  bases with `bin/openhvf cache clear`. `bin/openhvf cache list` shows what is
  cached and which entry the current configuration uses.
- On aarch64 hosts without hardware acceleration, pass `--emulate`.

## References

- `openhvf(1)` — full command, option, and exit-code reference:
  `mandoc man/openhvf/openhvf.1 | less`
- `bin/openhvf help` — quick usage
- `integration-tests` skill — running the integration suite in the VM
