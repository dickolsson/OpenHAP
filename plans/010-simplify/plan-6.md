# Phase 6 — The lock

This phase lands the strict gates that hold the tree at its new size:
`t/scripts/symbols.t` and two Perl::Critic policies. It must land last — phases
2 to 5 delete the code these gates would flag, so the gates cannot pass before
the sweeps.

## Tasks

### 6.1 t/scripts/symbols.t

One new tooling test, in the house style of `namespaces.t`: `git ls-files`, text
analysis, self-testing rules, and a sweep-size guard. Three subtest groups:

- **The caller floor.** For every public sub defined in `lib/Fugu/` and
  `lib/App/`, the sub's name appears in at least one other tracked file under
  `lib/` or `bin/`. The match is textual (`\b<name>\b`), which accepts method
  strings in `%COMMANDS` tables and dynamic dispatch; the floor catches API
  nothing references, not API referenced weakly. Exemptions, each with a
  one-line reason in the table:
  - `Protocol::` is out of scope: a library's `.pod` contract is its caller.
  - `App::OpenHAP::Test::` counts `t/openhap/integration/` as `bin/`: the
    integration tier is what it exists for.
  - A named allowlist for the rest. Seed it empty; every entry added while
    making the gate pass must name its reason (a hook the design keeps, a
    contract method, an OpenBSD-only path that CI cannot reference).
- **Documentation completeness, both directions.** Every `lib/Fugu/*.pm` has
  `man/fugu/<Module>.3p`, a `MAN3P` entry (parse the `Makefile` block as
  `t/web/site.t` parses `MAN`), and a `t/fugu/<module>.t`. Every other
  `lib/**/*.pm` has a `.pod` sidecar. Every `.pod` and every `man/fugu/*.3p` has
  its `.pm`. No module has both a sidecar and a `.3p` page.
- **Declared dependencies.** Every `use` and `require` of a non-core module in
  `lib/` and `bin/` names a module that appears in `cpanfile` and in each
  `deps/*.txt` manifest that lists CPAN dependencies. Reuse the parse from
  `t/protocol/boundary.t` (stop at `__END__`, `Module::CoreList` for the core
  test).

Follow the two habits of `coreperl.t` and `namespaces.t`: a negative control per
group (a fabricated sub name must fail the floor; a fabricated import must fail
the declaration check), and a sweep-size guard so an over-eager skip rule cannot
pass an empty test.

### 6.2 The Perl::Critic enables

Add to `.perlcriticrc`, with the block syntax the file already uses:

- `[Subroutines::ProhibitUnusedPrivateSubroutines]` with `severity = 4`. Run
  `make lint`; for each finding, delete the sub, demote the caller relationship
  it reveals, or add the policy's `allow` option with a comment naming the
  reason. The sweeps removed the known cases; findings here are news.
- `[Variables::ProhibitUnusedVariables]` with `severity = 4`.
- `[Miscellanea::ProhibitUnrestrictedNoCritic]` and
  `[Miscellanea::ProhibitUselessNoCritic]`, both `severity = 4`. The tree has
  zero `## no critic` annotations; these keep suppression from becoming the
  escape hatch.

### 6.3 The residue pass

Run the new gates over the whole tree and burn down what they find beyond the
sweeps — the audit sampled; the gates are exhaustive. Small findings land in
this phase; anything structural is recorded for a future effort, not rushed
here.

### 6.4 Documentation

- Add the gate to `t/CLAUDE.md`'s tooling-test list, one line, next to
  `namespaces.t`.

## Deliverables

- New `t/scripts/symbols.t`.
- Extended `.perlcriticrc`.
- Whatever residue 6.3 removes, with its tests and documentation.
- One line in `t/CLAUDE.md`.

## Acceptance criteria

- `make check` passes.
- Plant a public sub `sub zz_unused_probe` in a `lib/Fugu/` module: `symbols.t`
  fails naming the module and the sub, and `make lint` stays quiet (the floor,
  not the policy, owns public subs). Remove the plant.
- Plant a private `sub _zz_unused_probe` in the same module: `make lint` fails
  via `ProhibitUnusedPrivateSubroutines`. Remove the plant.
- Plant `use JSON::XS` in a `lib/App/` module without touching `cpanfile`: the
  declaration group fails. Remove the plant.
- Delete a `.pod` sidecar in a scratch commit: the completeness group fails in
  both directions (missing sidecar, and — restoring it while deleting the `.pm`
  — orphaned sidecar). Restore.
- `git grep -c 'no critic' -- lib bin scripts` reports zero.
- The allowlist in `symbols.t` has a reason on every row, and
  `prove -l t/scripts/symbols.t` passes on the clean tree.
