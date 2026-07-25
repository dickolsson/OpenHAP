# Phase 2 — Spec coverage tooling

Build the tool that makes spec↔test cross-verification mechanical (`design.md`
Contract 2). Depends on Phase 1 (citation convention exists and has first
users).

## Tasks

### 2.1 `scripts/spec-coverage`

A Perl script (v5.36, base-system modules only, OpenBSD style like
`scripts/deps.sh` peers):

- **Section inventory**: parse `spec/*.md` headings (`##`, `###`) and extract
  numbered anchors (`§N`, `§N.M`) per file. Files without numbering
  (`IMPLEMENTATIONS.md`) and index files (`HAP.md`, `MQTT.md`) are listed but
  marked non-citable/index.
- **Citation scan**: grep `t/` recursively for the citation pattern
  `\[(HAP|MQTT)[A-Za-z-]* §[0-9][0-9.]*(/[^\]]+)?\]`, recording file and line.
- **Join**: resolve each citation's spec stem + section against the inventory.
  Row-suffixed citations (`§5/Brightness`) resolve to their section; row
  existence is not checked (rows are unnumbered by design).

Output (stdout, plain text):

```
spec/HAP-Pairing.md      18/24 sections cited
  §2.6  t/conformance/hap-pairing.t:88 t/openhap/pairing.t:120
  §7.4  UNCOVERED
...
TOTAL: 96/143 numbered sections cited (67%)
STALE: t/openhap/foo.t:12 cites HAP-Pairing §9.9 (no such section)
```

Exit status: non-zero iff stale citations exist (a citation naming a section
absent from the inventory — the failure mode after spec regeneration). Low
coverage never fails the build.

Options: `--quiet` (totals and stale errors only, for CI), `--uncovered` (list
only uncovered sections, for gap-planning).

### 2.2 Makefile and CI wiring

- Add `spec-coverage` target: `@perl scripts/spec-coverage --quiet` and a
  `.PHONY` entry; document it in the root `CLAUDE.md` command list.
- Add a step to the `test` job in `.github/workflows/check.yml` running
  `make spec-coverage` after `make test`, so stale citations break CI.

### 2.3 Tool tests

- `t/openhap/spec-coverage.t` (host-side unit test, skip-friendly): run the
  script against a fixture tree (`File::Temp` spec dir + test dir) covering:
  citation parsed, row-suffix parsed, stale citation detected with non-zero
  exit, unnumbered spec file tolerated, `--uncovered` output.

### 2.4 Baseline report

- Run the tool on the real tree; commit nothing from the output, but record the
  initial coverage number in the Phase 3 plan's gap list to prioritize
  conformance work (Pairing, TLV8, HTTP, Encryption first — highest requirement
  density per the assessment).

## Deliverables

- New: `scripts/spec-coverage`, `t/openhap/spec-coverage.t`.
- Modified: `Makefile`, `CLAUDE.md`, `.github/workflows/check.yml`.

## Acceptance criteria

- `make spec-coverage` prints a matrix and exits 0 on the current tree.
- Introducing a bogus citation (e.g. `[HAP-Pairing §99]`) makes it exit non-zero
  and name the offending file:line.
- `make check` still passes; the new unit test runs under `make test`.
- CI Check workflow includes the spec-coverage step.
