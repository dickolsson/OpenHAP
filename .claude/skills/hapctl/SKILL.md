---
name: hapctl
description:
  Inspect a running OpenHAP installation with the hapctl control utility. Use
  when checking daemon status, validating configuration, or listing configured
  devices.
---

# Inspect with hapctl

## Objective

Query an OpenHAP installation — daemon state, pairing status, configuration
validity, and configured devices — with `bin/hapctl`.

## Workflow

1. Validate a configuration file:

   ```sh
   bin/hapctl -c /path/to/openhapd.conf check
   ```

2. Show daemon and pairing status (reads the PID file and pairing database):

   ```sh
   bin/hapctl status
   ```

3. List configured devices:

   ```sh
   bin/hapctl devices
   ```

4. Against the test VM, run the installed copy:

   ```sh
   bin/fuguvm ssh 'hapctl status'
   bin/fuguvm ssh 'hapctl -c /etc/openhapd.conf check'
   ```

Note: `status` reads `/var/db/openhapd` directly; as a non-root user, pairing
status may report as unknown.

## References

- `hapctl(8)` — full command reference: `mandoc man/openhap/hapctl.8 | less`
- `openhapd` skill — running and debugging the daemon
