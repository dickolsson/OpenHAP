# Phase 4 — OpenHAP conversion

This phase moves the generic OpenHAP modules into FuguLib, deletes the glue
modules, and removes the `$OpenHAP::logger` global. HAP wire behavior is
unchanged except one deliberate fix: the server frames requests by
`Content-Length` over a per-connection buffer.

## Tasks

### 4.1 The logger convention

- Delete the `$OpenHAP::logger` global (166 references). Library modules take
  `log => $logger` or call `FuguLib::Log->default`.
- `bin/openhapd` calls `FuguLib::Log->set_default(...)` at startup and after the
  privilege drop (`reopen`).
- Tests set a quiet default once through a small shared test helper instead of
  assigning a global in each file (34 test files assign it today).
- Library code never dies for a missing logger; `Test::Integration` drops its
  injected-logger workaround.

### 4.2 Move OpenHAP::MQTT to FuguLib::MQTT

- The module is generic already; it moves with the logger change applied.
- The `site_perl` `@INC` workaround stays, documented as OpenBSD packaging
  behavior; `Sandbox->perl_lib_dirs` (phase 1) covers the unveil side.
- The connect alarm guard becomes `FuguLib::Util::bounded`.
- `bin/openhapd` keeps the pre-unveil `require Net::MQTT::Simple` warm-up, now
  against the new module name.
- New `man/fugulib/MQTT.3p`; the `.pod` sidecar is deleted with the module;
  `t/openhap/mqtt.t` moves to `t/fugulib/mqtt.t`.

### 4.3 Move OpenHAP::HTTP to FuguLib::HTTP

- One codec replaces three: server-side `parse_request`, client-side
  `parse_response`, `build_request`, `build_response`, and
  `message_complete($buffer)` for `Content-Length` framing (the correct loop
  exists today only in the test clients, `Test::Controller` and
  `Test::Integration`; the server has none).
- The HAP-isms move out: status `470` and the default `Connection: keep-alive`
  become caller-supplied values in `OpenHAP::HAP`.
- `OpenHAP::HAP::_handle_client` gets a per-connection input buffer and consumes
  exactly one framed request per pass. Today one `sysread` is parsed as a whole
  message, so split or pipelined requests break. This is the one wire-behavior
  fix in this phase.
- The buffer is bounded: the server enforces a maximum request size (header
  block plus `Content-Length`) and closes the connection when a client exceeds
  it. Today the single 64 KB `sysread` bounds input implicitly; the buffered
  server must bound it explicitly, since unpaired clients reach `/pair-setup`.
  The limit is a `FuguLib::HTTP` argument; `OpenHAP::HAP` picks the value.
- `Test::Controller` and `Test::Integration` use the same codec; their two
  private HTTP parsers are deleted. The controller's independent crypto stays —
  the codec is transport, not oracle.
- New `man/fugulib/HTTP.3p`; `t/fugulib/http.t` covers framing (split,
  pipelined, oversized).

### 4.4 Crypto onto FuguLib::Crypto

- `OpenHAP::Crypto` is deleted. Every consumer moves to `FuguLib::Crypto` (phase
  2): `HAP` (identity generation), `Session`, `Pairing`, `SRP`,
  `Test::Controller`, and `Test::Controller::SRP`.
- The RFC 5054 3072-bit group constants move into `OpenHAP::SRP`; they are HAP
  policy, not a primitive. The conformance tests that read
  `$OpenHAP::Crypto::N_3072` follow them there.
- `bin/openhapd` calls `FuguLib::Crypto->preload` before it pledges: the promise
  set has no `prot_exec`, so no shared object may load after the pledge. The
  warm-up comment at `bin/openhapd:191-254` extends to say so.
- The HAP nonce and AAD conventions stay in `OpenHAP::Session`, as today.

### 4.5 OpenHAP::Storage onto FuguLib::Store and FuguLib::File

- The six small read/write accessors (three pairs: config number, config digest,
  auth attempts) and the flock/umask/chmod block become `FuguLib::Store` and
  `FuguLib::File` calls.
- `Storage` keeps what is HAP: the LTSK/LTPK key files, the pairings format
  (`controller_id:ltpk_hex:permissions`), and the rule that every pairing change
  increments `c#`.
- The on-disk layout under `/var/db/openhapd` is unchanged; a paired
  installation from before this phase still loads.

### 4.6 Delete OpenHAP::Config and OpenHAP::Daemon

- `bin/openhapd`, `bin/hapctl`, `DeviceLoader`, and `Test::Integration` parse
  configuration through `FuguLib::Config`; the device blocks use the ordered
  `blocks('device')` view. `Test::Integration`'s third parser is deleted.
- `OpenHAP::Daemon`'s pass-through shims die; two are already dead. The
  unveil-path inventory moves into `bin/openhapd` next to the pledge policy it
  belongs to; `perl_lib_dirs` already lives in `Sandbox`.
- `bin/hapctl` calls `FuguLib::Pidfile` directly for `status`.
- `Test::Integration` replaces `system('rcctl ...')` and log tailing shells with
  `FuguLib::Process->run`.

### 4.7 DeviceLoader: one table

- The three copies of the type/subtype table (`_is_supported_device`,
  `_instantiate_device`, `_device_type_name`) collapse into one declarative map
  entry per device class. Adding a device type means one line plus one `use`.
- Delete the unused `OpenHAP::DeviceLoader` import in `bin/hapctl`; it drags
  four Tasmota classes and JSON::XS into a CLI that reads config only.

### 4.8 Documentation

- Delete the `.pod` sidecars of removed modules
  (`Config,Crypto,Daemon,HTTP,MQTT`); update the sidecars of every changed
  OpenHAP module (`HAP`, `Storage`, `SRP`, `Session`, `DeviceLoader`,
  `Test::*`).
- New `man/fugulib/{MQTT,HTTP}.3p`; extend `MAN3P`.
- `man/openhap/openhapd.conf.5`: document the grammar as FuguLib::Config defines
  it — `key value` and `key = value` both parse, and malformed lines are now
  hard errors with file and line.
- `man/openhap/openhapd.8` and `hapctl.8`: no user-visible flag changes; verify
  FILES and DIAGNOSTICS.
- Update `web/fugulib.body.html`; check `README.md` and `INSTALL.md` for
  statements about module layout and correct them.
- Dependency manifests do not change: the same CPAN modules are required, and
  only their loading site moves.
- Test-file fates, stated so nothing dangles: `t/openhap/mqtt.t` moves to
  `t/fugulib/mqtt.t`; `t/openhap/http.t` folds into `t/fugulib/http.t`;
  `t/openhap/{config,crypto}.t` are deleted (their coverage lives in
  `t/fugulib/{config,crypto}.t`); `t/openhap/daemon.t` is deleted with the
  module, and its `unveil_paths` coverage follows the inventory into a
  `bin/openhapd` test or the integration tier.
- The five conformance files that call `OpenHAP::HTTP` and `OpenHAP::Crypto`
  (`hap-http.t`, `hap-pairing.t`, `hap-pairing-exchange.t`, `hap-encryption.t`,
  `hap-encryption-exchange.t`) migrate to the FuguLib names. Their spec
  citations and asserted bytes do not change.

## Deliverables

- `lib/FuguLib/{MQTT,HTTP}.pm` with pages and tests
- Deleted: `lib/OpenHAP/{Config,Crypto,Daemon,HTTP,MQTT}.pm` and their `.pod`
  sidecars
- Reworked `lib/OpenHAP/{HAP,Storage,SRP,Session,Pairing,DeviceLoader}.pm`,
  `lib/OpenHAP/Test/{Controller,Integration}.pm`, `bin/openhapd`, `bin/hapctl`,
  with sidecar updates
- Updated `t/openhap/*.t` and `t/conformance/*.t` (logger helper plus the
  call-site migration named in 4.8); moved and deleted tests per 4.8
- Updated `man/openhap/openhapd.conf.5`, `Makefile`, `web/fugulib.body.html`

## Acceptance criteria

- `make check` and `make spec-coverage` are green. The conformance tier passes
  with its call sites migrated; the cited behavior — pairing bytes, session
  encryption, TLV — is unchanged.
- `t/fugulib/http.t` proves a request split across two reads and two pipelined
  requests in one read are both handled, and an over-limit request closes the
  connection; `t/conformance` exercises the HAP server through the fixed path.
- A storage fixture in the current on-disk format is checked in under `t/`; the
  Storage tests load it and prove `c#` semantics are unchanged, so a paired
  installation from before this phase keeps working.
- Grep finds no `$OpenHAP::logger`, no `OpenHAP::Config`, `OpenHAP::Crypto`,
  `OpenHAP::Daemon`, `OpenHAP::HTTP`, or `OpenHAP::MQTT` references.
- `hapctl` no longer loads JSON::XS or any Tasmota class for `status`.
