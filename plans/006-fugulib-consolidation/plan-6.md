# Phase 6 — Control socket and hapctl

This phase gives `hapctl` a live channel to the running daemon.
`FuguLib::Control` carries requests over the phase 1 Imsg framing on a UNIX
socket; `openhapd` answers them from process state. This retires the
guess-from-files status logic, which is broken today.

## Tasks

### 6.1 FuguLib::Control

- One module, two packages in one file, per house style:
  - `FuguLib::Control` (server): `new(path => $socket, log => ...)`,
    `register($command, sub ($args) {...})`, and EventLoop integration — the
    listener and each accepted client register as fd handlers.
  - `FuguLib::Control::Client`: `new(path => ...)`, `request($command, $args)`
    returning the decoded reply or undef with `error`; distinguishes "socket
    absent" from "request failed".
- Payloads are JSON (JSON::PP, core); the transport is `FuguLib::Imsg` with
  `peerid` correlation from phase 1.
- An imsg frame carries at most ~16 KB of payload. A reply larger than one frame
  spans several frames with a continuation flag in the imsg type; the client
  reassembles by `peerid`. A `devices` reply can exceed one frame, so this is in
  scope, with a documented total-reply cap.
- The server creates the socket under a `umask 0177` guard, so it is mode 0600
  from birth; it removes a stale socket before `bind` and the live one on
  shutdown. It refuses oversized requests. External input is untrusted: unknown
  commands and malformed payloads get an error reply, never a die.

### 6.2 openhapd serves the socket

- Socket path: `/var/run/openhapd/control.sock` by default; a `control`
  directive in `openhapd.conf` overrides it, and `control off` disables the
  server. `Privdrop->prepare_statedir` (phase 1) creates `/var/run/openhapd`
  while still root — OpenBSD clears `/var/run` at boot — with owner `_openhap`
  and mode 0700, so the dropped daemon can bind and unlink the socket, and the
  directory mode is the outer access boundary.
- Commands and their policy live in `bin/openhapd` and `OpenHAP::HAP`: `status`
  (uptime, paired state, pairing count, config number, mDNS state, MQTT state)
  and `devices` (the loaded accessory list). There is no command that echoes
  configuration values: `openhapd.conf` carries `hap_pin` and `mqtt_pass`, and
  no reply may carry a secret.
- Replies carry no secrets: no keys, no setup code, no passwords, no pairing
  LTPKs.
- Sandbox updates: unveil the socket directory `rwc` — bind and unlink both
  create and remove directory entries; the `unix` pledge promise is already
  present.

### 6.3 hapctl rewrite

- `bin/hapctl` moves onto `FuguLib::CLI` with commands `check`, `status`, and
  `devices`. `check` stays what it is today — offline config validation through
  `FuguLib::Config` — because the integration tests and the operator workflow
  drive it.
- `status` asks the daemon over `FuguLib::Control::Client`. When the socket is
  absent, it falls back to `FuguLib::Pidfile` and says which method answered.
- This retires two live defects: `status` calls methods that do not exist on
  `OpenHAP::Storage`, so the pairing branch is unreachable; and the constructor
  argument mismatch makes a read-only status command create `/var/db/openhapd`.
  `hapctl` stops opening the storage directory at all.

### 6.4 Documentation and tests

- New `man/fugulib/Control.3p` documenting both packages; extend `MAN3P`.
- `man/openhap/hapctl.8`: rewritten command reference, the live-versus-file
  status distinction, and the socket path.
- `man/openhap/openhapd.8`: the control socket in FILES; the `control` directive
  cross-reference.
- `man/openhap/openhapd.conf.5`: the `control` directive; add it to the shipped
  example `share/openhap/examples/openhapd.conf.sample` too.
- New `t/fugulib/control.t` (server and client over a temporary socket, bad
  input, oversized frames, multi-frame replies). The existing
  `t/openhap/integration/hapctl.t` and `t/openhap/integration/configuration.t`
  update for the new output and keep driving `check`; a new integration test
  drives `hapctl status` and `devices` against the daemon in the VM.
- Update `web/fugulib.body.html` for the new module, and the command notes in
  `.claude/skills/hapctl/SKILL.md` (it documents `status` reading
  `/var/db/openhapd` directly, which stops being true).

## Deliverables

- `lib/FuguLib/Control.pm`, `man/fugulib/Control.3p`, `t/fugulib/control.t`
- Reworked `bin/hapctl`; updated `bin/openhapd`, `lib/OpenHAP/HAP.pm` (+ `.pod`)
- Updated `man/openhap/{hapctl.8,openhapd.8,openhapd.conf.5}`,
  `share/openhap/examples/openhapd.conf.sample`, `Makefile`,
  `web/fugulib.body.html`, `.claude/skills/hapctl/SKILL.md`
- New integration test under `t/openhap/integration/`; updated
  `t/openhap/integration/{hapctl,configuration}.t`

## Acceptance criteria

- `make check` is green; `mandoc -Tlint` passes on the new and changed pages.
- Against a running daemon, `hapctl status` reports live pairing state and
  device count; with the daemon stopped, it reports "not running" from the PID
  file and says so.
- `hapctl status` as an unprivileged user cannot reach the socket (directory
  mode 0700, socket mode 0600) and reports a permission error, not a crash — the
  integration test runs it via `su(1)` to a non-root user. `hapctl status` never
  creates files or directories, proven by a directory scan before and after the
  run.
- A malformed or oversized control request gets an error reply and the daemon
  stays up (fail closed, no die).
- The integration tier proves the socket appears after privilege drop with owner
  `_openhap` and disappears on clean shutdown.
