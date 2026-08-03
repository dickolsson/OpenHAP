# Phase 2 — OpenHAP becomes App::OpenHAP

This phase moves the daemon into `App::`, and gives three modules a name that
says what they do. The product is still called OpenHAP, and the daemon is still
`openhapd`. Prose that names the product does not change. Package names, file
paths, and test names do.

The phase depends on phase 1: the modules import `Fugu::` names.

## Tasks

### 2.1 Move the namespace

- `mkdir lib/App`, then `git mv lib/OpenHAP lib/App/OpenHAP`. Rename the package
  statement in each module, and in each `.pod` sidecar `=head1 NAME` line.
- Rewrite every `use`, `require`, and fully qualified call.
- `App::OpenHAP::Tasmota::*` and `App::OpenHAP::Test::Integration` keep their
  leaf names.

### 2.2 OpenHAP::Server becomes App::OpenHAP::Host

- `git mv lib/App/OpenHAP/Server.pm lib/App/OpenHAP/Host.pm`, and the `.pod`
  with it.
- The name states the job: the module hosts `Protocol::HAP::Server`. Two modules
  in one tree must not both be `Server`.
- Rewrite the sidecar abstract:
  `App::OpenHAP::Host - the host of the Protocol::HAP engine`.
- Users: `bin/openhapd`, `t/openhap/server.t`, and the comments in
  `t/protocol/server.t`.

### 2.3 OpenHAP::Storage becomes App::OpenHAP::Store::File

- `mkdir lib/App/OpenHAP/Store`, then `git mv` the module and its sidecar into
  it as `File.pm` and `File.pod`.
- The name states the contract and the medium. The module implements
  `Protocol::HAP::Store` in a file, and it pairs with
  `Protocol::HAP::Store::Memory`.
- The twelve contract methods do not change. This is a rename, not a rewrite.
- Users: `bin/openhapd` and `t/openhap/storage.t`.

### 2.4 OpenHAP::DeviceLoader becomes App::OpenHAP::Devices

- `git mv` the module and its sidecar. `Loader` names a mechanism; the module
  holds the configured devices.
- Users: `bin/openhapd`, `bin/hapctl`, and `t/openhap/device-loading.t`.

### 2.5 Write the two missing sidecars

- `lib/App/OpenHAP/Tasmota/Base.pod` and `Lightbulb.pod` do not exist. The
  documentation rule in the root `CLAUDE.md` requires a sidecar for every module
  outside `lib/Fugu/`.
- `Base.pod` documents the constructor arguments, the MQTT topic contract, and
  the methods that a subclass overrides. `Lightbulb.pod` documents the
  capability flags and the brightness and color characteristics.
- This phase already rewrites the header of both files, so the cost is the
  documentation alone.

### 2.6 Retarget the callers

- `bin/openhapd`: `use OpenHAP::DeviceLoader` and `use OpenHAP::Server` become
  `App::OpenHAP::Devices` and `App::OpenHAP::Host`. The `Storage` constructor
  call becomes `App::OpenHAP::Store::File`.
- `bin/hapctl`: one import line.

### 2.7 Move and retarget the tests

- `git mv t/openhap/server.t t/openhap/host.t` and
  `git mv t/openhap/storage.t t/openhap/store-file.t`. The tier directory keeps
  its name: it is named after the product, not the namespace.
- `t/openhap/device-loading.t` and `t/openhap/tasmota.t` keep their names.
- `mkdir -p t/lib/App`, then `git mv t/lib/OpenHAP t/lib/App/OpenHAP`, and
  rename the `OpenHAP::TestMock::MQTT` package. Retarget the four
  `t/conformance/mqtt-*.t` files that load it.
- Retarget the six `t/conformance/hap-*.t` files and the 17 files under
  `t/openhap/integration/` that name an `OpenHAP::` module.
- `t/protocol/boundary.t` matches `^(?:Fugu|FuguVM|OpenHAP)\b` after phase 1.
  The pattern becomes `^(?:Fugu|FuguVM|App)\b`. `FuguVM` needs its own
  alternative until phase 3, because `^Fugu\b` does not match `FuguVM`.
- `t/CLAUDE.md`: the `OpenHAP::TestMock::MQTT` example in the conformance
  section.

### 2.8 Build, install, and CI

- `Makefile`: `install`, `package`, and `uninstall` name `$(LIBDIR)/OpenHAP`,
  `/OpenHAP/Tasmota`, and `/OpenHAP/Test`. Each gains the `App/` level, and
  `install -d $(DESTDIR)$(LIBDIR)/App` comes first. The `Store/` subdirectory
  needs the same treatment as `Protocol/HAP/Store/`: a directory rule and a copy
  rule.
- `scripts/integration`: the tarball carries `lib/OpenHAP/Test/`, and the guest
  copy targets `site_perl/OpenHAP/`. Both become the `App/OpenHAP` path, and the
  copy needs `mkdir -p` for the new parent.
- `.github/workflows/integration.yml`: `lib/OpenHAP/**.pm` becomes
  `lib/App/OpenHAP/**.pm`, in the push list and the pull-request list.

### 2.9 Update the documentation

- Root `CLAUDE.md`: the namespace list, the `lib/OpenHAP/` row in Layout, and
  the module names in it.
- `t/web/site.t`: the `^(?:OpenHAP|FuguVM|Protocol)::` match that finds module
  manual pages. `App::OpenHAP::Host.3p.html` must match after this phase.
- `README.md`, `INSTALL.md`, `TODO.md`, `web/index.body.html`, and
  `t/openhap/integration/CLAUDE.md`: every mention of an `OpenHAP::` module.
  Mentions of the product OpenHAP stay as they are.

## Deliverables

- `lib/App/OpenHAP/` with `Host.pm`, `Devices.pm`, `Store/File.pm`,
  `Tasmota/*.pm`, and `Test/Integration.pm`, each with a `.pod` sidecar.
- `t/openhap/host.t`, `t/openhap/store-file.t`, and
  `t/lib/App/OpenHAP/TestMock/MQTT.pm`.
- Updated `Makefile`, `scripts/integration`,
  `.github/workflows/integration.yml`, `bin/openhapd`, `bin/hapctl`,
  `t/protocol/boundary.t`, `t/web/site.t`, and the documentation files.

## Acceptance criteria

- `make check` passes.
- `grep -rn 'OpenHAP::' --exclude-dir=.git --exclude-dir=plans . | grep -v 'App::OpenHAP::'`
  finds nothing.
- `grep -rn 'OpenHAP::Server\|OpenHAP::Storage\|OpenHAP::DeviceLoader' --exclude-dir=.git --exclude-dir=plans .`
  finds nothing.
- `make install DESTDIR=...` into an empty directory installs
  `$(LIBDIR)/App/OpenHAP/Store/File.pm`, and no `$(LIBDIR)/OpenHAP` path.
- Every `.pm` under `lib/App/OpenHAP/` has a `.pod` beside it.
- `make integration` passes, or its failure is unrelated to this phase and is
  recorded.
- No alias, no `@ISA` bridge, and no compatibility module carries an old name.
