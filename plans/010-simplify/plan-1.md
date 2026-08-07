# Phase 1 — The ground rules

This phase lands the rules and the gates that pass on today's tree: the
vocabulary gate, the `.perlcriticrc` cleanup, `spec-coverage` in `make check`,
the three `CLAUDE.md` rules, and the `shrink` skill. It depends on no other
phase. The sweeps in phases 2–5 cite the rules this phase writes down.

## Tasks

### 1.1 The vocabulary gate

- Add a `@BANNED` table to `t/scripts/namespaces.t`, beside `@RETIRED`, with the
  same `{ name, pattern }` shape. Entries:
  - `deprecation` — `qr/\bdeprecat/i`
  - `backward compatibility` — `qr/backwards?[ -]compat/i`
  - `for compatibility` — `qr/for compatibility/i`
  - `compatibility construct` —
    `qr/compatibility (?:shim|layer|alias|wrapper|path)/i`
- Sweep the same `git ls-files` list the retired names use, and assert each
  pattern against its own name, as the file already does for `@RETIRED`.
- Skip `plans/` (already skipped) and add `spec/` to the skip set for the
  `@BANNED` sweep only. The specs quote other projects' deprecations
  (`spec/HAP-Services.md` names a deprecated service; `spec/MQTT-Transport.md`
  recommends defaults "for compatibility"), and the retired-name sweep must keep
  reading them.
- Do not ban the bare word "legacy". The Tasmota and HAP specs use it as a term
  of art, and `t/conformance/mqtt-control.t` quotes it from a spec table.

### 1.2 Two comments reword

The gate must pass on a clean tree, and two lines trip it today. Users: the gate
in 1.1.

- `lib/Protocol/HAP/Server.pm:356-358`: the `/prepare` comment ends with "Accept
  both methods for compatibility." The reason is spec ambiguity, not
  compatibility. Reword to: "The spec shows POST in the table, but the later
  text uses PUT. Accept both."
- `lib/App/FuguVM/Config.pm:111-112`: the comment disclaims "a compatibility
  path". Keep the disclaimer, drop the phrase: "This is not a fallback: 'fuguvm
  init' writes vms/default.conf, and fuguvm(1) documents the directory."

### 1.3 The `.perlcriticrc` cleanup

- Confirm the default severity of every `[-Policy]` entry with
  `perlcritic --profile .perlcriticrc --list`. Delete each entry whose policy
  defaults below severity 4 — the severity filter already excludes it, so the
  entry never did anything. Expected deletions, to confirm rather than trust:
  `ProhibitExplicitISA`, `ProhibitPostfixControls`,
  `ProhibitParensWithBuiltins`, `ProhibitUnlessBlocks`,
  `RequireExtendedFormatting`, `ProhibitMagicNumbers`, `RequirePodSections`,
  `RequirePodAtEnd`, and the `[CodeLayout::ProhibitHardTabs]` block.
- Keep every entry whose policy defaults to severity 4 or 5.
- Keep the section comments that still describe a kept entry; delete the rest.

### 1.4 `make check` gains `spec-coverage`

- Change the `check` target to `check: lint test tidy spec-coverage`.
- `prettier` stays out: it runs through `npx`, and no `deps/` manifest provides
  node. Note this in the Makefile comment above the target.

### 1.5 The three rules in `CLAUDE.md`

Add a `## Simplicity` section after "Error handling and security", three
bullets, nothing more:

- The project has no users. Delete a compatibility path; never deprecate, alias,
  or migrate.
- Do not keep test-only API. Delete a sub or option that only tests use,
  together with its test.
- Validate each input once, at its boundary. Do not check the same invariant
  again downstream.

### 1.6 The `shrink` skill

- Create `.claude/skills/shrink/SKILL.md`, modeled on `ship-it`: frontmatter
  with name and description, then the procedure. Do not name it `simplify` — a
  harness skill already holds that name.
- Content, in order:
  - The six shapes of creep from the design, one line each, with one former
    in-repo example each.
  - The keep list from the design, verbatim in substance.
  - The procedure: grep `lib/ bin/ t/` for callers before every deletion; delete
    code, test, and documentation together; run `make check`; commit as
    `refactor` with `!` when observable behavior changes.
- The skill points to the design for background; it restates nothing from
  `CLAUDE.md`.

## Deliverables

- Extended `t/scripts/namespaces.t`.
- Two reworded comments in `lib/Protocol/HAP/Server.pm` and
  `lib/App/FuguVM/Config.pm`.
- A shorter `.perlcriticrc`.
- Updated `Makefile` and `CLAUDE.md`.
- New `.claude/skills/shrink/SKILL.md`.

## Acceptance criteria

- `make check` passes, and now runs `spec-coverage`.
- `prove -l t/scripts/namespaces.t` passes on the clean tree.
- Plant one violation per pattern — a `# kept for backward compatibility`
  comment in a scratch module under `lib/` — and the test fails naming the file
  and the pattern. Remove the plant.
- Add a `@BANNED` entry with a pattern that cannot match its own name, and the
  self-test subtest fails. Remove it.
- `perlcritic --profile .perlcriticrc --list` reports the same enabled policy
  set before and after the cleanup.
- `grep -n 'for compatibility' lib` finds nothing.
- `grep -c '^-' .claude/skills/shrink/SKILL.md` confirms the file exists;
  `make prettier` (where npx exists) accepts it.
