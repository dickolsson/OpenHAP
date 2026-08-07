# Phase 6 — The lock

This phase lands the strict gates that hold the tree at its new size:
`t/scripts/symbols.t` and the Perl::Critic enables. It must land last — phases 2
to 5 delete the code these gates would flag, so the gates cannot pass before the
sweeps.

## Tasks

### 6.1 t/scripts/symbols.t

One new tooling test, in the house style of `namespaces.t`: `git ls-files`, text
analysis, self-testing rules, a sweep-size guard, and a negative control per
group. Three subtest groups:

- **The caller floor.** For every sub defined in `lib/Fugu/` and `lib/App/` —
  public and private alike — the sub's name appears at least once in `lib/` or
  `bin/` outside its own definition line. Same-file references count: that is
  what lets `%COMMANDS` method strings, template-method overrides named in the
  base class, and self-calls pass without an allowlist row each. The floor
  catches API nothing references at all. Its known blind spot is named in a
  comment: a name duplicated across the CPAN boundary passes wrongly
  (`Fugu::Random::random_bytes` matches `Protocol::HAP::Crypto`'s unrelated
  sub), so the allowlist also records names to check by hand.
  - `Protocol::` is out of scope: a library's `.pod` contract is its caller.
  - `App::OpenHAP::Test::` counts `t/openhap/integration/` as its caller tree:
    the integration tier is what it exists for.
  - A named allowlist for the rest, one reason per row. Rows earn their place
    while making the gate pass; a row with no reason fails the self-test.
- **Documentation completeness, both directions.** Every `lib/Fugu/*.pm` has
  `man/fugu/<Module>.3p`, a `MAN3P` entry (parse the `Makefile` block as
  `t/web/site.t` parses `MAN`), and a `t/fugu/<module>.t`. Every other
  `lib/**/*.pm` has a `.pod` sidecar. Every `.pod` and every `man/fugu/*.3p` has
  its `.pm`. No module has both a sidecar and a `.3p` page. An exemption table
  with reasons, seeded with one row: `lib/Protocol/HAP/Store.pod` is the store
  contract and has no `.pm` by design (`CLAUDE.md` names it; `namespaces.t`
  already treats it as live).
- **Declared dependencies.** Every `use` and `require` of a non-core module in
  `lib/` and `bin/` names a module that `cpanfile` requires. Reuse the parse
  from `t/protocol/boundary.t` (stop at `__END__`, `Module::CoreList` for the
  core test). The `deps/*.txt` manifests stay out of the gate: they name OS
  packages (`p5-JSON-XS`, `p5-libwww`), not modules, and the mapping is not
  mechanical — the existing human-kept rule in `CLAUDE.md` continues to own
  them.

### 6.2 The Perl::Critic enables

Add to `.perlcriticrc`, with the block syntax the file already uses:

- `[Variables::ProhibitUnusedVariables]` with `severity = 4`. Measured clean on
  today's tree; the enable locks it.
- `[Miscellanea::ProhibitUnrestrictedNoCritic]` and
  `[Miscellanea::ProhibitUselessNoCritic]`, both `severity = 4`. The tree has
  zero `## no critic` annotations; these keep suppression from becoming the
  escape hatch.
- Do **not** enable `Subroutines::ProhibitUnusedPrivateSubroutines`: it is
  document-scoped, and measured on this tree it flags exactly the seven live
  template-method overrides in `Tasmota/*.pm` and nothing real. The caller floor
  in 6.1 covers private subs across files instead. Record this in a one-line
  comment where the enables sit, so nobody "fixes" it back in.

### 6.3 The residue pass

Run the new gates over the whole tree and burn down what they find beyond the
sweeps — the audit sampled; the gates are exhaustive. Small findings land in
this phase; anything structural is recorded for a future effort, not rushed
here.

### 6.4 Documentation

- Add one sentence for `symbols.t` to the tooling-test paragraph of
  `t/CLAUDE.md`, beside the phase-1 sentence for `namespaces.t`.

## Deliverables

- New `t/scripts/symbols.t`.
- Extended `.perlcriticrc`.
- Whatever residue 6.3 removes, with its tests and documentation.
- One sentence in `t/CLAUDE.md`.

## Acceptance criteria

- `make check` passes, and `prove -l t/scripts/symbols.t` passes on the clean
  tree with every allowlist and exemption row carrying a reason.
- Plant a sub `sub zz_unused_probe` in a `lib/Fugu/` module and `git add` it:
  the caller floor fails naming the module and the sub. Remove the plant.
- Plant `use JSON::PP::Boolean::Missing` (any module absent from `cpanfile`) in
  a `lib/App/` module: the declaration group fails. A plant of `use JSON::XS`
  must NOT fail — `cpanfile` already requires it, which is why the negative
  control uses an absent module. Remove the plant.
- Delete a `.pod` sidecar in a scratch commit: the completeness group fails;
  restore it and delete the `.pm` instead: it fails in the other direction
  (orphaned sidecar). Restore both.
- `git grep -c 'no critic' -- lib bin scripts` exits non-zero with no output (no
  annotations exist; note `grep -c` exits 1 on zero matches, so the scripted
  form is `! git grep -q 'no critic' -- lib bin scripts`).
- `make lint` stays green with the three enabled policies.
