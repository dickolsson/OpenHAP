# CLAUDE.md

> **CRITICAL: Write all output and all artifacts in ASD-STE100 Simplified
> Technical English.** This rule applies to the README, `INSTALL.md`, man pages,
> `.pod` sidecars, website text, code comments, commit messages, and chat
> replies. Use the active voice and the approved words. Keep each instruction
> shorter than 20 words and each descriptive sentence shorter than 25 words.
> Write one instruction in each sentence. Do not change technical names,
> commands, or code examples.

OpenHAP is a HomeKit Accessory Protocol (HAP) server for **OpenBSD**, written in
Perl (v5.36, base-system Perl, minimal dependencies). It bridges MQTT-connected
Tasmota devices to Apple HomeKit: SRP-6a pairing, Ed25519, X25519,
ChaCha20-Poly1305, HKDF-SHA-512, and TLV8 over encrypted HTTP/1.1, advertised
via mDNS. OpenBSD is the production platform (pledge(2)/unveil(2), rc.d,
`_openhap` user); Linux and Darwin are supported for development and CI only.

The repo holds two Perl namespaces. It claims no top-level name; `App::` and
`Protocol::` are shared namespaces that the project joins.

- `Protocol::HAP` (`lib/Protocol/HAP/`) — the host-neutral HAP library: codecs,
  crypto, pairing, the data model, the server engine, a controller, and two
  stores; self-contained, headed for CPAN
- `App::OpenHAP::` (`lib/App/OpenHAP/`) — the reference host: the daemon
  plumbing, MQTT device integration, and OpenBSD policy

The dependency direction is one way. `Protocol::` uses core Perl and its
declared CPAN modules, and never `Fugu::` or `App::`. `App::OpenHAP` uses
`Protocol::HAP`, the installed `Fugu::` library, and core Perl.

## Sibling distributions

Three sibling repositories carry what this one consumes. Each publishes a
release tarball, and the `dist` lines of the `deps/` manifests install the
latest one with cpanm:

- [FuguBSD/Fugu](https://github.com/FuguBSD/Fugu) — the OpenBSD-style daemon
  utilities (`Fugu::`) and the `Protocol::Imsg` codec; a runtime dependency
- [FuguBSD/FuguVM](https://github.com/FuguBSD/FuguVM) — `fuguvm`, the OpenBSD VM
  manager that `make integration` drives; a develop dependency
- [FuguBSD/FuguWeb](https://github.com/FuguBSD/FuguWeb) — `fuguweb`, the
  documentation site builder that `make web` drives; a develop dependency

`.github/actions/setup-perl` also lives in FuguBSD/Fugu; every workflow that
installs dependencies references it as
`FuguBSD/Fugu/.github/actions/setup-perl@main`.

## Commands

```sh
make check          # lint + test + tidy + spec-coverage; MUST pass before every commit
make test           # prove -l -v t/{protocol,openhap,conformance,scripts,web,ci}/*.t
prove -l t/openhap/foo.t   # run a single test file
make lint           # Perl::Critic, severity 4
make spec-coverage  # spec/ section coverage + stale-citation check

make tidy           # check perltidy formatting
make tidy-fix       # auto-fix Perl formatting
make prettier       # check Markdown/JSON/YAML formatting
make prettier-fix   # auto-fix Markdown/JSON/YAML
make deps           # install runtime dependencies (Fugu, mosquitto, crypto)
make deps-test      # runtime + test dependencies
make deps-develop   # all dependencies (adds fuguvm, fuguweb, QEMU, etc.)
make integration    # provision OpenBSD VM and run integration tests
make web            # build the website with the installed fuguweb
```

## Layout

- `bin/` — `openhapd` (daemon), `hapctl` (control CLI)
- `lib/Protocol/HAP/` — codecs (`TLV.pm`, `HTTP.pm`), setup-code rules
  (`SetupCode.pm`), crypto (`Crypto.pm`, `SRP.pm`), pairing and sessions
  (`Pairing.pm`, `Session.pm`, `Store.pod`, `Store/Memory.pm`, `Store/File.pm`),
  the data model (`Accessory.pm`, `Service.pm`, `Characteristic.pm`,
  `Bridge.pm`), the sans-IO engine (`Server.pm`), and the blocking client
  (`Controller.pm`). Do not call the tier sans-IO: `Server.pm` is, and
  `Controller.pm` and `Store/File.pm` are not (`t/protocol/boundary.t` enforces
  the dependency rule instead)
- `lib/App/OpenHAP/` — the host (`Host.pm`), device integration (`Devices.pm`,
  `Tasmota/*.pm`), the integration-test driver (`Test/Integration.pm`)
- `t/openhap/`, `t/protocol/` — unit tests; `t/conformance/` — spec-cited
  conformance tests; `t/scripts/`, `t/web/`, `t/ci/` — tooling tests, named
  after what they drive (see `t/CLAUDE.md`); `t/openhap/integration/` —
  integration tests, run inside the OpenBSD VM
- `man/openhap/` — mdoc(7) man pages: `openhapd.8`, `hapctl.8`,
  `openhapd.conf.5`
- `spec/` — curated protocol references, normative for the conformance tier (see
  `spec/CLAUDE.md`)
- `plans/` — design documents and phased implementation plans (see the Plans
  section below)
- `deps/` — per-OS dependency manifests; `scripts/` — the dependency, coverage
  and VM helpers

## Coding style

OpenBSD style(9): 8-character tabs, continuation lines indent 4 spaces.
Formatting is enforced by `make tidy` and `make lint` — run `make tidy-fix`
rather than hand-formatting. `.perlcriticrc` deliberately relaxes many rules to
match OpenBSD style; do not "fix" code toward generic Perl::Critic defaults.

Rules the tools cannot enforce:

- Always `use v5.36` (enables strict, warnings, say, signatures) — the only
  exception is the bootstrap scripts, see Dependencies
- Object-oriented style with signatures; object is `$self`; internal methods
  prefixed with `_`; do not name unused parameters: `sub foo($, $) { }`
- Function brace on its own line, control-structure brace on the same line:

```perl
sub method($self, $param)
{
	if ($condition) {
		...
	}
	return $result;
}
```

- Explicit `return` except for no-return or constant methods; omit parens on
  zero-argument method calls: `$object->width`
- Inheritance via `our @ISA` (not `use parent`); no multiple inheritance;
  multiple related packages per file are fine; constants via `use constant`
- New files start with the `# ex:ts=8 sw=4:` modeline and ISC copyright header —
  copy from an existing file in `lib/`
- `Class->new`, never indirect object notation; code refs always with
  parentheses (except delegation); no old-style prototypes unless creating
  syntax
- Simple string operations over regex where they suffice; `wantarray()` only as
  an optimization, never to change semantics

## Error handling and security

- Return `undef` (bare `return`) for recoverable errors, `die` for programming
  errors; never use `eval` for flow control
- Never ignore return values of system calls:
  `open my $fh, '<', $file or do { warn "..."; return; };`
- No threads — multiplex with `IO::Select`
- Signal handling via `Fugu::Signal` object handlers; daemonization and
  privilege drop via `Fugu::Daemon` and `Fugu::Privdrop`
- Security by default: randomness from `/dev/urandom`, design for
  pledge(2)/unveil(2), drop privileges early, fail closed, never trust external
  input
- Fail cleanly: diagnose invalid input in a human-readable message, never a
  stack trace; leave no partial files, orphaned processes, or corrupt state
  behind; make repeatable operations truly idempotent

## Simplicity

- The project has no users. Delete old code paths outright; never keep an alias,
  a bridge, or a migration.
- Do not keep test-only API. Delete a sub or option that only tests use,
  together with its test.
- Validate each input once, at its boundary. Do not check the same invariant
  again downstream.

## Testing

- Unit tests use `Test::More` with `done_testing()`; they skip gracefully when a
  dependency is unavailable (`plan skip_all => ...`); mirror an existing test in
  `t/openhap/` when adding one
- Be resilient to timing variations
- Every feature needs tests
- Integration tests follow different rules (they never skip) — see
  `t/openhap/integration/CLAUDE.md`

## Documentation

Every fact lives in exactly one place; everything else points to it. Decide
placement top-down — first match wins:

| #   | The content is...                               | It belongs in...                                                                                              |
| --- | ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| 1   | for human end-users or operators                | `README.md` (intro, quick start), `INSTALL.md` (install, setup), `man/` (authoritative tool/config reference) |
| 2   | the API of a Perl module                        | sidecar `.pod` next to the `.pm` — never inline POD                                                           |
| 3   | needed on essentially every coding task         | this file — always loaded, so keep it short                                                                   |
| 4   | needed only when touching one directory's files | that directory's `CLAUDE.md`                                                                                  |
| 5   | a procedure — "how to do X" on demand           | a skill in `.claude/skills/<name>/SKILL.md`                                                                   |
| 6   | none of the above                               | nowhere — delete it                                                                                           |

`web/` is not another place for any of this: the site renders `INSTALL.md`,
`man/` and the `.pod` sidecars, never restating them. Only site-specific framing
is hand-written, in `web/*.body.html`, and the front page is one of those — see
`web/CLAUDE.md`.

Corollaries:

- No `README.md` anywhere except the repository root
- Skills and `CLAUDE.md` files may point to man pages, `.pod` files, `spec/`, or
  each other, but never restate their content
- A new `lib/` module needs a `.pod` sidecar and a test
- Update the relevant documentation with any change in behavior, options, or
  configuration

## Plans

Larger efforts are planned before they are implemented, under
`plans/<NNN>-<slug>/` (numbered in order of creation):

- `design.md` — the **design**: a brief, high-level architectural plan defining
  the target state — contracts, interfaces, call graphs or mermaid diagrams. It
  says _what_ is being built and why, not how to sequence the work. Aim for 200
  lines; running over is a prompt to cut, or to split the effort in two, not a
  hard failure. Sequencing and file-by-file detail belong in `plan-N.md`.
- `plan-N.md` — the **plans**: the implementation broken into N phases, one file
  per phase. Each phase is independently shippable and lists its tasks,
  deliverables, and acceptance criteria; phase N may depend only on phases
  before it.

Plans describe intent at the time of writing; the code, tests, and regular
documentation remain the source of truth once a phase has landed.

Review every `design.md` and `plan-N.md` with a workflow of cold sub-agents,
never from the context that wrote it: fan several reviewers out on different
angles — contracts, phase independence, security boundaries, testability,
OpenBSD fit, what is left unsaid — each prompted to refute rather than confirm.
Report only findings that two other sub-agents independently confirm; drop the
rest.

## Dependencies

`deps/{OpenBSD,Linux,Darwin}.txt` are authoritative, installed by `make deps`
via `scripts/deps`; one line each, `<environment> <type> <name>`, where
`<environment>` is `runtime`, `test`, or `develop` and `<type>` is `pkg`,
`dist`, or `cpan`. A `dist` line names a release-asset URL of a sibling
distribution, and `scripts/deps` installs the tarball with cpanm — this is how
Fugu, FuguVM and FuguWeb arrive.

`scripts/deps` and `scripts/deps-key` are the one exception to `use v5.36`: they
run before anything is installed, and macOS still ships perl 5.34, so requiring
5.36 would mean installing a perl with the script that installs things. They use
`use v5.34` plus explicit `use warnings` and core modules only. Do not "fix"
them up to 5.36.

- Justify the need first: prefer base-system Perl, and `require` optional
  dependencies so they stay optional
- Prefer `pkg` over `cpan` — OS packages are vetted, binary, and upgraded with
  the system (on OpenBSD the native `p5-*` packages)
- Add the line to every platform manifest that applies, keep the `cpanfile` in
  sync, then verify with `make deps` and commit with the `build` type

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/):
`<type>(<scope>): <description>` with types `feat`, `fix`, `docs`, `style`,
`refactor`, `perf`, `test`, `build`, `ci`, `chore` and module scopes such as
`protocol`, `hap`, `mqtt`, `crypto`, `bridge`, `config`, `daemon`, `tasmota`.
Breaking changes take `!` or a `BREAKING CHANGE:` footer.

```
feat(mqtt): add support for retained messages
fix(crypto): correct ChaCha20-Poly1305 nonce handling
```

Always run `make check` before committing; fix formatting failures with
`make tidy-fix`. Group unrelated changes into separate commits rather than one
sweeping commit.

## Gotchas

- Releases use semantic versioning: a `v<MAJOR>.<MINOR>.<PATCH>` tag; there is
  no VERSION file and no `$VERSION` in a source module. `scripts/dist` (a
  one-time copy of the FuguBSD/Tooling engine, configured by `.toolingrc`)
  builds the App-OpenHAP CPAN distribution: it stamps `our $VERSION` into every
  staged package and writes the META.json that PAUSE indexes. The Release
  workflow publishes the OS archive and the dist to GitHub, and the dist to
  PAUSE.
- Use `explore/` (gitignored) for scratch scripts and experiments, never `/tmp`
- Audit findings go to `SCRATCHPAD-<N>.md` files (gitignored)
