# Phase 5 — Fugu::Timeout, and the documentation pass

This phase removes the last general noun from the tree, and finishes the
documentation. After it, every module name in the repository says what the
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
- Add `Fugu::Util` to the retired list in `t/scripts/namespaces.t`.

### 5.2 format_size moves to its only caller

- `App::FuguVM::CLI` calls `format_size` six times. Nothing else calls it.
- Move the function into `App::FuguVM::CLI` as the private `_format_size`.
  Delete it from the module, from the manual page, and from the export list.
- Move its subtests from `t/fugu/util.t` into `t/fuguvm/cli.t`, with the same
  cases.

### 5.3 Rewrite the website text

- `web/fugu.body.html`: replace the `Fugu::Util` entry with `Fugu::Timeout`, and
  correct its description. Correct the `Fugu::Imsg` entry if phase 4 has landed.
- `web/index.body.html`: confirm that the namespace names and the links match
  the tree.
- `t/web/site.t`: confirm the page list, the module-manual match, and the `.Xr`
  assertions after every landed phase.
- `web/mkindex.sh`: confirm that every `emit_group` prefix matches a directory
  that exists, and that `manuals.html` holds all five groups with their entries.

### 5.4 Finish the project documentation

- Root `CLAUDE.md`: the introduction now names `App::OpenHAP`, `App::FuguVM`,
  `Fugu`, `Protocol::HAP`, and `Protocol::Imsg`. Rewrite the four-namespace
  paragraph, the Layout list, and row 2 of the documentation table.
- `t/CLAUDE.md`: the tier table and the mock example.
- `t/openhap/integration/CLAUDE.md`: the module names in the rules.
- `README.md` and `INSTALL.md` name no module that moves. Confirm that, and
  change nothing.
- Leave `plans/001` to `plans/007` as they are.

### 5.5 Record the release work in TODO.md

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
- The open naming questions: `Fugu::MQTT`, `Fugu::SSH`, and `Fugu::Proxy` may
  belong under `Net::` or `HTTP::`. `Fugu::MDNS` needs a different question
  first, because it does not implement mDNS: it is a control client for
  `mdnsd(8)`, so the name promises more than the module holds.
- The descriptor-passing subset of `Protocol::Imsg`, from phase 4.

### 5.6 Close the sweep

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

- `lib/Fugu/Timeout.pm`, `man/fugu/Timeout.3p`, and `t/fugu/timeout.t`.
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
- `grep -n 'format_size' lib/Fugu/Timeout.pm man/fugu/Timeout.3p` finds nothing.
- `make install DESTDIR=...` into an empty directory produces only `App/`,
  `Fugu/`, and `Protocol/` under `$(LIBDIR)`, and only `Fugu::*.3p` under
  `man3p/`.
- `make uninstall DESTDIR=...` leaves an unrelated `App::` or `Protocol::`
  module in place.
- `make integration` passes on a guest that was purged of every old install
  path.
