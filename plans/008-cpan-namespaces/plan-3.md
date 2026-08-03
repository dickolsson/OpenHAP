# Phase 3 — FuguVM becomes App::FuguVM

This phase moves the VM utility into `App::`, and renames the two modules that
name a mechanism instead of a feature. The command is still `fuguvm`, the
configuration file is still `.fuguvmrc`, and the data files stay under
`share/fuguvm/`. Only Perl package names and file paths change.

The phase depends on phase 1. It does not depend on phase 2, and the two can
land in either order.

## Tasks

### 3.1 Move the namespace

- `git mv lib/FuguVM lib/App/FuguVM`. Rename the package statement in each of
  the 11 modules, the nested `FuguVM::Proxy::Cache` package, and the
  `=head1 NAME` line of each `.pod` sidecar.
- Rewrite every `use`, `require`, and fully qualified call.
- `bin/fuguvm` loads one module. Change that line.

### 3.2 FuguVM::VM becomes App::FuguVM::Guest

- `git mv lib/App/FuguVM/VM.pm lib/App/FuguVM/Guest.pm`, and the `.pod` with it.
- `FuguVM::VM` repeats its parent. The module is the lifecycle of one OpenBSD
  guest, and `Guest` says that.
- The private methods keep their names. `_bounded` becomes a call into
  `Fugu::Timeout` in phase 5, not here.
- Users: `App::FuguVM::CLI`, `t/fuguvm/vm.t`, and the `.pod` sidecars that
  cross-reference it.

### 3.3 FuguVM::Expect becomes App::FuguVM::Installer

- `git mv lib/App/FuguVM/Expect.pm lib/App/FuguVM/Installer.pm`, and the `.pod`
  with it.
- `Expect` names the CPAN dependency. The module drives the OpenBSD installer
  over the serial console, and that is the feature.
- `SCRIPT_DIR` stays `share/fuguvm/expect`. That directory holds expect(1)
  scripts, so the path is still correct, and the data files do not move.
- Rewrite the sidecar abstract:
  `App::FuguVM::Installer - drive the OpenBSD installer over the serial console`.

### 3.4 Move and retarget the tests

- `git mv t/fuguvm/vm.t t/fuguvm/guest.t`. The tier directory keeps its name: it
  is named after the product, and the product is still FuguVM.
- Retarget the imports in the other nine files under `t/fuguvm/`.
- `t/protocol/boundary.t` matches `^(?:Fugu|FuguVM|App)\b` after phase 2. Drop
  the `FuguVM` alternative, because `App` now covers it.
- `t/scripts/conventions.t` compiles every script under `scripts/`. Confirm that
  it still passes: nothing under `scripts/` loads a `FuguVM::` module today, and
  nothing may start to.

### 3.5 Build and CI

- `Makefile`: FuguVM is a development tool. The `install` and `package` targets
  do not name `lib/FuguVM/` or `bin/fuguvm`, and they must not gain them. Only
  the `test` target names `t/fuguvm/`, and that path does not change.
- `.github/workflows/integration.yml`: `lib/FuguVM/**.pm` becomes
  `lib/App/FuguVM/**.pm`, in the push list and the pull-request list.
- `scripts/vm-provision` and `scripts/vm-up` name the command `fuguvm` and the
  `.fuguvmrc` file, not a module. Confirm this rather than assume it.

### 3.6 Update the documentation

- Root `CLAUDE.md`: the namespace list, and the `lib/FuguVM/` row in Layout.
- `t/web/site.t`: after phase 2 the module-manual match is
  `^(?:App|Protocol)::`, and it already covers `App::FuguVM::Guest`. Confirm the
  page names that the test expects.
- `web/fuguvm.body.html` and `.claude/skills/fuguvm/SKILL.md` name the product
  and the command, not the modules. They stay as they are, unless a grep finds a
  module name in them.
- `man/fuguvm/fuguvm.1` documents the command. Change it only where it names a
  module.

## Deliverables

- `lib/App/FuguVM/` with 11 modules, including `Guest.pm` and `Installer.pm`,
  each with a `.pod` sidecar.
- `t/fuguvm/guest.t`, and nine retargeted test files.
- Updated `bin/fuguvm`, `Makefile` comments where they name the namespace,
  `.github/workflows/integration.yml`, `t/protocol/boundary.t`, and root
  `CLAUDE.md`.

## Acceptance criteria

- `make check` passes.
- `grep -rn 'FuguVM::' --exclude-dir=.git --exclude-dir=plans . | grep -v 'App::FuguVM::'`
  finds nothing.
- `grep -rn 'FuguVM::VM\|FuguVM::Expect' --exclude-dir=.git --exclude-dir=plans .`
  finds nothing.
- `make package` does not ship `lib/App/FuguVM/`.
- `bin/fuguvm status` runs from a clean checkout, or fails only for a reason
  that a missing VM explains.
- No alias, no `@ISA` bridge, and no compatibility module carries an old name.
