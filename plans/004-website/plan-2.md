# Phase 2 — mdoc manuals on the web

Render the four in-tree mdoc(7) pages to HTML and give them an index. This is
the phase that makes the site worth publishing: `man/` becomes browsable without
a checkout, from exactly one source. Depends on phase 1.

## Tasks

### 2.1 Staging directory

mandoc's `-O man=local;remote` chooses the first template only when a file named
`%N.%S` exists **in the current working directory** (mandoc(1), `man=`). Our
four sources are split across `man/openhap/` and `man/fuguvm/`, so no single
directory sees them all and every `.Xr` would fall through to the remote
template.

- `web` copies `$(MAN1) $(MAN5) $(MAN8)` into `$(WEBOUT)/.man/` before
  rendering, and runs mandoc with that as the working directory.
- The staging directory is an implementation detail of the build and is removed
  at the end of the `web` target, so it never appears in the published tree.
  Verify it is gone in `t/web/site.t` — a stray `.man/` would publish the mdoc
  sources as if they were content.

### 2.2 Rendering

One rule per manual, matching the existing `%.cat1: %.1` idiom rather than
inventing a new mechanism:

```
mandoc -Thtml -O fragment,man='%N.%S.html;https://man.openbsd.org/%N.%S' \
    <page> | web/mkpage.sh '<name>(<section>)' > $(WEBOUT)/<name>.<section>.html
```

- Outputs: `openhapd.8.html`, `hapctl.8.html`, `openhapd.conf.5.html`,
  `fuguvm.1.html`.
- Page title is the manual's own `name(section)` form — `openhapd(8)`, not
  "Openhapd Manual". The site chrome supplies the rest.
- Run mandoc with `-W warning` so a malformed page fails the build instead of
  silently producing degraded HTML. The four current pages emit
  `unusual Xr order` and `sections out of conventional order` warnings today;
  either fix those pages in this phase or set the threshold at `-W error`.
  Fixing them is preferred — they are trivial reorderings and they are real mdoc
  style defects.

### 2.3 Cross-reference verification

Confirm empirically, not by reading the manual page, that:

- `.Xr openhapd 8` inside `hapctl.8` links to `openhapd.8.html`.
- `.Xr pledge 2` links to `https://man.openbsd.org/pledge.2`.

If mandoc's two-template behaviour does not discriminate as documented, fall
back to a single local template plus an explicit list of known-external pages —
but do not post-process mandoc's HTML with `sed`. Record whichever way it went
in `web/CLAUDE.md` (phase 5).

### 2.4 `web/mkindex.sh` and `manuals.html`

- `web/mkindex.sh <manpage>...` emits the body of `manuals.html`: a heading per
  project (OpenHAP, FuguVM; FuguLib and the OpenHAP modules arrive in phases 3
  and 4) and, under each, a definition list of `name(section)` linked to its
  page with the one-line description.
- Take the description from the page's `.Nd` macro rather than retyping it —
  `mandoc -Tman` or a `.Nd`-targeted read of the source. Retyping it here would
  create the second copy this whole design exists to avoid.
- Grouping is by source directory (`man/openhap/`, `man/fuguvm/`,
  `man/fugulib/`), which is already how the tree is organised — no separate
  mapping table to maintain.
- Replaces the phase 1 placeholder `manuals.html` entirely.

### 2.5 Stylesheet

Fill in the block reserved in phase 1 with real mandoc class rules, written
against actual output rather than guessed: `.head` and `.foot` as the running
header/footer bars, `.manual-text` as the body, `.Sh`/`.Ss` headings, and the
inline semantic classes `.Nm`, `.Fl`, `.Ar`, `.Cm`, `.Pa`, `.Ev`, `.Er`, `.Va`,
`.Dv`, `.Fn`, `.Ic`. Bold, italic, and monospace are the whole vocabulary — the
target is a manual page, not a syntax-highlighted document.

Keep mandoc's `permalink` anchors working: they are the only navigation inside a
long page and cost nothing.

### 2.6 Dependency

Add `mandoc` as a **develop** dependency via the `add-dependency` skill.
`MANDOC ?= mandoc` already exists in the Makefile for `make man`, but mandoc
appears in no `deps/*.txt` — it is in OpenBSD and Darwin base, and needs the
`mandoc` package on Linux.

## Deliverables

- `Makefile` — `.man/` staging, four render rules, `manuals.html`
- `web/mkindex.sh`
- `web/style.css` — mandoc classes
- `man/openhap/*`, `man/fuguvm/*` — mdoc style-warning fixes
- `deps/Linux.txt` — `develop pkg mandoc`
- `t/web/site.t` — extended

## Acceptance criteria

- `make web` produces the four manual pages plus `manuals.html`; each renders
  with the site's typography and is recognisable as a manual page.
- Every manual is linked from `manuals.html`, and every `.Nd` description shown
  there matches the source page.
- Local `.Xr` targets link to local files; non-local ones link to
  man.openbsd.org. Verified by test, not by inspection.
- `mandoc -W warning` is clean for all four pages, and the build fails if a page
  later regresses.
- `$(WEBOUT)/.man/` does not exist after `make web`.
- Editing a `.Nd` line and rebuilding changes both the manual page and
  `manuals.html`, with no other file touched.
- `make check` stays green.
