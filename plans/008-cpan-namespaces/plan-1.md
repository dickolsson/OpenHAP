# Phase 1 — FuguLib becomes Fugu

This phase renames one namespace, and builds the two gates that every later
phase depends on. The rename itself stays mechanical: no module splits, no API
changes, and no moved functions.

The collection is now called Fugu, so the website body, the manual titles, and
the `CLAUDE.md` text change with the packages.

## Tasks

### 1.1 Move the modules

- `git mv lib/FuguLib lib/Fugu`. Rename the package statement in each of the 21
  modules.
- Rename the three nested packages: `FuguLib::Control::Client`,
  `FuguLib::Proxy::Cache`, and `FuguLib::Proxy::Meta`.
- Rewrite every `use` and `require` line, every fully qualified call such as
  `FuguLib::Util::bounded`, and every mention in a code comment.

### 1.2 Retarget the callers

- `bin/openhapd` and `bin/hapctl`: nine and five import lines.
- `lib/OpenHAP/` and `lib/FuguVM/`: every module and every `.pod` sidecar.
- `lib/Protocol/` must not match. If it does, `t/protocol/boundary.t` is broken,
  not the code.
- 29 test files outside `t/fugulib/` also name a `FuguLib::` module: 15 under
  `t/conformance/`, 7 under `t/openhap/` (including
  `t/openhap/integration/control.t` and `sandbox.t`), and 7 under `t/fuguvm/`.
  `make check` never runs the integration files, so a miss there surfaces only
  in `make integration`.

### 1.3 Move the manuals

- `git mv man/fugulib man/fugu`. Rewrite the `.Nm` name, the `.Xr`
  cross-references, and the body text of all 21 pages.
- `Makefile`: the `MAN3P` list, the comment above it, the `install-man` rename
  loop, the `uninstall` rename loop, the `web` staging loop, and the
  `build/$(PACKAGE)/man/fugulib/` staging directory in `package`.
- A page installs as `Fugu::Daemon.3p`, so `man Fugu::Daemon` finds it.
- Run `mandoc -Tlint -W warning` over the moved pages. `make check` does not.

### 1.4 Move the tests

- `git mv t/fugulib t/fugu`. Retarget the imports in all 22 files.
- `git mv t/lib/FuguLib t/lib/Fugu`, and rename the `FuguLib::TestLog` package.
- `t/fugu/coreperl.t:20` opens `$lib/FuguLib` and calls `skip_all` when the
  directory is absent, and line 64 builds `require FuguLib::$module`. Change the
  path and the string, and make the missing directory a hard failure. A skip
  would hide the whole core-Perl guarantee.
- `t/protocol/boundary.t` holds two different subtests, and the plan for each
  differs:
  - Direction one, at line 64, scans `lib/Protocol` and matches
    `^(?:FuguLib|FuguVM|OpenHAP)\b` at line 73. Change the pattern only.
  - Direction two, at line 94, scans `lib/FuguLib` and matches
    `^(?:Protocol::HAP|OpenHAP)\b` at line 104. Change the path only. Phase 2
    changes that pattern.
  - The file header at lines 3 to 8 and both subtest names name FuguLib.
- `Makefile`: the `test` target names `t/fugulib`.
- `t/CLAUDE.md`: the tier table row and the sandbox paragraph.

### 1.5 Add the clean-break gate

- Write `t/scripts/namespaces.t`. It lists the retired names, reads the tracked
  files with `git ls-files`, skips `plans/`, and fails on any hit. Seed the list
  with `FuguLib`.
- Reading tracked files only keeps `build/`, `web/build/`, and `.fuguvm/` out of
  the result. Those directories hold generated pages under the old names until
  `make clean`, and they make a plain `grep -r` useless as a gate.
- Match the retired name where no live name precedes it, so that a line holding
  both an old and a new name still fails. A line filter such as
  `grep -v 'App::OpenHAP::'` cannot do that.
- Every later phase appends its retired names to the list. This test replaces
  the hand-run greps.

### 1.6 Fix the CI compile gate

- `.github/workflows/check.yml:89-90` runs
  `find lib -name "*.pm" -exec perl -I lib -cw {} \;`. `find -exec … \;` does
  not propagate the exit status, so a module that fails to compile prints an
  error and the step passes.
- Replace both lines with a form that fails, such as
  `find lib -name '*.pm' -print0 | xargs -0 -n1 perl -I lib -cw`.
- Without this, no gate in the project compiles the renamed tree end to end.

### 1.7 Build, install, and CI

- `Makefile`: `install` makes `$(LIBDIR)/FuguLib` and copies `lib/FuguLib/*.pm`
  into it. `package` makes and fills the same directory. `uninstall` removes it.
  All three change to `Fugu`.
- `scripts/integration` names the path four times: the comment at line 22, the
  `tar czf` at line 27, the comment at line 67, and the `TESTS` variable at
  line 69. Miss line 69 and the OpenBSD-only pledge and unveil subtests stop
  running, because the no-`prove` fallback at line 75 skips a missing file
  without a word.
- `scripts/vm-provision` runs `make uninstall` from the new checkout, which no
  longer names `$(LIBDIR)/FuguLib`. Add a purge of the retired path to the
  provisioning step, before `make install`. Without it, a warm guest disk keeps
  the old modules in `@INC`, and a missed rename still resolves there, so
  `make integration` passes against a shim that the environment supplies.
- `.github/workflows/integration.yml`: `lib/FuguLib/*.pm` and
  `t/fugulib/sandbox.t` appear in the push list and in the pull-request list.
  Change all four lines.
- `check.yml` matches `lib/**.pm` and `t/**`, so its filters need no change.

### 1.8 Move the website page

- `git mv web/fugulib.body.html web/fugu.body.html`. Rewrite the heading, the 21
  `<dt>` module names, the body text, and the `manuals.html#fugulib` anchor.
- `web/mkindex.sh:148` is
  `emit_group 'FuguLib' fugulib man/fugulib/ 'FuguLib::' "$@"`. It is the only
  source of both the 3p entries and the `id="fugulib"` anchor, and `emit_group`
  emits nothing when its path prefix matches nothing. Miss this line and all 21
  index entries and the anchor disappear. Line 91 names the page format in a
  comment.
- `web/head.html:16` links `fugulib.html` in the navigation that `mkpage.sh`
  stamps on every page.
- `Makefile`: the `web` target builds `$(WEBOUT)/fugulib.html` with the title
  `FuguLib`.
- `web/index.body.html`: the link text and the target file name.
- `web/CLAUDE.md:60-64`: four mentions that explain the staging rename.
- `t/web/site.t`: `@SITE` at line 44, `@NAV` at line 56, the `$dir eq 'fugulib'`
  test at line 68, the `"FuguLib::$stem"` name at line 71, and the
  `FuguLib::Daemon` and `FuguLib::Pidfile` assertions at lines 223 to 225.
- `t/web/site.t` skips without `lowdown` and `mandoc`, which `make deps-test`
  does not install. Run `make deps-develop` and `make web` in this phase, and
  confirm the suite runs rather than skips.

### 1.9 Update the project documentation

- Root `CLAUDE.md`: the namespace list in the introduction, the `lib/FuguLib/`
  and `man/fugulib/` rows in Layout, and row 2 of the documentation table.
- `TODO.md`: every mention, in both the `FuguLib::` and the `lib/FuguLib/`
  forms.
- `README.md` and `INSTALL.md` hold no occurrence of `FuguLib`. Confirm that,
  and change nothing.
- Do not touch `plans/001` to `plans/007`.

## Deliverables

- `lib/Fugu/` with 21 modules, `man/fugu/` with 21 3p pages, `t/fugu/` with 22
  test files, and `t/lib/Fugu/TestLog.pm`.
- `t/scripts/namespaces.t`, the new clean-break gate.
- `web/fugu.body.html`, and updated `web/head.html`, `web/mkindex.sh`,
  `web/index.body.html`, and `web/CLAUDE.md`.
- Updated `Makefile`, `scripts/integration`, `scripts/vm-provision`,
  `.github/workflows/check.yml`, `.github/workflows/integration.yml`, root
  `CLAUDE.md`, `t/CLAUDE.md`, `TODO.md`, `t/web/site.t`,
  `t/protocol/boundary.t`.

## Acceptance criteria

- `make check` passes, and so do `make prettier`, `make web`, and
  `mandoc -Tlint -W warning` over `man/fugu/`.
- `t/scripts/namespaces.t` passes, and fails correctly on a planted
  `use FuguLib::Log;` and on a planted `lib/FuguLib/Log.pm` that carries
  `our @ISA = ('Fugu::Log');`. Prove both failure modes once by hand.
- `t/web/site.t` runs rather than skips, and passes.
- `make install DESTDIR=...` into an empty directory installs
  `$(LIBDIR)/Fugu/*.pm` and `man3p/Fugu::Daemon.3p`, and no `FuguLib` path.
- `make spec-coverage` reports no stale citations.
- `make integration` passes on a guest that was purged of the old install.
