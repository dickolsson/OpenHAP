---
name: openhapd
description:
  Run and debug the openhapd daemon during development. Use when running the
  daemon in the foreground, validating a configuration file, or debugging
  startup, logging, or mDNS registration problems.
---

# Run and Debug the Daemon

## Objective

Run `bin/openhapd` against a development configuration and diagnose startup or
runtime problems.

## Workflow

1. Validate the configuration without starting:

   ```sh
   bin/openhapd -n -c /path/to/openhapd.conf
   ```

2. Run in the foreground with debug logging (logs to stderr instead of syslog):

   ```sh
   bin/openhapd -f -v -c /path/to/openhapd.conf
   ```

3. In the test VM, run it as the real service and watch syslog:

   ```sh
   fuguvm ssh 'rcctl restart openhapd'
   fuguvm ssh 'tail -f /var/log/daemon'
   ```

## Debugging notes

- Startup ordering in `bin/openhapd` is delicate: it daemonizes and takes
  `/var/run/openhapd.pid` as root, prepares `/var/db/openhapd`, drops to
  `_openhap`, reopens the log, and registers mDNS. Symptoms like silent syslog
  or missing mDNS advertisements usually trace back to changes in this order.
- The PID file stays root-owned and the daemon never removes it. A leftover file
  after a stop is by design; `hapctl status` reads it and reports "not running"
  because the PID is stale.
- Use the `hapctl` skill to inspect a running installation.

## References

- `openhapd(8)` — options and daemon behavior:
  `mandoc man/openhap/openhapd.8 | less`
- `openhapd.conf(5)` — configuration file format:
  `mandoc man/openhap/openhapd.conf.5 | less`
- `fuguvm(1)` in the FuguBSD/FuguVM repository — VM lifecycle
