# Phase 5 — Fugu::Timeout, and the documentation pass

This phase removes the last general noun from the tree, and finishes the
documentation. After it, every module name in the repository says what the
module does, and no document names a namespace that no longer exists.

The phase depends on phases 1 to 3. It does not depend on phase 4.

## Tasks

### 5.1 Fugu::Util becomes Fugu::Timeout

- `Fugu::Util` holds three functions that share no idea: `bounded`,
  `wait_until`, and `format_size`. The name hides that.
- `git mv lib/Fugu/Util.pm lib/Fugu/Timeout.pm`. The module keeps `bounded` and
  `wait_until`, which are one idea: run something under a time limit.
- Users of the two: `Fugu::SSH`, `Fugu::MQTT`, `Fugu::Proxy`,
  `App::FuguVM::Guest`, and `App::FuguVM::QGA`.
- `git mv man/fugu/Util.3p man/fugu/Timeout.3p`, and rewrite it for the two
  functions. Update `MAN3P` in the `Makefile` and every `.Xr` that names the
  page.
- `git mv t/fugu/util.t t/fugu/timeout.t`.

### 5.2 format_size moves to its only caller

- `App::FuguVM::CLI` calls `format_size` six times. Nothing else calls it.
- Move the function into `App::FuguVM::CLI` as the private `_format_size`.
  Delete it from the module, from the manual page, and from the export list.
- Move its subtests from `t/fugu/util.t` into `t/fuguvm/cli.t`. Keep the same
  cases: the byte, kilobyte, megabyte, and gigabyte boundaries, and the
  undefined argument.

### 5.3 Rewrite the website text

- `web/fugu.body.html`: replace the `Fugu::Util` entry with `Fugu::Timeout`, and
  correct its description. Add the `Fugu::Imsg` entry for the smaller module if
  phase 4 has landed.
- `web/index.body.html`: confirm that the namespace names and the links match
  the tree.
- `t/web/site.t`: confirm the page list, the module-manual match, and the `.Xr`
  assertions after all five phases.

### 5.4 Finish the project documentation

- Root `CLAUDE.md`: the introduction now names `App::OpenHAP`, `App::FuguVM`,
  `Fugu`, `Protocol::HAP`, and `Protocol::Imsg`. Rewrite the four-namespace
  paragraph, the Layout list, and row 2 of the documentation table.
- `README.md` and `INSTALL.md`: every module name.
- `t/CLAUDE.md`: the tier table and the mock example.
- `t/openhap/integration/CLAUDE.md`: the module names in the rules.
- Leave `plans/001` to `plans/007` as they are. They record what was true when
  they were written.

### 5.5 Record the release work in TODO.md

Replace the `Protocol::HAP CPAN release` section with one section for the whole
tree. It lists what a release of any distribution here still needs:

- A distribution main module for `App-OpenHAP` and for `App-FuguVM`. PAUSE
  grants indexing permission on that module first, and neither exists today.
- A `$VERSION` policy. No module in the repository carries one, and PAUSE does
  not index a module without a version.
- `no_index` metadata for the packages that live inside another file:
  `Protocol::HAP::Log::Null`, `Protocol::HAP::SRP::Client`,
  `Fugu::Control::Client`, `Fugu::Proxy::Cache`, `Fugu::Proxy::Meta`, and
  `App::FuguVM::Proxy::Cache`.
- Distribution tooling: `Makefile.PL` or `Build.PL`, `MANIFEST`, and
  distribution tests.
- The redistribution-license review of `spec/`.
- The open naming question: `Fugu::MQTT`, `Fugu::MDNS`, `Fugu::SSH`, and
  `Fugu::Proxy` may belong under `Net::` or `HTTP::`. Each needs a study of the
  existing module in that namespace before it moves.
- The descriptor-passing subset of `Protocol::Imsg`, from phase 4.

### 5.6 Sweep the tree

Run the greps from every phase one more time, from the repository root, with
`plans/` excluded. Each must find nothing:

```sh
grep -rn 'FuguLib\|fugulib' --exclude-dir=.git --exclude-dir=plans .
grep -rn 'OpenHAP::' --exclude-dir=.git --exclude-dir=plans . | grep -v 'App::'
grep -rn 'FuguVM::' --exclude-dir=.git --exclude-dir=plans . | grep -v 'App::'
grep -rn 'Fugu::Util\|FuguVM::VM\|FuguVM::Expect' --exclude-dir=.git \
    --exclude-dir=plans .
```

## Deliverables

- `lib/Fugu/Timeout.pm`, `man/fugu/Timeout.3p`, and `t/fugu/timeout.t`.
- `App::FuguVM::CLI` with the private `_format_size`, and the moved subtests in
  `t/fuguvm/cli.t`.
- Updated `web/fugu.body.html`, `web/index.body.html`, root `CLAUDE.md`,
  `t/CLAUDE.md`, `t/openhap/integration/CLAUDE.md`, `README.md`, `INSTALL.md`,
  and `TODO.md`.

## Acceptance criteria

- `make check` passes.
- The four greps in task 5.6 find nothing.
- `grep -rn 'format_size' lib/Fugu man/fugu` finds nothing.
- `make web` builds, and `t/web/site.t` passes with the final page list.
- `make install DESTDIR=...` into an empty directory produces only `App/`,
  `Fugu/`, and `Protocol/` under `$(LIBDIR)`, and only `Fugu::*.3p` under
  `man3p/`.
- `make integration` passes.
- The repository contains no alias, no `@ISA` bridge, no compatibility module,
  and no migration note for an older install.
