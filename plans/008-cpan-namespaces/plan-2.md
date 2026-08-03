# Phase 2 — OpenHAP becomes App::OpenHAP

This phase moves the daemon into `App::`, and gives four modules a name that
says what they do. The product is still called OpenHAP, and the daemon is still
`openhapd`.

The phase depends on phase 1. Phase 3 depends on this one.

## Tasks

### 2.1 Move the namespace

- `mkdir lib/App`, then `git mv lib/OpenHAP lib/App/OpenHAP`. Rename the package
  statement in each module, and the `=head1 NAME` line of each `.pod` sidecar.
- Rewrite every `use`, `require`, and fully qualified call.
- `App::OpenHAP::Test::Integration` and the four device classes keep their leaf
  names. `Tasmota::Base` does not: task 2.5 renames it.

### 2.2 OpenHAP::Server becomes App::OpenHAP::Host

- `git mv lib/App/OpenHAP/Server.pm lib/App/OpenHAP/Host.pm`, and the `.pod`
  with it.
- The name states the job: the module hosts `Protocol::HAP::Server`. Two modules
  in one tree must not both be `Server`.
- Users: `bin/openhapd`, `t/openhap/server.t`, and the comments in
  `t/protocol/server.t`.

### 2.3 OpenHAP::Storage becomes Protocol::HAP::Store::File

This task is the one rewrite in the effort. Land it in a commit of its own, so a
bisect separates it from the namespace move. Task 2.1 must not carry the module
into `lib/App/OpenHAP/` first: the old name and its replacement never exist
together, and a move to `App::` would be a name that this task deletes.

- `git mv lib/OpenHAP/Storage.pm lib/Protocol/HAP/Store/File.pm`, and the
  sidecar with it as `File.pod`. The directory already holds `Memory.pm`.
- The twelve contract methods keep their behavior, and the layout on disk does
  not change. Three host dependencies go, as the design describes:
  - `FuguLib::Log` becomes a `logger` argument, with
    `Protocol::HAP->null_logger` as the default.
  - `FuguLib::File` becomes private `_read`, `_write`, `_write_atomic`, and
    `_ensure_dir` methods over `Fcntl` and `File::Path`. `_write` takes the mode
    and applies it at the `sysopen`. A `chmod` after the write is a fault, not a
    style choice.
  - `FuguLib::Store` becomes a private JSON file over `JSON::PP`. Keep the two
    guarantees of `Fugu::Store`: `load` tolerates a missing and a corrupt file,
    and `save` writes through a temporary file and renames over the target.
- `Fcntl`, `File::Path`, and `JSON::PP` are core Perl, so `%DECLARED` in
  `t/protocol/boundary.t` needs no new entry. Prove that the test still passes.
- `db_path` becomes `path`, and `new` dies without it. The `/var/db/openhapd`
  default moves to `bin/openhapd`, beside the other path policy.
- Users: `lib/OpenHAP/Server.pm:78`, which becomes
  `Protocol::HAP::Store::File->new( path => ..., logger => Fugu::Log->default )`.
- `lib/Protocol/HAP/Store.pod:11` names `OpenHAP::Storage` as a production
  implementation elsewhere. It now names `Protocol::HAP::Store::File` as the
  file implementation in this distribution. It is a shipped `.pod` that
  `make web` publishes, and `t/protocol/boundary.t` reads `.pm` files only, so
  nothing else catches it.

### 2.4 OpenHAP::DeviceLoader becomes App::OpenHAP::Devices

- `git mv` the module and its sidecar. `Loader` names a mechanism; the module
  holds the configured devices.
- Users: `bin/openhapd`, `bin/hapctl`, and `t/openhap/device-loading.t`.

### 2.5 OpenHAP::Tasmota::Base becomes App::OpenHAP::Tasmota::Device

- `git mv lib/App/OpenHAP/Tasmota/Base.pm lib/App/OpenHAP/Tasmota/Device.pm`.
- `Base` names a role in the code, as `Loader` did. The class is a Tasmota
  device that is also a `Protocol::HAP::Accessory`: it owns the MQTT
  subscription, the availability state, and the power helpers.
- Users: the four device classes that inherit from it, `App::OpenHAP::Devices`,
  and `t/openhap/tasmota.t`.

### 2.6 Write the two missing sidecars

- `Tasmota/Device.pod` and `Tasmota/Lightbulb.pod` do not exist. The
  documentation rule in the root `CLAUDE.md` requires a sidecar for every module
  outside `lib/Fugu/`.
- `Device.pod` documents the constructor arguments, the MQTT topic contract, and
  the methods that a subclass overrides. `Lightbulb.pod` documents the
  capability flags and the brightness and color characteristics.
- The two new sidecars change the sidecar count that `t/web/site.t` asserts at
  line 206. Task 2.10 handles the regex on the other side of that assertion.

### 2.7 Retarget the callers

- `bin/openhapd`: the `use OpenHAP::DeviceLoader` and `use OpenHAP::Server`
  lines. The daemon now owns the `/var/db/openhapd` default, per task 2.3.
- `bin/openhapd:282` and the pledge comment at `bin/openhapd:296` to `:300` name
  `Storage` six times. The promises do not change: the same module makes the
  same calls under a new name. Only the name in the comments changes.
- `bin/openhapd:380` is
  `push @perl_dirs, $script_lib if -d "$script_lib/OpenHAP";`. This is a
  filesystem probe on a directory name, not a package name, so no grep for
  `OpenHAP::` finds it. After the move the test is false forever, the checkout's
  `lib/` never joins the unveil list, and a daemon started from a checkout loses
  read access to its own modules under pledge. The lazy
  `require Net::MQTT::Simple` on the MQTT reconnect path then dies inside the
  sandbox. Change the probe to `"$script_lib/App/OpenHAP"`.
- `bin/hapctl`: one import line.

### 2.8 Move and retarget the tests

- `git mv t/openhap/server.t t/openhap/host.t`. The tier directory keeps its
  name: it is named after the product, not the namespace.
- `git mv t/openhap/storage.t t/protocol/store-file.t`. The test follows its
  module into the protocol tier. Keep the file-specific assertions here: the
  layout on disk, the counters that survive a restart, and the mode of every
  file that the store creates. Nothing asserts the mode of `accessory_ltsk` or
  `pairings.db` today, and both must be 0600 from their first byte.
- Add `t/protocol/store.t`: the twelve contract methods of
  `Protocol/HAP/Store.pod`, driven over `Store::Memory` and `Store::File` from
  one loop. It replaces the `can` loop at the end of `t/openhap/storage.t`,
  which proved that the methods exist and never that they agree. Above all it
  proves the increment rule that `Store.pod` calls a rule with no slack: each of
  `save_pairing`, `remove_pairing`, and `remove_all_pairings` moves `c#` by one,
  in both implementations.
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
  `OpenHAP::Server`, `OpenHAP::Storage`, `OpenHAP::DeviceLoader`,
  `OpenHAP::Tasmota::Base`, and the path form `lib/OpenHAP/`.
- `t/CLAUDE.md`: the `OpenHAP::TestMock::MQTT` example.

### 2.9 Build, install, and CI

- `Makefile`: `install`, `package`, and `uninstall` name `$(LIBDIR)/OpenHAP`,
  `/OpenHAP/Tasmota`, and `/OpenHAP/Test`. Each gains the `App/` level, and
  `install -d $(DESTDIR)$(LIBDIR)/App` comes first. The store needs no new rule:
  the `lib/Protocol/HAP/Store/*` loops at `Makefile:137` and `Makefile:217`
  already cover it, and the comment at `Makefile:130` that the loop accepts zero
  files is now stale, because the directory holds two modules.
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

### 2.10 Update the website and the manuals

- `web/mkindex.sh:149` is
  `emit_group 'OpenHAP modules' modules lib/OpenHAP/ '' "$@"`. The prefix stops
  matching, and `emit_group` emits nothing when nothing matches, so the whole
  group and its `id="modules"` anchor vanish from `manuals.html`.
  `web/index.body.html` links `manuals.html#modules`, and `t/web/site.t`
  requires that anchor to resolve. Line 60 names the path in a comment.
- The store sidecar changes group. `web/mkindex.sh:150` already covers it with
  the `lib/Protocol/` prefix, so `Store/File.pod` leaves the `OpenHAP modules`
  group and joins `Protocol::HAP modules` with no edit. The total sidecar count
  does not change: the file moves, it does not appear.
- `t/web/site.t:203` matches `^(?:OpenHAP|FuguVM|Protocol)::` and asserts one
  page per sidecar at line 206. This phase sets it to
  `^(?:App|FuguVM|Protocol)::`. `FuguVM` must stay until phase 3, because 11
  FuguVM sidecars are still in the tree. Line 97 also names `lib/OpenHAP` in an
  assertion description.
- `man/openhap/hapctl.8:170` prints `Class: OpenHAP::Tasmota::Thermostat` in a
  sample session. `bin/hapctl:182` prints `$device->{class}` verbatim, and
  `Devices` sets that field to the package name, so the daemon's output changes
  with the rename. Update the manual.

### 2.11 Update the project documentation

- Root `CLAUDE.md`: the namespace list, and the `lib/OpenHAP/` row in Layout.
- `TODO.md` holds 18 references in the path form `lib/OpenHAP/...`. A grep for
  `OpenHAP::` does not match them.
- `t/openhap/integration/CLAUDE.md`: the module names in the rules.

## Deliverables

- `lib/App/OpenHAP/` with `Host.pm`, `Devices.pm`, `Tasmota/Device.pm`, the four
  device classes, and `Test/Integration.pm`, each with a `.pod` sidecar.
- `lib/Protocol/HAP/Store/File.pm` and `File.pod`, with no `Fugu::` import.
- `t/openhap/host.t`, `t/protocol/store-file.t`, `t/protocol/store.t`, and
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
  `$(LIBDIR)/Protocol/HAP/Store/File.pm`, and no `$(LIBDIR)/OpenHAP` path.
- `t/protocol/boundary.t` passes over the new `lib/Protocol/HAP/Store/File.pm`,
  and fails correctly on a planted `use Fugu::File;` inside it.
- `t/protocol/store.t` fails correctly when one implementation skips the
  increment in `remove_pairing`. Prove it once by hand, in each implementation.
- `t/protocol/store-file.t` asserts mode 0600 on `accessory_ltsk`,
  `pairings.db`, and `state.json`, and mode 0644 on `accessory_ltpk`.
- A paired daemon still starts: `make integration` covers this, and the store
  reads a directory that the previous run wrote.
- `make uninstall DESTDIR=...` against a directory that also holds
  `$(LIBDIR)/App/Other.pm` and `$(LIBDIR)/Protocol/Other.pm` leaves both files
  in place.
- Every `.pm` under `lib/App/OpenHAP/` has a `.pod` beside it.
- `make integration` passes on a guest that was purged of the old install, and
  the unveil path list in `bin/openhapd` covers the checkout `lib/`.
