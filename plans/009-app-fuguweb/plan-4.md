# Phase 4 — The checks and the documentation

This phase moves the generic site checks into the tool, so every project gets
them. It then updates every document, workflow, and manifest that the three
earlier phases changed.

## Tasks

### 4.1 App::FuguWeb::Check

- `App::FuguWeb::Check->new(config => $config, out => $dir)`.
- `$check->run` returns a list of problems. Each problem names the page and says
  what is wrong. An empty list means the site is good.
- The checks come from the generic half of `t/web/site.t`:
  - every expected page and asset exists and is not empty;
  - no page holds an unsubstituted `@TITLE@`;
  - every page has a title;
  - every page carries the whole navigation;
  - no reference starts with `/`, because the host may serve the site from a
    path below the root;
  - no reference uses a `file:` URL;
  - every relative reference resolves to a file in the output;
  - every fragment resolves to an `id` on the target page;
  - no relative href reads as a URL scheme, so every local link keeps its `./`;
  - no local `.Xr` cross-reference dangles;
  - every page is reachable from `entry`, except a page marked `unlinked`;
  - the output holds the site and nothing else.
- The check never fetches a link. It collects the external links and reports
  them, because the build and its checks touch no network.

### 4.2 The CLI

- Add the `check` command. It takes `--out <dir>`.
- The command prints one line for each problem to standard error and exits with
  `EXIT_CHECK_FAILED`. It exits 0 and says nothing when the list is empty.
- Add `--verbose`, which also notes every external link.

### 4.3 t/web/site.t

- The file keeps its tooling-tier rule: it drives subprocesses and asserts on
  exit status and output. It does not load a module from `lib/`.
- It runs `make web WEBOUT=<tmp>`, then `bin/fuguweb check --out <tmp>`, and
  asserts that both exit 0.
- It keeps only the OpenHAP-specific assertions:
  - `install.html` carries content from `INSTALL.md`;
  - `hapctl.8.html` links `.Xr openhapd 8` locally and sends `.Xr rc 8` to the
    manual host;
  - `Fugu::Daemon.3p.html` links `.Xr Fugu::Pidfile 3p` locally;
  - every manual source in `man/` and every `.pod` sidecar under `lib/` produces
    a page, and the index shows its description verbatim;
  - two builds give the same bytes.
- Delete `@SITE`, `@ASSETS`, and `@NAV`. `App::FuguWeb::Check` gets those from
  `.fuguwebrc`, so the third copy of the page list goes away.
- The discovery loop at the top matches `man/([^/]+)/` and applies the `Fugu::`
  prefix for one directory. Replace that special case with the group namespaces
  that `.fuguwebrc` declares, read as text. Plan 008 had to edit this same rule;
  nobody should edit it again.

### 4.4 The manual page

- Write `man/fuguweb/fuguweb.1` in mdoc(7). Model it on `man/fuguvm/fuguvm.1`:
  `NAME`, `SYNOPSIS`, `DESCRIPTION` with a tagged list of the subcommands,
  `FILES` for `.fuguwebrc` and `share/fuguweb/style.css`, `EXIT STATUS`,
  `EXAMPLES`, `SEE ALSO`, and `AUTHORS`.
- Add it to `MAN1` in the `Makefile`. `install-man` does not ship `MAN1` today,
  and `fuguweb` is a development tool, so that stays true.
- Add a `manuals "FuguWeb"` group to `.fuguwebrc` for `man/fuguweb`, with the
  anchor `fuguweb`. The page then reaches the site and the index.

### 4.5 Documentation

- Rewrite `web/CLAUDE.md` for the new shape: what `web/` holds, how `.fuguwebrc`
  describes the site, and how to add a page or a manual. Keep the five findings;
  point at the code that carries each one.
- Update the root `CLAUDE.md`:
  - add `App::FuguWeb::` to the namespace list that plan 008 rewrote, with one
    line on its purpose;
  - add `lib/App/FuguWeb/`, `bin/fuguweb`, `man/fuguweb/`, and the `t/fuguweb/`
    tier to the Layout section;
  - correct the sentence that says the site renders `README.md`. It renders
    `INSTALL.md`; the front page is hand-written framing.
- Add the `t/fuguweb/` row to the tier table in `t/CLAUDE.md`, if phase 1 has
  not already.
- Extend `t/scripts/namespaces.t` with the retired file names: `mkpage.sh`,
  `mkindex.sh`, `web/head.html`, `web/foot.html`, and `web/style.css`. Plan 008
  built that gate for retired module names; the same clean-break rule covers a
  retired script.
- Record the CPAN release work in `TODO.md`, under a new "App::FuguWeb CPAN
  release" section beside the sections that plan 008 leaves there.

### 4.6 CI and dependencies

- Update both path filters in `.github/workflows/web.yml`:
  - drop `web/*.sh`;
  - add `lib/App/FuguWeb/**`, `bin/fuguweb`, `.fuguwebrc`, `share/fuguweb/**`,
    and `t/fuguweb/**`.
- The workflow installs `lowdown` and `mandoc` from apt and uses the system
  perl. `fuguweb` needs no CPAN module, so that step does not change.
- Confirm that `.github/workflows/web.yml` still uploads `web/build`. The
  artifact path repeats the `WEBOUT` default; a change to one needs a change to
  the other.
- Add `develop pkg mandoc` to `deps/Darwin.txt`. The manifest lacks it today,
  and the web build needs it on every platform except OpenBSD, where it is in
  the base system.
- Check the path filters in `check.yml` and `test.yml`. They must watch
  `lib/App/**` and `t/fuguweb/**`.

### 4.7 Tests

- Add `t/fuguweb/check.t`. Build a small broken site in a `File::Temp` directory
  and assert one problem for each check: a dead link, a dead fragment, a
  root-absolute reference, a link that reads as a scheme, an unreachable page,
  and a stray file in the output.

## Deliverables

- `lib/App/FuguWeb/Check.pm` with its `.pod` sidecar.
- `man/fuguweb/fuguweb.1`.
- `t/fuguweb/check.t`, and the shrunk `t/web/site.t`.
- Updated `web/CLAUDE.md`, `CLAUDE.md`, `t/CLAUDE.md`, `TODO.md`, `Makefile`,
  `.fuguwebrc`, `t/scripts/namespaces.t`, `.github/workflows/web.yml`, and
  `deps/Darwin.txt`.

## Acceptance criteria

- `make check` passes.
- `make web WEBOUT=<tmp>` gives a tree that `diff -r` reports as identical to
  the phase-3 output, plus the new `fuguweb.1.html` page and its index entry.
- `make web && bin/fuguweb check --out web/build` exits 0.
- A dead link in a body fragment fails `fuguweb check` and names the link. Prove
  it once by hand.
- `git grep -n 'mkpage\|mkindex' -- . ':!plans'` finds nothing.
- `make spec-coverage` reports no stale citation.
- `make install DESTDIR=<empty dir>` succeeds and installs no `App/FuguWeb`
  file, as it installs no `App/FuguVM` file.
