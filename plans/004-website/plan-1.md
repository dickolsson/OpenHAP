# Phase 1 — Skeleton, look and feel, build system

Establish `web/`, the page chrome, the stylesheet, and the `make web` target,
then prove the whole approach with the pages that need no man-page machinery.
Ships a complete, navigable four-page site.

## Tasks

### 1.1 Page chrome

- `web/head.html` — HTML5 doctype, `<meta charset="utf-8">`, a viewport meta,
  `<title>@TITLE@ — OpenHAP</title>`,
  `<link rel="stylesheet" href="style.css">`, then the opening `<body>`, the
  site banner, and the navigation bar. Nav is a single line of six links,
  separated by a middot, identical on every page: `OpenHAP` (`index.html`),
  `Install` (`install.html`), `Manuals` (`manuals.html`), `OpenHVF`
  (`openhvf.html`), `FuguLib` (`fugulib.html`), `GitHub` (the repository URL).
- `web/foot.html` — an `<hr>`, the copyright line, the ISC licence note, and the
  closing tags. No "generated at" timestamp: it would make the build
  non-reproducible for no reader benefit.
- `manuals.html` does not exist until phase 2. Ship the nav link anyway and
  create the page in phase 2 — a dead link inside a single-phase window is worse
  than a stub, so phase 1 emits a placeholder `manuals.html` saying the manuals
  are not yet published, replaced wholesale in phase 2.

### 1.2 `web/mkpage.sh`

Ten-line `sh` script, `set -eu`, one argument:

```sh
title=$1
sed "s/@TITLE@/$title/" web/head.html
cat
cat web/foot.html
```

It reads the body fragment from stdin so every renderer in later phases can pipe
into it unchanged. Reject a missing or empty `$1` with a usage line and non-zero
exit; do not attempt to escape `sed` metacharacters — instead assert in the test
that no title contains `/`, `&`, or a newline.

### 1.3 Stylesheet

`web/style.css`, hand-written, no preprocessor, targeting the openbsd.org look
described in the design:

- `body { font-family: "Times New Roman", Times, serif; background: #fff; color: #000; max-width: 55em; }`
  — left-aligned, not centred.
- Links `#23238e` for `:link` and `:visited` alike, `#ff0000` for `:active`.
  Underlined. No hover animation.
- `pre`, `code`, `tt`: `"Courier New", monospace`, a thin border and a very pale
  background for block code.
- Headings: bold serif with a pale band behind `h1`/`h2`, `<hr>` as a section
  rule.
- A reserved, commented-out block for the mandoc class names — filled in during
  phase 2 once there is real mandoc output to style. Do not guess at it now.

### 1.4 Hand-written pages

Body fragments only, no chrome:

- `web/index.body.html` — what OpenHAP is, the feature list, a quick-start
  block, and links onward to Install and Manuals. This is site-specific framing
  and the one place prose is written by hand; keep it short and do not paste
  `README.md` into it.
- `web/openhvf.body.html` — OpenHVF as the QEMU harness for OpenBSD integration
  testing, stating plainly that it is a development tool, not shipped, and not
  part of any release.
- `web/fugulib.body.html` — FuguLib as generic OpenBSD-style daemon utilities
  (daemonize, privilege drop, signals, logging, process, state).

Each ends with a pointer to its manuals, which phases 2–4 make live.

### 1.5 Markdown rendering

- `install.html` is rendered from `INSTALL.md` with `lowdown -Thtml` piped into
  `mkpage.sh`. `INSTALL.md` is not edited and not copied.
- Add `lowdown` as a **develop** dependency for all three platforms using the
  `add-dependency` skill. It is build-time only and never reaches an installed
  OpenHAP.
- Confirm during implementation that lowdown's default output nests cleanly
  inside our chrome (no `<html>`/`<body>` wrapper). If it emits a full document,
  use its standalone-suppressing invocation rather than post-processing.

### 1.6 Make integration

In the top-level `Makefile`, using only constructs already present (`?=`, `!=`,
`%` pattern rules — no `$(wildcard)`, which OpenBSD make lacks):

- `WEBOUT ?= web/build` — overridable so the test can build to a temp directory.
- `web:` builds every page listed above into `$(WEBOUT)` and copies
  `web/style.css` there.
- `web-clean:` removes `$(WEBOUT)`; add it as a prerequisite of `clean`.
- Add `web` and `web-clean` to `.PHONY`.
- `web/build` is already covered by the existing `build/` line in `.gitignore`;
  confirm this rather than adding a redundant rule.
- Do **not** add `web` to `check`, `install`, or `package`.

### 1.7 Test

`t/web/site.t`, following the unit-test convention:

- `plan skip_all` unless `lowdown` is on `PATH`.
- Build with `make web WEBOUT=<tempdir>`; skip if `make` itself is unavailable.
- Assert: each expected file exists and is non-empty; no output contains a
  literal `@TITLE@`; every `href` that is not absolute resolves to a file in the
  output directory; every page contains the six nav links.
- Add `prove -l -v t/web/*.t` to the `test` target in the Makefile.

## Deliverables

- `web/head.html`, `web/foot.html`, `web/style.css`, `web/mkpage.sh`
- `web/index.body.html`, `web/openhvf.body.html`, `web/fugulib.body.html`
- `Makefile` — `WEBOUT`, `web`, `web-clean`, `clean`, `test`, `.PHONY`
- `deps/{OpenBSD,Linux,Darwin}.txt` — `develop pkg lowdown`
- `t/web/site.t`

## Acceptance criteria

- `make web` on a clean checkout produces `index.html`, `install.html`,
  `openhvf.html`, `fugulib.html`, a placeholder `manuals.html`, and `style.css`
  in `web/build`, and writes nothing outside it.
- Running `make web` twice produces byte-identical output.
- `install.html` reflects `INSTALL.md`; editing `INSTALL.md` and rebuilding
  changes it, and no installation prose exists under `web/`.
- Every page reaches every other page through the nav; opening
  `web/build/index.html` with `file://` renders correctly with no console errors
  and no network requests.
- The site renders legibly with CSS disabled and in a text browser.
- `make web-clean` and `make clean` both leave no `web/build`.
- `make check` stays green; `prove -l t/web/site.t` passes, and skips cleanly on
  a host without `lowdown`.
