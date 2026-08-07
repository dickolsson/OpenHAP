# Phase 1 — The ground rules

This phase lands the rules and the gates that pass on today's tree: the
vocabulary gate, the `.perlcriticrc` cleanup, `spec-coverage` in `make check`,
the three `CLAUDE.md` rules, and the `shrink` skill. It depends on no other
phase.

## Tasks

### 1.1 The vocabulary gate

- Add a `@BANNED` table to `t/scripts/namespaces.t`, beside `@RETIRED`, with the
  same `{ name, pattern }` shape. Entries:
  - `deprecation` — `qr/\bdeprecat/i`
  - `backward compatibility` — `qr/backwards?[ -]compat/i`
  - `for compatibility` — `qr/for compatibility/i`
  - `compatibility shim` —
    `qr/compatibility (?:shim|layer|alias|wrapper|path)/i`
- Each name must match its own pattern; the file's self-test subtest enforces
  that, so check the fourth entry: "compatibility shim" matches its alternation.
- Sweep the same `git ls-files` list the retired names use. Skip `plans/`
  (already skipped) and add `spec/` to the skip set for the `@BANNED` sweep
  only: `spec/HAP-Services.md` names a deprecated service and
  `spec/MQTT-Transport.md` recommends defaults "for compatibility", and the
  retired-name sweep must keep reading both.
- Do not ban the bare word "legacy". The Tasmota and HAP specs use it as a term
  of art, and `t/conformance/mqtt-control.t` quotes a spec table.
- The gate reads line by line, so a phrase split across a comment wrap escapes
  it. Accepted: the gate catches vocabulary, review catches intent.

### 1.2 Three cleanups the gate forces

The gate must pass on the clean tree. Exactly three tracked lines outside
`plans/` and `spec/` trip the four patterns today. Users: the gate in 1.1.

- `lib/Protocol/HAP/Server.pm:356-358`: the `/prepare` comment ends with "Accept
  both methods for compatibility." The reason is spec ambiguity. Reword to: "The
  spec shows POST in the table, but the later text uses PUT. Accept both."
- `lib/App/FuguVM/Config.pm:111-112`: the comment disclaims "a compatibility
  path". Keep the disclaimer, drop the phrase: "This is not a fallback: 'fuguvm
  init' writes vms/default.conf, and fuguvm(1) documents the directory."
- `TODO.md:803`: the bullet "Maintain backward compatibility where possible"
  contradicts the clean-break rule. Delete the bullet.

### 1.3 The `.perlcriticrc` cleanup

- Confirm the default severity of every entry with `perlcritic --list`
  (severities print in column one). Delete each entry whose policy defaults
  below severity 4 — the severity filter already excludes it, so the entry never
  did anything. Verified deletions, nine entries: `ProhibitExplicitISA` (3),
  `ProhibitPostfixControls` (2), `ProhibitParensWithBuiltins` (1),
  `ProhibitUnlessBlocks` (2), `RequireExtendedFormatting` (3),
  `ProhibitMagicNumbers` (2), `RequirePodSections` (2), `RequirePodAtEnd` (1),
  and the `[CodeLayout::ProhibitHardTabs]` block (3) — the last is a configuring
  block for a policy the filter excludes, not a disable.
- Keep the six entries whose policies default to severity 4 or 5, including
  `[-InputOutput::RequireBriefOpen]`.
- Keep the section comments that still describe a kept entry.

### 1.4 `make check` gains `spec-coverage`

- Change the `check` target to `check: lint test tidy spec-coverage`.
- Update the stale comment at `CLAUDE.md:48` that lists the target's parts.
- `prettier` stays out: it runs through `npx`, and no `deps/` manifest provides
  node. Note this in a Makefile comment above the target. CI already runs
  `spec-coverage` in `test.yml`; the gain is local parity.

### 1.5 The three rules in `CLAUDE.md`

Add a `## Simplicity` section after "Error handling and security", three
bullets, nothing more. The wording below is chosen to pass the 1.1 patterns —
keep it, or check any rewording against them:

- The project has no users. Delete old code paths outright; never keep an alias,
  a bridge, or a migration.
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
  - The keep list from the design, and the design's verified-keeps list — the
    audit claims the review refuted — as cautionary examples.
  - The procedure: grep `lib/ bin/ t/` for callers before every deletion; check
    conformance tests for spec citations on the code; delete code, test, and
    documentation together; run `make check`; commit as `refactor` with `!` when
    observable behavior changes.
- The skill points to the design for background; it restates nothing from
  `CLAUDE.md`.

### 1.7 `t/CLAUDE.md`

- The tooling-test paragraph describes `deps.t` and `conventions.t`. Add one
  sentence for `namespaces.t`'s two sweeps: retired names and banned vocabulary.

## Deliverables

- Extended `t/scripts/namespaces.t`.
- Reworded lines in `lib/Protocol/HAP/Server.pm`, `lib/App/FuguVM/Config.pm`,
  and `TODO.md`.
- A shorter `.perlcriticrc`.
- Updated `Makefile`, `CLAUDE.md`, and `t/CLAUDE.md`.
- New `.claude/skills/shrink/SKILL.md`.

## Acceptance criteria

- `make check` passes, and now runs `spec-coverage`.
- `prove -l t/scripts/namespaces.t` passes on the clean tree.
- Plant four violations — one line per pattern, in a scratch module under
  `lib/`, added with `git add` (the sweep reads tracked files only) — and the
  test fails four times, naming the file and the pattern each time. Remove the
  plants.
- Add a `@BANNED` entry whose pattern cannot match its own name, and the
  self-test subtest fails. Remove it.
- `perlcritic --profile .perlcriticrc --list-enabled` reports the same policy
  set before and after the cleanup (`--list` ignores the profile;
  `--list-enabled` is the falsifiable form).
- `grep -rn 'for compatibility' lib` finds nothing, and
  `grep -n 'backward compatibility' TODO.md` finds nothing.
- The new `CLAUDE.md` bullets themselves pass the gate:
  `prove -l t/scripts/namespaces.t` stays green after the `CLAUDE.md` edit.
