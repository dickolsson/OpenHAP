# Phase 3 — The whole build

This phase moves the rest of the `web` target into the tool. After this phase
the target runs one command, and `web/` holds content only.

## Tasks

### 3.1 A working directory for Fugu::Process

`Fugu::Process->run` runs its child in the working directory of the caller.
`mandoc` resolves a `.Xr` target against the working directory, so the staging
trick needs a child that starts somewhere else. A `chdir` in the parent would
race every other relative path in the build.

- Add a `cwd => $dir` option to `Fugu::Process->run` and to `_run_passthrough`.
  The child calls `chdir` after the fork and before the `exec`, and reports a
  failure through the existing exec pipe.
- Update `man/fugu/Process.3p` with the new option.
- Add a subtest to `t/fugu/process.t`: the child runs in the named directory,
  and a directory that does not exist fails with a message and not a silent run
  in the wrong place.
- This is the only change outside `App::FuguWeb` in this phase. The option is
  generic, so it belongs in the nexus, not in a copy inside the tool.

### 3.2 App::FuguWeb::Render

- One class for the three external renderers. It runs them with
  `Fugu::Process->run` and returns the output as bytes.
- `$render->probe` checks `mandoc`, `lowdown`, and `pod2man`. It returns the
  name of the first tool that is absent. The caller reports the name and exits
  with `EXIT_TOOL_MISSING`.
- `$render->lint(@paths)` runs `mandoc -Tlint -W warning`. A malformed page must
  fail the build, not render badly.
- `$render->markdown($path)` runs `lowdown -Thtml`.
- `$render->mdoc($file, $dir)` runs `mandoc` with `cwd => $dir` and the shared
  HTML options. The directory decides whether a `.Xr` target becomes a local
  link or a link to the manual host.
- `$render->pod($path, $name, $date)` runs
  `pod2man --section=3p --name --date --center --release` and feeds the result
  to `mdoc` as standard input.
- The HTML options come from the configuration: `-I os=<mandoc_os>` and
  `-O fragment,man='./%N.%S.html;<man_url>%N.%S'`. The `-I os=` flag pins the
  footer, so the site does not vary with the build host.
- The tool names are overridable, so a caller can name another binary.

### 3.3 App::FuguWeb::Site

- `App::FuguWeb::Site->new(config => $config, out => $dir)`.
- `$site->build` runs the whole pipeline:
  1. probe the renderers;
  2. lint every mdoc source;
  3. create the output directory and the `.man/` staging directory inside it;
  4. copy every mdoc source into the staging directory under its staged name;
  5. copy the base stylesheet and every asset;
  6. render each `page` block;
  7. render one page for each manual in each group;
  8. remove the staging directory.
- `$site->clean` removes the output directory.
- `$site->pod_date` returns the date of the last commit, and today's date when
  git does not answer. git does not preserve file times, so a file time would
  make the build vary.
- Create the output directory explicitly. The current recipe gets it as a side
  effect of `mkdir -p $(WEBOUT)/.man`, which breaks the moment the staging step
  moves or goes away.
- The staging directory lives inside the output directory and never reaches the
  published tree.

### 3.4 The stylesheet

- `git mv web/style.css share/fuguweb/style.css`. The content does not change.
- `Site` finds it with `Fugu::File->share_path('share/fuguweb/style.css')` and
  copies it to `<out>/style.css`.
- Add a `stylesheet` setting to `App::FuguWeb::Config`. It names the base sheet
  and overrides the search. `share_path` finds the sheet in a checkout, but not
  in an installed CPAN distribution, so a project must have a way to say where
  the file is.
- Fail the build with a named path when the stylesheet is not found. A site with
  no stylesheet must not look like a success.
- **`web/` now holds content only:** the `*.body.html` files, `robots.txt`,
  `CNAME`, and `CLAUDE.md`.

### 3.5 The CLI

- Add the `build` and `clean` commands. Both take `--out <dir>`, which overrides
  `out_dir` from the configuration.
- Add the `init` command. It writes a starter `.fuguwebrc` into a directory that
  holds none, as `fuguvm init` does.

### 3.6 The Makefile

- Cut `web` and `web-clean` down to one command each.
- Delete `LOWDOWN`, `MANDOC`, `POD2MAN`, `MKPAGE`, `WEBMAN`, and `MANHTML`.
- Keep `WEBOUT`: `t/web/site.t` and `.github/workflows/web.yml` both set it.
- Keep `MAN1`, `MAN3P`, `MAN5`, and `MAN8`. `install-man`, `package`,
  `uninstall`, and `man` still read them.
- `MANDOC` also serves the `%.cat1`, `%.cat3p`, `%.cat5`, and `%.cat8` rules of
  the `man` target. Keep the variable if those rules still need it, and delete
  only the web use.

### 3.7 Tests

- Add `t/fuguweb/render.t`: the probe names an absent tool, the lint fails a
  malformed page, and the mdoc options carry the configured OS and manual URL.
  Skip the whole file when `mandoc` is absent.
- Add `t/fuguweb/site.t`: a small site in a `File::Temp` directory builds, holds
  the expected files, drops the staging directory, and builds a second time to
  the same bytes.
- These tests do not read the repository. `t/web/site.t` covers the real site.

## Deliverables

- `lib/App/FuguWeb/{Render,Site}.pm`, each with a `.pod` sidecar.
- `share/fuguweb/style.css`, moved from `web/style.css`.
- `t/fuguweb/{render,site}.t`.
- Updated `lib/Fugu/Process.pm`, `man/fugu/Process.3p`, `t/fugu/process.t`,
  `Makefile`, and `lib/App/FuguWeb/CLI.pm`.
- Deleted `web/style.css`.

## Acceptance criteria

- `make check` passes.
- `make web WEBOUT=<tmp>` gives a tree that `diff -r` reports as identical to
  the phase-2 output.
- `sed -n '/^web:/,/^$/p' Makefile` shows one command.
- `ls web/` shows only `*.body.html`, `robots.txt`, `CNAME`, and `CLAUDE.md`.
- `fuguweb build` fails and names `mandoc` when `mandoc` is not on the path.
  Prove it once by hand.
- Two builds in a row give the same bytes.
- `make man` still builds the cat pages.
