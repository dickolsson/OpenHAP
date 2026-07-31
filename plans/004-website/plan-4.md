# Phase 4 — OpenHAP module manuals from POD

Publish the 25 `.pod` sidecars under `lib/OpenHAP/` as manual pages, so the
protocol, crypto, and device modules are browsable alongside everything else.
Unlike phase 3 this is pure plumbing: the documentation already exists and is
not rewritten, only rendered. Depends on phase 2.

## Tasks

### 4.1 The `pod2man | mandoc` pipeline

`pod2man` is core Perl, so this adds no dependency:

```
pod2man --section=3p --name='<Module::Name>' --center='OpenHAP Programmer'"'"'s Manual' \
    --release='OpenHAP' <pod> \
  | mandoc -Thtml -O fragment,man='%N.%S.html;https://man.openbsd.org/%N.%S' \
  | web/mkpage.sh '<Module::Name>(3p)' > $(WEBOUT)/<Module.Name>.3p.html
```

- `--center` and `--release` fill mandoc's header and footer bars, so POD pages
  and mdoc pages get the same chrome instead of `pod2man`'s defaults.
- `--name` must be given explicitly; `pod2man` would otherwise derive it from
  the filename and produce `Heater(3p)` rather than
  `OpenHAP::Tasmota::Heater(3p)`.
- Name and filename derive mechanically from the path under `lib/`: strip
  `.pod`, then `/` → `::` for the name and `/` → `.` for the filename.

### 4.2 Enumerating the sidecars

The list must not be hand-maintained — a sidecar added without a matching
Makefile line would silently never publish.

- `POD != find lib/OpenHAP -name '*.pod' | sort`. `!=` is already used in the
  Makefile (`UNAME != uname`) and works in both OpenBSD and GNU make;
  `$(wildcard)` does not and must not be used. `sort` keeps the build
  reproducible against filesystem ordering.
- Because the output filename is not a suffix transformation of the input, a `%`
  pattern rule cannot express this. Use a single bulk target that loops over
  `$(POD)` in `sh`. Incrementality is irrelevant here — 25 pages render in well
  under a second — and one loop is simpler than 25 generated rules.
- `lib/OpenHAP/Test/*` sidecars document test helpers that ship only in the
  packaged tree. Include them; they are part of the module reference and
  excluding them means maintaining an exclusion list.
- `lib/FuguVM/` has no sidecars today. If any appear, they belong in this same
  loop — but FuguVM is development-only, so decide at that point rather than
  writing speculative rules now.

### 4.3 Index and navigation

- `mkindex.sh` gains an "OpenHAP modules" group. With ~25 entries this is the
  longest group on the page; sort by module path so `OpenHAP::Tasmota::*`
  cluster together.
- Descriptions come from the POD `=head1 NAME` line ("Module - description"),
  parsed rather than retyped.
- Distinguish the three OpenHAP manuals from phase 2 (`openhapd(8)`,
  `hapctl(8)`, `openhapd.conf(5)`) from the module reference. They are different
  audiences — operators and programmers — and mixing them in one
  undifferentiated list serves neither.

### 4.4 Known limitation

`pod2man` renders `L<FuguLib::Signal>` as plain italic text, not a link, so POD
pages do not cross-reference each other the way phase 2's mdoc pages do. This is
accepted, not worked around: making it work would mean post-processing mandoc's
HTML, which trades a cosmetic gain for a fragile build. Record it in
`web/CLAUDE.md` (phase 5) so it is not rediscovered as a bug.

## Deliverables

- `Makefile` — `POD` enumeration, bulk render target
- `web/mkindex.sh` — OpenHAP modules group
- `web/index.body.html` — pointer to the module reference
- `t/web/site.t` — extended

## Acceptance criteria

- `make web` renders one page per `.pod` under `lib/OpenHAP/`, and the count of
  output pages equals the count of sidecars — asserted in the test, not
  eyeballed.
- Adding a new `.pod` sidecar and rebuilding publishes it and lists it in
  `manuals.html` with no Makefile or HTML edit.
- Page titles and header bars read `OpenHAP::Tasmota::Heater(3p)`, not
  `Heater(3p)`, and POD pages are visually indistinguishable in chrome from mdoc
  pages.
- Every `manuals.html` description matches the sidecar's `=head1 NAME` line.
- `make web` output remains byte-identical across runs and independent of
  filesystem ordering.
- `make check` stays green.
