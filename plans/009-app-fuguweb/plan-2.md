# Phase 2 — The manual index

This phase moves `web/mkindex.sh` into the tool. Its group table becomes
`manuals` and `modules` blocks in `.fuguwebrc`. After this phase `web/` holds no
script.

The group table that this phase moves is the one plan 008 leaves behind. Plan
008 edited it in four of its five phases, and its design names the file as a
mechanism that fails quietly under a rename. This phase removes that failure
mode: a group whose directory does not exist becomes an error, not silence.

## Tasks

### 2.1 App::FuguWeb::Manual

- One object for one manual source. Fields: `path`, `name`, `section`, `page`,
  `description`, and `group`.
- `App::FuguWeb::Manual->from_mdoc($path, $group)` takes the section from the
  file extension. It prefixes the name with the group namespace.
- `App::FuguWeb::Manual->from_pod($path, $group, $module_root)` uses section
  `3p`. It drops the `module_root` prefix from the path and maps `/` to `::`.
- `$manual->page` is `<name>.<section>.html`.
- `$manual->description` reads the source. An mdoc page gives the argument of
  `.Nd`. A POD sidecar gives the text after `Module - ` on the first non-blank
  line that follows `=head1 NAME`. The method returns undef when neither is
  present.
- `$manual->staged_name` is the file name that the mdoc staging directory needs.
  For a group with a namespace it carries that prefix, so `man/fugu/Daemon.3p`
  stages as `Fugu::Daemon.3p`.

### 2.2 App::FuguWeb::Config, the groups

- Parse the `manuals` and `modules` blocks. Each gives `heading` (the block
  name), `anchor`, `dir`, and, for `manuals`, an optional `namespace`.
- `$config->groups` returns the groups in file order.
- `$group->manuals` reads the directory and returns `App::FuguWeb::Manual`
  objects.
- A `manuals` group globs `*.1`, `*.3p`, `*.5`, and `*.8` in its directory. It
  sorts by section, in the order 1, 3p, 5, 8, and then by file name in
  `LC_ALL=C` order. That reproduces the `$(MAN1) $(MAN3P) $(MAN5) $(MAN8)`
  argument order of the current recipe.
- A `modules` group finds every `*.pod` file below its directory and sorts by
  path in `LC_ALL=C` order. That reproduces
  `find lib -name '*.pod' | LC_ALL=C sort`, so `Store.pod` stays before
  `Store/Memory.pod`.
- The sort never reads the locale of the builder.
- Reject a group whose directory does not exist. A silent empty group hides a
  typo in a path, which is exactly how `emit_group` failed.

### 2.3 App::FuguWeb::Index

- `App::FuguWeb::Index->new(config => $config)`.
- `$index->body` returns the body fragment of `manuals.html`.
- The fragment starts with `<h1>` and the standard paragraph about the manual
  sources. A `<source_dir>/manuals.body.html` file replaces that opening when it
  exists.
- Each group emits `<h2 id="<anchor>">`, a `<dl>`, and one blank line after the
  closing `</dl>`. A group with no manual emits nothing.
- Each manual emits `<dt><a href="./<page>"><name>(<section>)</a></dt>` and
  `<dd><description></dd>`. The `./` prefix is mandatory, because a browser
  reads a relative URL whose first segment holds a colon as a scheme.
- Escape `&` and `<` in every description, as `mkindex.sh` does today.

### 2.4 The CLI

- Add the `index` command. It writes the body fragment to standard output.
- `fuguweb page 'Manuals'` still wraps it, so the `Makefile` pipes one into the
  other.

### 2.5 The configuration file

- Add three `manuals` blocks: `man/openhap` (anchor `openhap`), `man/fuguvm`
  (anchor `fuguvm`), and `man/fugu` (anchor `fugu`, namespace `Fugu::`).
- Add four `modules` blocks: `lib/App/OpenHAP` (anchor `modules`),
  `lib/App/FuguVM` (anchor `vm-modules`), `lib/Protocol` (anchor
  `protocol-modules`), and the new `lib/App/FuguWeb` (anchor `web-modules`).
- Never name `lib/App` as a `modules` directory. That one directory holds three
  namespaces, and one group would swallow all of them.
- Take each heading from the state that plan 008 leaves: `Fugu`,
  `OpenHAP modules`, `FuguVM modules`, and the heading that plan 008 phase 4
  gave to `lib/Protocol` when `Protocol::Imsg` joined it.
- Delete `web/mkindex.sh`. **`web/` now holds no script.**

### 2.6 The Makefile

- Replace `$(MKINDEX) ... | $(MKPAGE) 'Manuals'` with
  `$(FUGUWEB) index | $(FUGUWEB) page 'Manuals'`.
- Delete `MKINDEX` and `FINDPOD`.

### 2.7 Tests

- Add `t/fuguweb/manual.t`: the name and section of an mdoc page, the name of a
  nested POD sidecar, the namespace prefix, the staged name, the `.Nd`
  description, the `=head1 NAME` description, and a source with neither.
- Add `t/fuguweb/index.t`: the group order, the two sort rules, the `./` prefix,
  the escaping of `&` and `<`, an empty group, a missing directory, and the
  optional opening fragment.
- Both tests build their sources in a `File::Temp` directory. They do not read
  the repository, so a change under `man/` cannot break them.

## Deliverables

- `lib/App/FuguWeb/{Manual,Index}.pm`, each with a `.pod` sidecar.
- The group blocks in `.fuguwebrc`.
- `t/fuguweb/{manual,index}.t`.
- Updated `Makefile`, `lib/App/FuguWeb/Config.pm`, and `lib/App/FuguWeb/CLI.pm`.
- Deleted `web/mkindex.sh`.

## Acceptance criteria

- `make check` passes.
- `make web WEBOUT=<tmp>` gives a tree that `diff -r` reports as identical to
  the reference build, except for the new `App::FuguWeb` module pages and their
  index entries. Those pages are new sidecars, and the site publishes every
  sidecar.
- `ls web/*.sh` finds nothing.
- A `manuals` block that names a directory which does not exist fails the build
  and names the directory. Prove it once by hand.
