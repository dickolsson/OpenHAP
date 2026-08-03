# Phase 1 — The page assembler

This phase creates the `App::FuguWeb` namespace and the `.fuguwebrc` file. It
moves the shared chrome out of `web/` and into the tool. The `Makefile` still
drives the build, but it calls `fuguweb page` in place of `web/mkpage.sh`.

Plan 008 must land first. This phase names `Fugu::` modules and the `fugu.html`
page, and neither exists before it.

## Tasks

### 1.1 The umbrella module

- Create `lib/App/FuguWeb.pm`. It holds the namespace overview comment, the
  `CONFIG_FILE` constant, and the HTML escape that the other modules share.
  Multiple packages in one file follow the style rules.
- Create the `App/FuguWeb.pod` sidecar: what the tool is, the shape of
  `.fuguwebrc`, and pointers to the per-module pods.
- No `$VERSION`. Version policy is release work.

### 1.2 App::FuguWeb::Config

- Wrap `Fugu::Config`. The class reads `.fuguwebrc`, applies the defaults, and
  validates the result.
- Settings and their defaults: `site` (required), `banner` (defaults to `site`),
  `lang` (`en`), `out_dir` (`web/build`), `source_dir` (`web`), `entry`
  (`index.html`), `module_root` (`lib`), `pod_center`, `pod_release`,
  `mandoc_os` (`OpenBSD`), `man_url` (`https://man.openbsd.org/`).
- Accessors: `root`, `path`, `source_path`, one accessor for each setting, `nav`
  (ordered list of `{ href, label }`), and `pages` (ordered list of
  `{ file, title, source, value, unlinked }`).
- `App::FuguWeb::Config->load(%args)` finds the root with
  `Fugu::Config->find_project_root('.fuguwebrc')`, unless `root` says otherwise.
  It returns undef and records the reason when the file is absent or does not
  parse.
- Reject a page block that names no source, or more than one source. Reject a
  page file that two blocks declare. Reject a nav block with no label. Reject a
  path setting that holds `..`, because a build must not write outside the
  project. Name the file and the block in every message.
- The manual and module groups arrive in phase 2. This phase ignores those
  blocks.

### 1.3 App::FuguWeb::Page

- `App::FuguWeb::Page->new(config => $config)`.
- `$page->document($title, $fragment)` returns the whole page as bytes.
- `$page->write($path, $title, $fragment)` writes it with `Fugu::File`.
- The chrome reproduces `web/head.html` and `web/foot.html` exactly: the
  doctype, the `lang` attribute, the two meta elements, the title, the
  stylesheet links, the banner, the navigation, a rule, `<main>`, the fragment,
  a rule, the footer, and the closing tags.
- Two separators are not ASCII: the em dash between the title and the site name
  (`\xe2\x80\x94`) and the middle dot between navigation entries (`\xc2\xb7`).
  Define both as byte constants. The file carries no `use utf8`, so the bytes
  reach the output unchanged.
- Escape `&`, `<`, and `>` in the title and in every navigation label. The `sed`
  restriction on `/` and `&` goes away with `mkpage.sh`.
- Read the footer from `<source_dir>/footer.body.html` when that file exists.
  Emit no `<footer>` element when it does not.
- Link `<source_dir>/extra.css` after `style.css` when that file exists.

### 1.4 App::FuguWeb::CLI and bin/fuguweb

- Copy the shape of `App::FuguVM::CLI`: a `%COMMANDS` table, a `_prepare` method
  that applies the global options and loads the configuration, and one `cmd_`
  method for each command.
- This phase implements `page` only. `page <title>` reads a fragment on standard
  input and writes the document to standard output.
- Global options: `--project` (the project root) and `--quiet`.
- Exit codes: import the five generic codes from `Fugu::CLI`. Add
  `EXIT_RENDER_FAILED => 4`, `EXIT_CHECK_FAILED => 5`, and
  `EXIT_TOOL_MISSING => 6`.
- `bin/fuguweb` copies `bin/fuguvm`: the ISC header, `FindBin`, `use lib`, and
  one `exit` line. Give it mode 755.

### 1.5 The configuration file

- Write `.fuguwebrc` with the settings, the six `nav` blocks, and the six `page`
  blocks. The titles come from the `Makefile` recipe, unchanged. The navigation
  names `fugu.html`, which plan 008 phase 1 created.
- Move the licence sentence from `web/foot.html` into `web/footer.body.html`.
- Delete `web/mkpage.sh`, `web/head.html`, and `web/foot.html`.

### 1.6 The Makefile

- Add `FUGUWEB ?= bin/fuguweb`. Replace `MKPAGE = web/mkpage.sh` with it.
- Replace every `$(MKPAGE) '<title>'` call with `$(FUGUWEB) page '<title>'`.
- Everything else in the `web` target stays until phase 3. `mkindex.sh` still
  runs, and it still pipes into the assembler, so the target works throughout.

### 1.7 Tests

- Add `t/fuguweb/boundary.t`. It parses `use` and `require` lines under
  `lib/App/FuguWeb/` and fails on `App::OpenHAP`, `App::FuguVM`, or
  `Protocol::`, and on any non-core module outside `Fugu::`. It also reads
  `lib/App/OpenHAP/` and `lib/App/FuguVM/` and fails on a file that names
  `App::FuguWeb`. A sibling application is not a library.
- Add `t/fuguweb/config.t`: the defaults, a page block with two sources, a page
  declared twice, a nav block with no label, a path that holds `..`, an absent
  file, and a parse error with a line number.
- Add `t/fuguweb/page.t`: the chrome, the two byte constants, the escaping of a
  title that holds `&` and `<`, the optional footer, and the optional
  `extra.css`.
- Add `prove -l -v t/fuguweb/*.t` to the `test` target, after the `t/fuguvm`
  line. Add the tier row to `t/CLAUDE.md`.

## Deliverables

- `bin/fuguweb`, `lib/App/FuguWeb.pm`, `lib/App/FuguWeb/{Config,Page,CLI}.pm`,
  each with a `.pod` sidecar.
- `.fuguwebrc` and `web/footer.body.html`.
- `t/fuguweb/{boundary,config,page}.t`.
- Updated `Makefile` and `t/CLAUDE.md`.
- Deleted `web/mkpage.sh`, `web/head.html`, and `web/foot.html`.

## Acceptance criteria

- `make check` passes.
- `make web WEBOUT=<tmp>` gives a tree that `diff -r` reports as identical to
  the reference build.
- `prove -l t/web/site.t` passes with no change to that file.
- `git grep -n 'mkpage\|head\.html\|foot\.html' -- Makefile web t` finds
  nothing.
- `fuguweb page 'A & B'` produces a correct title. Prove it once by hand: the
  old `sed` would have mangled it.
