# Phase 5 — The leaf renames, and the documentation pass

This phase renames the four modules that no namespace move touches, and finishes
the documentation. After it, every module name in the repository says what the
module does, and no document names a namespace that no longer exists.

The phase depends on phases 1 to 3. It does not depend on phase 4.

## Tasks

### 5.1 Fugu::Util becomes Fugu::Timeout

- `Fugu::Util` holds three functions that share no idea: `bounded`,
  `wait_until`, and `format_size`. The name hides that.
- `git mv lib/Fugu/Util.pm lib/Fugu/Timeout.pm`. The module keeps `bounded` and
  `wait_until`, which are one idea: run something under a time limit.
- Users of the two: `Fugu::SSH`, `Fugu::MQTT`, `Fugu::Proxy`,
  `App::FuguVM::Guest`, and `App::FuguVM::QGA`.
- `git mv man/fugu/Util.3p man/fugu/Timeout.3p`, and rewrite it for the two
  functions. Update `MAN3P` in the `Makefile` and every `.Xr` that names the
  page.
- `git mv t/fugu/util.t t/fugu/timeout.t`.
- Add `Fugu::Util` to the retired list in `t/scripts/namespaces.t`. Tasks 5.2 to
  5.4 add `Fugu::Store`, `Fugu::MDNS`, `Protocol::HAP::PIN`, and
  `normalize_pin`.

### 5.2 Fugu::Store becomes Fugu::StateFile

- `git mv lib/Fugu/Store.pm lib/Fugu/StateFile.pm`, and
  `git mv man/fugu/Store.3p man/fugu/StateFile.3p`. Update `MAN3P` and every
  `.Xr` that names the page.
- The module is a small JSON state file with `load`, `save`, `get`, `set`,
  `increment`, and `delete`. Its own abstract says so.
- The rename also ends the three-`Store` problem. After it, `Store` in this tree
  means the `Protocol::HAP` persistence contract and its two implementations,
  and nothing else.
- Users: `Fugu::Proxy`, `App::OpenHAP::Store::File`, `App::FuguVM::State` and
  its `.pod`, `t/fugu/proxy.t`, and `t/fuguvm/proxy.t`.
- `git mv t/fugu/store.t t/fugu/statefile.t`.

### 5.3 Fugu::MDNS becomes Fugu::Mdnsd

- `git mv lib/Fugu/MDNS.pm lib/Fugu/Mdnsd.pm`, and
  `git mv man/fugu/MDNS.3p man/fugu/Mdnsd.3p`.
- The module implements no mDNS. It opens the `mdnsd(8)` control socket and
  sends `IMSG_CTL_*` messages over `Fugu::Imsg`. `connect`, `publish`,
  `publish_service`, `update_txt`, and `withdraw` are all control operations.
  The name claims a capability the module does not hold.
- `format_txt` stays, and its comment keeps the point that the join is mdnsd's
  format, not HAP's.
- The spec files keep their names. `spec/MDNS-Control.md` and
  `spec/MDNS-Imsg.md` document the protocol of mdnsd, not this module, and
  `make spec-coverage` maps `t/conformance/mdns-control.t` to the first by stem.
- Users: `bin/openhapd`, `App::OpenHAP::Host`, `t/fugu/mdns.t`,
  `t/conformance/mdns-control.t`, and the integration tests.
- `git mv t/fugu/mdns.t t/fugu/mdnsd.t`. Do not rename the conformance file: it
  is named after the spec stem, and `t/CLAUDE.md` requires that.

### 5.4 Protocol::HAP::PIN becomes Protocol::HAP::SetupCode

- `git mv lib/Protocol/HAP/PIN.pm lib/Protocol/HAP/SetupCode.pm`, and the `.pod`
  with it.
- `spec/HAP-Pairing.md` §2 says "8-digit setup code". `PIN` is the word the
  specification replaced.
- Rename the exported `normalize_pin` to `normalize_setup_code`, and any `*_pin`
  name inside the module with it. A module named for the specification that
  exports the superseded word is half a rename.
- Users: `bin/openhapd`, `Protocol::HAP::SRP`, `Protocol::HAP::Pairing`,
  `Protocol::HAP::Server`, and the umbrella `lib/Protocol/HAP.pod`.
- `git mv t/protocol/pin.t t/protocol/setupcode.t`. The conformance files keep
  their names and their citations: the spec sections do not move.

### 5.5 format_size moves to its only caller

- `App::FuguVM::CLI` calls `format_size` six times. Nothing else calls it.
- Move the function into `App::FuguVM::CLI` as the private `_format_size`.
  Delete it from the module, from the manual page, and from the export list.
- Move its subtests from `t/fugu/util.t` into `t/fuguvm/cli.t`, with the same
  cases.

### 5.6 Rewrite the website text

- `web/fugu.body.html`: replace the `Fugu::Util`, `Fugu::Store`, and
  `Fugu::MDNS` entries with `Fugu::Timeout`, `Fugu::StateFile`, and
  `Fugu::Mdnsd`, and correct each description. Correct the `Fugu::Imsg` entry if
  phase 4 has landed.
- `web/index.body.html`: confirm that the namespace names and the links match
  the tree.
- `t/web/site.t`: confirm the page list, the module-manual match, and the `.Xr`
  assertions after every landed phase.
- `web/mkindex.sh`: confirm that every `emit_group` prefix matches a directory
  that exists, and that `manuals.html` holds all five groups with their entries.

### 5.7 Finish the project documentation

- Root `CLAUDE.md`: the introduction now names `App::OpenHAP`, `App::FuguVM`,
  `Fugu`, `Protocol::HAP`, and `Protocol::Imsg`. Rewrite the four-namespace
  paragraph, the Layout list, and row 2 of the documentation table.
- `t/CLAUDE.md`: the tier table and the mock example.
- `t/openhap/integration/CLAUDE.md`: the module names in the rules.
- `README.md` and `INSTALL.md` name no module that moves. Confirm that, and
  change nothing.
- Leave `plans/001` to `plans/007` as they are.

### 5.8 Record the release work in TODO.md

Replace the `Protocol::HAP CPAN release` section with one section for the whole
tree. It lists what a release of any distribution here still needs:

- **A `Fugu` distribution would ship with no documentation.** MetaCPAN renders
  POD, not mdoc, and no `lib/Fugu/` module holds POD: the API documentation is
  in `man/fugu/*.3p`, which `Makefile` installs and the distribution would not
  carry. This is the largest obstacle to releasing the namespace that the whole
  effort exists to justify. Either the release ships generated POD, or the
  documentation rule changes for `Fugu::`.
- A distribution main module for `App-OpenHAP`, `App-FuguVM`, and `Fugu`. PAUSE
  grants indexing permission on that module first, and none exists.
- A `$VERSION` policy. No module carries one, and PAUSE does not index a module
  without a version.
- `no_index` metadata for the packages that live inside another file:
  `Protocol::HAP::Log::Null`, `Protocol::HAP::SRP::Client`,
  `Fugu::Control::Client`, `Fugu::Proxy::Cache`, `Fugu::Proxy::Meta`, and
  `App::FuguVM::Proxy::Cache`.
- Distribution tooling: `Makefile.PL` or `Build.PL`, `MANIFEST`, and
  distribution tests.
- The redistribution-license review of `spec/`.
- The descriptor-passing subset of `Protocol::Imsg`, from phase 4.

No naming question belongs in this list. Plan 008 decides every name in the
tree, including the ones it decides to keep. The design records those with their
reasons.

### 5.9 Close the sweep

- `t/scripts/namespaces.t` now holds every retired name from phases 1 to 5.
  Confirm the list against the design's rename table, and confirm the test reads
  tracked files only.
- Run it against a dirty tree: `make web` and `make package` first, so that
  `build/` and `web/build/` hold generated pages under the old names. The test
  must still pass, because generated output is not tracked.
- Plant one shim of each kind and confirm the test fails: a stale `use`, an
  `@ISA` bridge in a new file under the old path, a stale name in a `.pod` line
  that also names a live module, and a stale name in a manual page.

## Deliverables

- `lib/Fugu/Timeout.pm`, `lib/Fugu/StateFile.pm`, `lib/Fugu/Mdnsd.pm`, and
  `lib/Protocol/HAP/SetupCode.pm`, each with its 3p page or `.pod` sidecar.
- `t/fugu/timeout.t`, `t/fugu/statefile.t`, `t/fugu/mdnsd.t`, and
  `t/protocol/setupcode.t`.
- `App::FuguVM::CLI` with the private `_format_size`, and the moved subtests in
  `t/fuguvm/cli.t`.
- A complete `t/scripts/namespaces.t` retired list.
- Updated `web/fugu.body.html`, `web/index.body.html`, root `CLAUDE.md`,
  `t/CLAUDE.md`, `t/openhap/integration/CLAUDE.md`, and `TODO.md`.

## Acceptance criteria

- `make check` passes, and so do `make prettier`, `make web`, and
  `mandoc -Tlint -W warning` over every manual page.
- `t/scripts/namespaces.t` passes on a clean tree and on a built tree, and fails
  on each of the four planted shims.
- `grep -n 'format_size' lib/Fugu/Timeout.pm man/fugu/Timeout.3p` finds nothing,
  and `grep -rn 'normalize_pin' lib bin t` finds nothing.
- `make spec-coverage` still maps every `spec/MDNS-*.md` and `spec/HAP-*.md`
  file to its conformance test.
- `make install DESTDIR=...` into an empty directory produces only `App/`,
  `Fugu/`, and `Protocol/` under `$(LIBDIR)`, and only `Fugu::*.3p` under
  `man3p/`.
- `make uninstall DESTDIR=...` leaves an unrelated `App::` or `Protocol::`
  module in place.
- `make integration` passes on a guest that was purged of every old install
  path.
