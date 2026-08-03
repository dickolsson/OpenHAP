# Phase 3 — FuguVM becomes App::FuguVM

This phase moves the VM utility into `App::`, and renames the two modules that
name a mechanism instead of a feature. The command is still `fuguvm`, the
configuration file is still `.fuguvmrc`, and the data files stay under
`share/fuguvm/`.

The phase depends on phase 2. Both phases edit the same regex in
`t/web/site.t:203` and in `t/protocol/boundary.t:73`, and the phase-2 state must
keep the `FuguVM` alternative in each. Phase 3 removes it.

## Tasks

### 3.1 Move the namespace

- `git mv lib/FuguVM lib/App/FuguVM`. Rename the package statement in each of
  the 11 modules, the nested `FuguVM::Proxy::Cache` package, and the
  `=head1 NAME` line of each `.pod` sidecar.
- Rewrite every `use`, `require`, and fully qualified call.
- `bin/fuguvm` loads one module. Change that line.
- `lib/FuguVM/Image.pm:73` explains that the file "is two directories below the
  project root". After the move it is three. The code is safe, because
  `share_path` derives the root from `Fugu::File`'s own `__FILE__`, but the
  comment is wrong.

### 3.2 FuguVM::VM becomes App::FuguVM::Guest

- `git mv lib/App/FuguVM/VM.pm lib/App/FuguVM/Guest.pm`, and the `.pod` with it.
- `FuguVM::VM` repeats its parent. The module is the lifecycle of one OpenBSD
  guest.
- The private methods keep their names. `_bounded` becomes a call into
  `Fugu::Timeout` in phase 5, not here.
- Users: `App::FuguVM::CLI`, `t/fuguvm/vm.t`, and the `.pod` sidecars that
  cross-reference it.

### 3.3 FuguVM::Expect becomes App::FuguVM::Console

- `git mv lib/App/FuguVM/Expect.pm lib/App/FuguVM/Console.pm`, and the `.pod`
  with it.
- `Expect` names the CPAN dependency. `Console` names the feature: the module
  drives the guest's serial console.
- `Console`, not `Installer`. The module has two public verbs, `run_install` and
  `run_script`, and `fuguvm expect <script>` is a documented subcommand
  (`lib/FuguVM/CLI.pm:102`, `man/fuguvm/fuguvm.1:185`) that calls the second
  one. `Installer` would name half the module.
- `SCRIPT_DIR` stays `share/fuguvm/expect`. That directory holds expect(1)
  scripts, so the path is still correct, and the data files do not move. The
  `expect` subcommand keeps its name for the same reason.
- Rewrite the sidecar abstract:
  `App::FuguVM::Console - drive the serial console of a guest`.

### 3.4 Move and retarget the tests

- `git mv t/fuguvm/vm.t t/fuguvm/guest.t`. The tier directory keeps its name: it
  is named after the product, and the product is still FuguVM.
- `t/fuguvm/vm.t:15` is
  `eval { require FuguVM::VM; 1 } or plan skip_all => ...`. A stale guard turns
  this rename into a skipped file, not a failing one. Make the load a hard
  failure, or retarget the guard and confirm the file still runs.
- Retarget the imports in the other nine files under `t/fuguvm/`.
- `t/protocol/boundary.t:73` is `^(?:Fugu|FuguVM|App)\b` after phase 2. Drop the
  `FuguVM` alternative, because `App` now covers it.
- Add the retired names to `t/scripts/namespaces.t`: `FuguVM::`, `FuguVM::VM`,
  `FuguVM::Expect`, and the path form `lib/FuguVM/`.
- `t/scripts/conventions.t` compiles every script under `scripts/`. Nothing
  there loads a `FuguVM::` module today. Confirm that rather than assume it.

### 3.5 Build and CI

- `Makefile`: FuguVM is a development tool. The `install` and `package` targets
  do not name `lib/FuguVM/` or `bin/fuguvm`, and they must not gain them. Only
  the `test` target names `t/fuguvm/`, and that path does not change.
- `.github/workflows/integration.yml`: `lib/FuguVM/**.pm` becomes
  `lib/App/FuguVM/**.pm`, in the push list and the pull-request list.
- `scripts/vm-provision` and `scripts/vm-up` name the command `fuguvm` and the
  `.fuguvmrc` file, not a module. Confirm this rather than assume it.

### 3.6 Update the website and the documentation

- `web/mkindex.sh:151` is
  `emit_group 'FuguVM modules' vm-modules lib/FuguVM/ '' "$@"`. The prefix stops
  matching, and the group emits nothing when nothing matches, so the whole
  section and its `id="vm-modules"` anchor vanish from `manuals.html`.
- `t/web/site.t:203` is `^(?:App|FuguVM|Protocol)::` after phase 2. Drop the
  `FuguVM` alternative here, and confirm the one-page-per-sidecar assertion at
  line 206 still balances.
- Root `CLAUDE.md`: the namespace list, and the `lib/FuguVM/` row in Layout.
- `web/fuguvm.body.html` and `.claude/skills/fuguvm/SKILL.md` name the product
  and the command, not the modules. They stay as they are, unless a grep finds a
  module name in them.
- `man/fuguvm/fuguvm.1` documents the command. Change it only where it names a
  module.

## Deliverables

- `lib/App/FuguVM/` with 11 modules, including `Guest.pm` and `Console.pm`, each
  with a `.pod` sidecar.
- `t/fuguvm/guest.t`, and nine retargeted test files.
- Updated `bin/fuguvm`, `web/mkindex.sh`, `t/web/site.t`,
  `t/protocol/boundary.t`, `t/scripts/namespaces.t`,
  `.github/workflows/integration.yml`, and root `CLAUDE.md`.

## Acceptance criteria

- `make check` passes, and so do `make prettier` and `make web`.
- `t/scripts/namespaces.t` passes with the new retired names.
- `t/fuguvm/guest.t` runs rather than skips. Confirm the planned test count
  against the count before the rename.
- `make package` does not ship `lib/App/FuguVM/`.
- `manuals.html` holds the `vm-modules` group with all 11 entries.
- `bin/fuguvm status` runs from a clean checkout, or fails only for a reason
  that a missing VM explains.
