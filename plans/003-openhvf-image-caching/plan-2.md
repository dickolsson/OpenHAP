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
  `installed/`; `--stale` keeps only the entry whose key matches the VM named by
  `--vm`, matching every other verb's scoping. Say so explicitly: the key inputs
  `version` and `disk_size` are per-VM (`Config.pm:163-164`) and a configuration
  may declare many `vm` blocks plus `.openhvf/vms/*.conf`, so `--stale` run for
  one VM prunes bases another VM would have hit. Widening the keep-set instead
  would need a Config enumerator that does not exist today.
- Before removing an entry, resolve which base an existing working disk uses via
  `Disk::info` (`Disk.pm:85-95`, whose backing-filename phase 1 already reads).
  Refuse while that VM is running (`State::is_vm_running`), and warn when
  removal orphans an existing stopped disk's backing chain — the phase 1 chain
  check makes the consequence loud, this makes it predictable. The refusal can
  only cover VMs in the invoking checkout; a `cache_dir` shared between
  checkouts cannot be surveyed, which is why the orphan case stays a warning.
- Both forms also sweep leftover `installed/.tmp.*` trees from interrupted
  `store` calls.

### 2.2 Cache on/off control

- New config directive `image_cache yes|no` (project or global `.openhvfrc`),
  default `yes`, parsed and exposed by `OpenHVF::Config` like `cache_dir`.
- New `up` option `--no-cache`: skip both restore (force a fresh install) and
  save for this invocation. Useful when debugging the installer itself and for
  `robustness-openhvf` runs.
- Precedence: CLI flag over project config over global config.

### 2.3 Documentation

- `man/openhvf/openhvf.1`: document the `cache` subcommand, the `--no-cache`
  option, the `image_cache` directive, the cache layout under `cache_dir`, the
  per-VM scoping of `--stale`, and a SECURITY note that `meta.json` stores the
  generated root password (mode 0600; the same secret the state directory
  already holds, but now surviving `destroy` and rotating only with the base
  key).
- That note must not call these VMs localhost-only. The guest permits password
  root login (`install.exp`, `firstboot.exp`), and `VM.pm:787` and `:791` pass
  `hostfwd=tcp::<ssh_port>-:22` and `-serial tcp::<console_port>` with no host
  address, so the forwarded SSH port and the telnet serial console bind every
  interface. State the exposure as it is. Rebinding those to 127.0.0.1 is a
  `VM.pm` networking change unrelated to caching — every in-tree consumer
  already dials 127.0.0.1 — and belongs outside plan 003.
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
  operations; `cache clear --stale` provably keeps the invoked VM's key and
  removes others, and sweeps a synthetic `installed/.tmp.*` tree (unit-tested
  with synthetic entries).
- `cache clear` refuses while the VM whose disk is backed by that entry is
  running, and warns rather than refusing when the disk is stopped.
- `image_cache no` and `--no-cache` each force a full install and leave the
  cache untouched; default behavior is unchanged from phase 1.
- Usage errors (`cache frobnicate`) return `EXIT_INVALID_ARGS` with a usage
  line, matching the existing subcommand style.
- `make check` stays green; man page lints with `mandoc -Tlint` if that check
  exists in the tree, otherwise renders cleanly with `man -l`.
