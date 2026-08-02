# Phase 2 — Foundation modules

This phase adds seven new FuguLib modules with man pages and tests. No consumer
changes; the modules ship unused and the conversions follow in phases 3 and 4.
Each module merges the strongest existing implementation of its concern, as
mapped in the design.

All modules follow the phase 1 conventions: `new(%args)`, named invocants, `die`
for programming errors, `undef` plus `error` for recoverable failures,
`log => $logger` with the `FuguLib::Log->default` fallback.

## Tasks

### 2.1 FuguLib::File

Class methods over paths; no object state.

- `read($path)` / `write($path, $data, mode => ...)` — slurp and spew; the mode
  applies to the open, before any byte is written.
- `write_atomic($path, $data, mode => ...)` — temp file plus `rename` in the
  same directory.
- `read_json($path)` / `write_json($path, $ref, mode => ...)` — JSON::PP with
  the same atomic, mode-first discipline. This kills the
  `FuguVM::ImageCache::_write_json` window where a secret is world-readable.
- `ensure_dir($path)` — refuse symlinks, refuse non-directories, `make_path`
  with a sanitized error (from `FuguVM::State::_ensure_dir`).
- `expand_tilde($path)` — one copy instead of three.
- `share_path($relative)` — resolve a shipped data file against the install
  root; one strategy instead of the three in `Expect`, `Image`, `ImageCache`.
- `atomic_dir($target, $code)` — build in a `.tmp.$$` sibling, publish by
  rename, sweep leftovers; from `FuguVM::ImageCache`, with the `END` and
  signal-cleanup guards.
- `valid_name($string)` — safe path-component check (length, `/`, NUL), from
  `FuguVM::State` and `ImageCache::valid_snapshot_name`.

### 2.2 FuguLib::Util

- `bounded($seconds, $code)` — `alarm` guard; one copy for the two admitted
  duplicates in `FuguVM::VM` and `OpenHAP::MQTT`.
- `wait_until($timeout, $interval, $code)` — bounded poll; replaces the three
  hand-rolled TCP/port/SSH wait loops. Honors `FuguLib::Signal` interruption.
- `format_size($bytes)` — human-readable bytes, from `FuguVM::CLI`.

### 2.3 FuguLib::Crypto

- `random_bytes($n)` — `/dev/urandom` with short-read and failure checks (the
  `FuguVM::Util` copy checks neither).
- `random_password($n)` — URL-safe base64 over `random_bytes`.
- Signature and AEAD wrappers, moved from `OpenHAP::Crypto`: `ed25519_keypair`,
  `ed25519_sign`, `ed25519_verify`, `x25519_keypair`, `x25519_shared_secret`,
  `hkdf_sha512`, `chacha20poly1305_encrypt`, `chacha20poly1305_decrypt`.
- The Crypt::* modules load lazily per function group with a clear failure
  message; `random_bytes` and `random_password` stay core-Perl.
- The RFC 5054 SRP group constants do not move here; they are HAP policy and go
  to `OpenHAP::SRP` in phase 4.

### 2.4 FuguLib::Config

One parser for the OpenBSD-style grammar, replacing three.

- Accepts `key value` and `key = value`; strips quotes; skips comment and blank
  lines.
- Blocks: `<type> <arg> ... {` up to `}`; one nesting level, as today.
- Both views: `blocks($type)` returns the ordered list (the OpenHAP device case)
  and `block($type, $name)` returns the named entry (the FuguVM case).
- `get($key, $default)` for top-level values; `bool($key, $default)` accepting
  yes/no, true/false, on/off, 1/0.
- Errors carry file and line: unreadable file and malformed line both return
  undef with `error` set. Today OpenHAP ignores bad lines silently; the design
  says fail closed.
- `find_project_root($marker)` — walk up to the directory holding the marker
  file, from `FuguVM::Config`.

### 2.5 FuguLib::Store

A file-backed JSON state store; the generic half of `FuguVM::State` and
`OpenHAP::Storage`.

- `new(path => $file, mode => 0600)`, `load` (tolerates a missing or corrupt
  file), `save` (atomic via `FuguLib::File`).
- `get($key)`, `set($key, $value)` with save; `increment($key)` for counters
  (the `c#` and auth-attempt cases).
- No PID logic and no subprocess logic; `Pidfile` and the callers own those.

### 2.6 FuguLib::CLI

The dispatch skeleton shared by `fuguvm` and `hapctl`.

- `new(name => ..., commands => {...}, options => {...})`; each command declares
  its options, usage line, and code.
- `run(@argv)`: parse global options once, dispatch, parse command options — the
  block `FuguVM::CLI` repeats five times.
- Exit-code constants: `EXIT_SUCCESS`, `EXIT_ERROR`, `EXIT_INVALID_ARGS`,
  `EXIT_CONFIG_ERROR`, `EXIT_TIMEOUT`. Domain codes stay in the applications;
  today `FuguVM::CLI` and `FuguVM::VM` define the same numbers twice.
- Usage and help generation to stdout; diagnostics go to the logger on stderr.
  Command data output stays on stdout (the `snapshot list --names` contract).

### 2.7 FuguLib::JSONSocket

The newline-delimited JSON client duplicated by QMP and QGA.

- `new(path => $socket, timeout => $s, greeting => 0|1)`; `connect` reads the
  greeting when asked (QMP) and skips it otherwise (QGA).
- `request($hashref)` returns the decoded response or undef with `error`.
- `read_line` keeps the wall-clock deadline and the buffered-remainder handling
  of the current copies; `disconnect`; `is_connected`.

### 2.8 Documentation and build

- New pages: `man/fugulib/{File,Util,Crypto,Config,Store,CLI,JSONSocket}.3p`;
  extend `MAN3P` in the `Makefile`.
- New tests: `t/fugulib/{file,util,crypto,config,store,cli,jsonsocket}.t`.
  Crypto tests skip gracefully when Crypt::* modules are absent.
- Update `web/fugulib.body.html`: the module list grows and the "nine modules,
  only core Perl" sentence becomes "core Perl at load time; some modules load
  optional CPAN libraries on use".

## Deliverables

- `lib/FuguLib/{File,Util,Crypto,Config,Store,CLI,JSONSocket}.pm`
- `man/fugulib/{File,Util,Crypto,Config,Store,CLI,JSONSocket}.3p` and the
  `Makefile` `MAN3P` additions
- `t/fugulib/{file,util,crypto,config,store,cli,jsonsocket}.t`
- Updated `web/fugulib.body.html`

## Acceptance criteria

- `make check` is green with the new modules present but unconsumed;
  `mandoc -Tlint` passes on the seven new pages.
- `t/fugulib/config.t` parses fixtures for both grammars: an OpenHAP-style
  device list and a FuguVM-style named-VM file, through the same parser.
- `t/fugulib/file.t` proves `write_json` never exposes a secret: the file has
  its final mode before it has content.
- `t/fugulib/store.t` proves `load` survives a corrupt file and `save` is atomic
  (no partial file after a simulated failure).
- FuguLib still loads with core Perl only: a test walks `lib/FuguLib` and
  compiles every module without CPAN modules installed, or skips where the
  environment cannot express that.
