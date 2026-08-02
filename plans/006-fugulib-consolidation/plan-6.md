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
- The server creates the socket with mode 0600 before `listen`, removes it on
  shutdown, and refuses oversized requests. External input is untrusted: unknown
  commands and malformed payloads get an error reply, never a die.

### 6.2 openhapd serves the socket

- Socket path: `/var/run/openhapd/control.sock` by default; a `control`
  directive in `openhapd.conf` overrides it, and `control off` disables the
  server. The parent directory is prepared by `Privdrop->prepare_statedir` so
  the socket is created after the drop.
- Commands and their policy live in `bin/openhapd` and `OpenHAP::HAP`: `status`
  (uptime, paired state, pairing count, config number, mDNS state, MQTT state),
  `devices` (the loaded accessory list), `config` (the running configuration
  values).
- Replies carry no secrets: no keys, no setup code, no pairing LTPKs.
- Sandbox updates: unveil the socket directory read-write; the `unix` pledge
  promise is already present.

### 6.3 hapctl rewrite

- `bin/hapctl` moves onto `FuguLib::CLI` with commands `status`, `devices`,
  `config`.
- `status` asks the daemon over `FuguLib::Control::Client`. When the socket is
  absent, it falls back to `FuguLib::Pidfile` and says which method answered.
- This retires two live defects: `status` calls methods that do not exist on
  `OpenHAP::Storage`, so the pairing branch is unreachable; and the constructor
  argument mismatch makes a read-only status command create `/var/db/openhapd`.
  `hapctl` stops opening the storage directory at all.
- `hapctl` keeps working without a running daemon for config validation (`-n`
  parity) through `FuguLib::Config`.

### 6.4 Documentation and tests

- New `man/fugulib/Control.3p` documenting both packages; extend `MAN3P`.
- `man/openhap/hapctl.8`: rewritten command reference, the live-versus-file
  status distinction, and the socket path.
- `man/openhap/openhapd.8`: the control socket in FILES; the `control` directive
  cross-reference.
- `man/openhap/openhapd.conf.5`: the `control` directive.
- New `t/fugulib/control.t` (server and client over a temporary socket, bad
  input, oversized frames) and `t/openhap/hapctl.t` growth for the fallback
  path; an integration test drives `hapctl status` against the daemon in the VM.
- Update `web/fugulib.body.html` for the new module.

## Deliverables

- `lib/FuguLib/Control.pm`, `man/fugulib/Control.3p`, `t/fugulib/control.t`
- Reworked `bin/hapctl`; updated `bin/openhapd`, `lib/OpenHAP/HAP.pm` (+ `.pod`)
- Updated `man/openhap/{hapctl.8,openhapd.8,openhapd.conf.5}`, `Makefile`,
  `web/fugulib.body.html`
- New integration test under `t/openhap/integration/`

## Acceptance criteria

- `make check` is green; `mandoc -Tlint` passes on the new and changed pages.
- Against a running daemon, `hapctl status` reports live pairing state and
  device count; with the daemon stopped, it reports "not running" from the PID
  file and says so.
- `hapctl status` as an unprivileged user cannot read the socket (mode 0600) and
  reports a permission error, not a crash; it never creates files or
  directories.
- A malformed or oversized control request gets an error reply and the daemon
  stays up (fail closed, no die).
- The integration tier proves the socket appears after privilege drop with owner
  `_openhap` and disappears on clean shutdown.
