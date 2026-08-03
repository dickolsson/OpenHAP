# Phase 2 — OpenHAP becomes App::OpenHAP

This phase moves the daemon into `App::`, and gives three modules a name that
says what they do. The product is still called OpenHAP, and the daemon is still
`openhapd`.

The phase depends on phase 1. Phase 3 depends on this one.

## Tasks

### 2.1 Move the namespace

- `mkdir lib/App`, then `git mv lib/OpenHAP lib/App/OpenHAP`. Rename the package
  statement in each module, and the `=head1 NAME` line of each `.pod` sidecar.
- Rewrite every `use`, `require`, and fully qualified call.
- `App::OpenHAP::Tasmota::*` and `App::OpenHAP::Test::Integration` keep their
  leaf names.

### 2.2 OpenHAP::Server becomes App::OpenHAP::Host

- `git mv lib/App/OpenHAP/Server.pm lib/App/OpenHAP/Host.pm`, and the `.pod`
  with it.
- The name states the job: the module hosts `Protocol::HAP::Server`. Two modules
  in one tree must not both be `Server`.
- Users: `bin/openhapd`, `t/openhap/server.t`, and the comments in
  `t/protocol/server.t`.

### 2.3 OpenHAP::Storage becomes App::OpenHAP::Store::File

- `mkdir lib/App/OpenHAP/Store`, then `git mv` the module and its sidecar into
  it as `File.pm` and `File.pod`.
- The name states the contract and the medium. The module cannot live in
  `Protocol::HAP::Store::File`, because it uses `Fugu::File` and the layering
  rules forbid that direction. Say so in the sidecar.
- The twelve contract methods do not change. This is a rename, not a rewrite.
- Users: `bin/openhapd` and `t/openhap/storage.t`.
- `lib/Protocol/HAP/Store.pod:11` names `OpenHAP::Storage` in prose. It is a
  shipped `.pod` that `make web` publishes, and `t/protocol/boundary.t` reads
  `.pm` files only, so nothing else catches it.

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
- The two new sidecars change the sidecar count that `t/web/site.t` asserts at
  line 206. Task 2.9 handles the regex on the other side of that assertion.

### 2.6 Retarget the callers

- `bin/openhapd`: the `use OpenHAP::DeviceLoader` and `use OpenHAP::Server`
  lines, and the `Storage` constructor call.
- `bin/openhapd:380` is
  `push @perl_dirs, $script_lib if -d "$script_lib/OpenHAP";`. This is a
  filesystem probe on a directory name, not a package name, so no grep for
  `OpenHAP::` finds it. After the move the test is false forever, the checkout's
  `lib/` never joins the unveil list, and a daemon started from a checkout loses
  read access to its own modules under pledge. The lazy
  `require Net::MQTT::Simple` on the MQTT reconnect path then dies inside the
  sandbox. Change the probe to `"$script_lib/App/OpenHAP"`.
- `bin/hapctl`: one import line.

### 2.7 Move and retarget the tests

- `git mv t/openhap/server.t t/openhap/host.t` and
  `git mv t/openhap/storage.t t/openhap/store-file.t`. The tier directory keeps
  its name: it is named after the product, not the namespace.
- `mkdir -p t/lib/App`, then `git mv t/lib/OpenHAP t/lib/App/OpenHAP`, and
  rename the `OpenHAP::TestMock::MQTT` package. Retarget the four
  `t/conformance/mqtt-*.t` files that load it.
- Retarget the six `t/conformance/hap-*.t` files and the 17 files under
  `t/openhap/integration/` that name an `OpenHAP::` module.
- `t/protocol/boundary.t` needs both patterns changed in this phase:
  - Direction one, line 73, is `^(?:Fugu|FuguVM|OpenHAP)\b` after phase 1. It
    becomes `^(?:Fugu|FuguVM|App)\b`. `FuguVM` needs its own alternative until
    phase 3, because `^Fugu\b` does not match `FuguVM`.
  - Direction two, line 104, is `^(?:Protocol::HAP|OpenHAP)\b`. It becomes
    `^(?:Protocol::HAP|App)\b`, and the subtest name at line 93 follows. Without
    this the design's rule that `Fugu::` never uses `App::` stops being
    enforced, and no acceptance grep can see it: the literal text is `OpenHAP)`,
    with no trailing colons.
- Add the retired names to `t/scripts/namespaces.t`: `OpenHAP::`,
  `OpenHAP::Server`, `OpenHAP::Storage`, `OpenHAP::DeviceLoader`, and the path
  form `lib/OpenHAP/`.
- `t/CLAUDE.md`: the `OpenHAP::TestMock::MQTT` example.

### 2.8 Build, install, and CI

- `Makefile`: `install`, `package`, and `uninstall` name `$(LIBDIR)/OpenHAP`,
  `/OpenHAP/Tasmota`, and `/OpenHAP/Test`. Each gains the `App/` level, and
  `install -d $(DESTDIR)$(LIBDIR)/App` comes first. The `Store/` subdirectory
  needs a directory rule and a copy rule.
- `uninstall` must not do `rm -rf $(DESTDIR)$(LIBDIR)/App`. `App/` is a shared
  parent that holds other distributions, such as `App::cpanminus`. Remove
  `App/OpenHAP` and then `rmdir` the parent, which fails harmlessly when the
  parent is not empty. Fix the same fault on the line above it:
  `rm -rf $(LIBDIR)/Protocol` deletes every other `Protocol::` distribution on
  the machine today.
- `scripts/integration`: the tarball carries `lib/OpenHAP/Test/`, and the guest
  copy targets `site_perl/OpenHAP/`. Both become the `App/OpenHAP` path, and the
  copy needs `mkdir -p` for the new parent.
- `scripts/vm-provision`: purge `site_perl/OpenHAP` on the guest before
  `make install`, for the reason phase 1 gives.
- `.github/workflows/integration.yml`: `lib/OpenHAP/**.pm` becomes
  `lib/App/OpenHAP/**.pm`, in the push list and the pull-request list.

### 2.9 Update the website and the manuals

- `web/mkindex.sh:149` is
  `emit_group 'OpenHAP modules' modules lib/OpenHAP/ '' "$@"`. The prefix stops
  matching, and `emit_group` emits nothing when nothing matches, so the whole
  group and its `id="modules"` anchor vanish from `manuals.html`.
  `web/index.body.html` links `manuals.html#modules`, and `t/web/site.t`
  requires that anchor to resolve. Line 60 names the path in a comment.
- `t/web/site.t:203` matches `^(?:OpenHAP|FuguVM|Protocol)::` and asserts one
  page per sidecar at line 206. This phase sets it to
  `^(?:App|FuguVM|Protocol)::`. `FuguVM` must stay until phase 3, because 11
  FuguVM sidecars are still in the tree. Line 97 also names `lib/OpenHAP` in an
  assertion description.
- `man/openhap/hapctl.8:170` prints `Class: OpenHAP::Tasmota::Thermostat` in a
  sample session. `bin/hapctl:182` prints `$device->{class}` verbatim, and
  `Devices` sets that field to the package name, so the daemon's output changes
  with the rename. Update the manual.

### 2.10 Update the project documentation

- Root `CLAUDE.md`: the namespace list, and the `lib/OpenHAP/` row in Layout.
- `TODO.md` holds 18 references in the path form `lib/OpenHAP/...`. A grep for
  `OpenHAP::` does not match them.
- `t/openhap/integration/CLAUDE.md`: the module names in the rules.

## Deliverables

- `lib/App/OpenHAP/` with `Host.pm`, `Devices.pm`, `Store/File.pm`,
  `Tasmota/*.pm`, and `Test/Integration.pm`, each with a `.pod` sidecar.
- `t/openhap/host.t`, `t/openhap/store-file.t`, and
  `t/lib/App/OpenHAP/TestMock/MQTT.pm`.
- Updated `Makefile`, `scripts/integration`, `scripts/vm-provision`,
  `.github/workflows/integration.yml`, `bin/openhapd`, `bin/hapctl`,
  `t/protocol/boundary.t`, `t/scripts/namespaces.t`, `t/web/site.t`,
  `web/mkindex.sh`, `man/openhap/hapctl.8`, `lib/Protocol/HAP/Store.pod`, and
  the documentation files.

## Acceptance criteria

- `make check` passes, and so do `make prettier` and `make web`.
- `t/scripts/namespaces.t` passes with the new retired names, and fails
  correctly on a planted `OpenHAP::Server` in a `.pod` line that also names a
  live module.
- `t/protocol/boundary.t` fails correctly on a planted `use App::OpenHAP::Host;`
  inside `lib/Fugu/`. Prove it once by hand.
- `make install DESTDIR=...` into an empty directory installs
  `$(LIBDIR)/App/OpenHAP/Store/File.pm`, and no `$(LIBDIR)/OpenHAP` path.
- `make uninstall DESTDIR=...` against a directory that also holds
  `$(LIBDIR)/App/Other.pm` and `$(LIBDIR)/Protocol/Other.pm` leaves both files
  in place.
- Every `.pm` under `lib/App/OpenHAP/` has a `.pod` beside it.
- `make integration` passes on a guest that was purged of the old install, and
  the unveil path list in `bin/openhapd` covers the checkout `lib/`.
