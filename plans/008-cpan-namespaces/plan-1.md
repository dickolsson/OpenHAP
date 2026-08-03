# Phase 1 — FuguLib becomes Fugu

This phase renames one namespace and nothing else. It touches more files than
the other four phases together, so it stays mechanical on purpose: no module
splits, no API changes, and no moved functions. A reviewer must be able to check
it with a grep.

The product keeps its name in prose only where the prose means the collection of
daemon utilities. That collection is now called Fugu, so the website body, the
manual titles, and the `CLAUDE.md` text change with the packages.

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
- `lib/OpenHAP/`: `Server.pm`, `Storage.pm`, `DeviceLoader.pm`, `Tasmota/*.pm`,
  `Test/Integration.pm`, and the `.pod` sidecars.
- `lib/FuguVM/`: every module and every `.pod` sidecar.
- `lib/Protocol/` must not match. If it does, `t/protocol/boundary.t` is broken,
  not the code.

### 1.3 Move the manuals

- `git mv man/fugulib man/fugu`. Rewrite the `.Nm` name, the `.Xr`
  cross-references, and the body text of all 21 pages.
- `Makefile`: the `MAN3P` list, the comment above it, the `install-man` rename
  loop, the `uninstall` rename loop, and the `web` staging loop all use the
  literal `FuguLib::`. Each becomes `Fugu::`.
- The `package` target makes and fills `build/$(PACKAGE)/man/fugulib/`. That
  staging directory becomes `man/fugu/`.
- A page installs as `Fugu::Daemon.3p`, so `man Fugu::Daemon` finds it.

### 1.4 Move the tests

- `git mv t/fugulib t/fugu`. Retarget the imports in all 22 files.
- `git mv t/lib/FuguLib t/lib/Fugu`, and rename the `FuguLib::TestLog` package.
  Retarget every test that loads it.
- `t/fugu/coreperl.t` scans `lib/FuguLib` and builds `require FuguLib::$module`
  strings. Both change.
- `t/protocol/boundary.t`: direction two scans `$ROOT/lib/FuguLib` and matches
  `^(?:FuguLib|FuguVM|OpenHAP)\b`. Change the path, the pattern, and the subtest
  names.
- `Makefile`: the `test` target names `t/fugulib`.
- `t/CLAUDE.md`: the tier table row and the sandbox paragraph.

### 1.5 Build, install, and CI

- `Makefile`: `install` makes `$(LIBDIR)/FuguLib` and copies `lib/FuguLib/*.pm`
  into it. `package` makes and fills the same directory. `uninstall` removes it.
  All three change to `Fugu`.
- `scripts/integration`: the tarball carries `t/fugulib/sandbox.t`, and the
  comment above it names the path. Both change.
- `.github/workflows/integration.yml`: `lib/FuguLib/*.pm` and
  `t/fugulib/sandbox.t` appear in the push list and in the pull-request list.
  Change all four lines.
- `check.yml` matches `lib/**.pm` and `t/**`, so it needs no change. Confirm
  this rather than assume it.

### 1.6 Move the website page

- `git mv web/fugulib.body.html web/fugu.body.html`. Rewrite the heading, the 21
  `<dt>` module names, the body text, and the `manuals.html#fugulib` anchor.
- `Makefile`: the `web` target builds `$(WEBOUT)/fugulib.html` with the title
  `FuguLib`. Both change.
- `web/index.body.html`: the link text and the target file name.
- `t/web/site.t`: the `$dir eq 'fugulib'` test, the `"FuguLib::$stem"` name, the
  `FuguLib::Daemon.3p.html` and `FuguLib::Pidfile.3p.html` assertions, and the
  comments that explain them.

### 1.7 Update the project documentation

- Root `CLAUDE.md`: the namespace list in the introduction, the `lib/FuguLib/`
  and `man/fugulib/` rows in Layout, and row 2 of the documentation table.
- `README.md`, `INSTALL.md`, and `TODO.md`: every mention.
- Do not touch `plans/001` to `plans/007`.

## Deliverables

- `lib/Fugu/` with 21 modules, `man/fugu/` with 21 3p pages, `t/fugu/` with 22
  test files, and `t/lib/Fugu/TestLog.pm`.
- `web/fugu.body.html`, and an updated `web/index.body.html`.
- Updated `Makefile`, `scripts/integration`,
  `.github/workflows/integration.yml`, root `CLAUDE.md`, `t/CLAUDE.md`,
  `README.md`, `INSTALL.md`, `TODO.md`, `t/web/site.t`, `t/protocol/boundary.t`.

## Acceptance criteria

- `make check` passes.
- `grep -rn 'FuguLib\|fugulib' --exclude-dir=.git --exclude-dir=plans .` finds
  nothing.
- `make install DESTDIR=...` into an empty directory installs
  `$(LIBDIR)/Fugu/*.pm` and `man3p/Fugu::Daemon.3p`, and no `FuguLib` path.
- `make web` builds `fugu.html`, and `t/web/site.t` passes.
- `make spec-coverage` reports no stale citations.
- No file in `lib/`, `bin/`, `t/`, or `man/` defines or names a `FuguLib`
  package. This phase adds no alias and no compatibility module.
