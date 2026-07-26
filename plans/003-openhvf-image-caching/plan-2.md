# Phase 2 — Operability: cache subcommand, config knob, docs

Phase 1 makes the cache work; this phase makes it observable, controllable, and
documented. Independently shippable on top of phase 1.

## Tasks

### 2.1 `openhvf cache` subcommand

Add to `OpenHVF::CLI` alongside the existing `image` subcommand:

- `cache list` — one line per `installed/<key>/` entry: key, on-disk size,
  creation time (from `meta.json`), snapshot count (0 until phase 3), and a
  marker on the entry matching the current configuration's derived key. Nothing
  cached prints "No cached images", mirroring `image list`.
- `cache clear [--stale]` — removes cached entries. Bare `clear` removes all of
  `installed/`; `--stale` keeps only the entry whose key matches the current
  configuration. Refuse to remove the entry backing a currently existing working
  disk while the VM is running (check via state), and warn when removal orphans
  an existing stopped disk's backing chain — the phase 1 chain check makes the
  consequence loud, this makes it predictable.

### 2.2 Cache on/off control

- New config directive `image_cache yes|no` (project or global `.openhvfrc`),
  default `yes`, parsed and exposed by `OpenHVF::Config` like `cache_dir`.
- New `up` option `--no-cache`: skip both restore (force a fresh install) and
  save for this invocation. Useful when debugging the installer itself and for
  `robustness-openhvf` runs.
- Precedence: CLI flag over project config over global config.

### 2.3 Documentation

- `man/openhvf/openhvf.1`: document the `cache` subcommand, the `--no-cache`
  option, the `image_cache` directive, the cache layout under `cache_dir`, and a
  SECURITY note that `meta.json` stores the generated root password (mode 0600;
  same exposure as the state directory today; test VMs are localhost-only).
- Update `lib/OpenHVF/ImageCache.pod` for any interface additions.
- Update the `openhvf` skill (`.claude/skills/openhvf/SKILL.md`) only if its
  procedures change; it must point at the man page, not restate it.

## Deliverables

- Changes to `lib/OpenHVF/CLI.pm`, `lib/OpenHVF/Config.pm`, `lib/OpenHVF/VM.pm`,
  `lib/OpenHVF/ImageCache.pm` (+ `.pod`)
- Extended `t/openhvf/cli.t`, `t/openhvf/config.t`, `t/openhvf/imagecache.t`
- `man/openhvf/openhvf.1` updates

## Acceptance criteria

- `cache list` reflects reality before and after installs and `clear`
  operations; `cache clear --stale` provably keeps the current key and removes
  others (unit-tested with synthetic entries).
- `image_cache no` and `--no-cache` each force a full install and leave the
  cache untouched; default behavior is unchanged from phase 1.
- Usage errors (`cache frobnicate`) return `EXIT_INVALID_ARGS` with a usage
  line, matching the existing subcommand style.
- `make check` stays green; man page lints with `mandoc -Tlint` if that check
  exists in the tree, otherwise renders cleanly with `man -l`.
