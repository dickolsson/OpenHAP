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

2. Show what the running daemon is doing:

   ```sh
   bin/hapctl status
   ```

3. List the devices:

   ```sh
   bin/hapctl devices
   ```

4. Against the test VM, run the installed copy:

   ```sh
   bin/fuguvm ssh 'hapctl status'
   bin/fuguvm ssh 'hapctl -c /etc/openhapd.conf check'
   ```

`status` and `devices` ask the daemon over `/var/run/openhapd/control.sock`.
Read the output line that names the source: with no socket, the report falls
back to `/var/run/openhapd.pid` and the configuration file, and says so. The
socket is mode 0600 in a directory of mode 0700, both owned by `_openhap`, so
a user who is neither root nor `_openhap` always gets the fallback.

`-s <socket>` reaches a daemon whose `control` directive names another path.
`hapctl` opens no other file, and it creates nothing.

## References

- `hapctl(8)` — full command reference: `mandoc man/openhap/hapctl.8 | less`
- `openhapd` skill — running and debugging the daemon
