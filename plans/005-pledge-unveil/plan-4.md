# Phase 4 — unveil(2)

Restrict the filesystem view. Depends on phase 3 for `FuguLib::Sandbox`, which
already carries the `unveil` and `unveil_lock` API; this phase only builds the
path inventory and calls them. At the end of this phase the claims in
`README.md` and `web/index.body.html` are true.

## Tasks

### 4.1 The path inventory

Assembled in `bin/openhapd` from configuration, not hardcoded — `$config_file`,
`$db_path` and the log path are all variable.

| path                    | perms | needed for                            |
| ----------------------- | ----- | ------------------------------------- |
| `$config_file`          | `r`   | re-read after a future SIGHUP reload  |
| `$db_path`              | `rwc` | pairings, device state (`Storage.pm`) |
| `/var/log/openhapd.log` | `w`   | daemon-mode log (`Daemon::daemonize`) |
| `/var/run/mdnsd.sock`   | `rw`  | `connect(2)` needs `w` on the path    |
| `/dev/urandom`          | `r`   | `Crypto.pm:35`                        |
| `/etc/resolv.conf`      | `r`   | resolver, on MQTT reconnect           |
| `/etc/hosts`            | `r`   | resolver, on MQTT reconnect           |
| each `@INC` directory   | `r`   | lazy `require` of pure-Perl modules   |

Notes that matter:

- **`@INC` read-only is a deliberate choice**, and the design says why: Perl's
  lazy loading makes "prove nothing loads late" a claim no test can hold over
  time, while unveiling the library tree read-only is one line and cannot
  regress. The comment in the code must say this, or someone will "tighten" it
  and break pairing three months later.
- Skip `@INC` entries that are not directories (`.`, code refs from any future
  loader hooks) rather than failing on them.
- `/var/log/openhapd.log` is already an open fd by unveil time, so this entry
  exists for log rotation and reopen, not for the current write path. Keep it —
  the cost is one line and the alternative is a surprise later.
- `/etc/resolv.conf` and `/etc/hosts` are only needed when `mqtt_host` is a
  name. Unveil them unconditionally: conditionally-restricted is harder to
  reason about than uniformly-restricted, and neither file is sensitive to this
  daemon.
- No `x` anywhere. Phase 2 removed the only `exec`, and an unveil that grants
  `x` while pledge withholds `exec` is a confusing contradiction in the source.

### 4.2 Call site and ordering

In `bin/openhapd`, between the mDNS advertisement and the pledge from phase 3:

1. Preload (phase 3, task 3.2) — before unveil, because it reads from `@INC` and
   `dlopen`s.
2. `FuguLib::Sandbox->unveil(paths => \@paths)`.
3. `FuguLib::Sandbox->unveil_lock`.
4. `FuguLib::Sandbox->pledge(promises => ...)`.

All four after privdrop. Unveil only removes reachability — it grants nothing —
so applying it as `_openhap` is correct, and it keeps the root-only `chown` loop
at `bin/openhapd:118-137` untouched. `Storage` has already run `make_path` on
`$db_path` (`Storage.pm:14`) via `HAP->new`, so the directory exists by the time
we unveil it; a `$db_path` that still does not exist is a hard failure, and
correctly so.

Add a short comment block naming the four steps and their order, because the
ordering is load-bearing and not locally obvious.

### 4.3 Tests

`t/openhap/openhapd.t`-style coverage cannot exercise unveil without running the
daemon, so split the work:

- `t/fugulib/sandbox.t` (extended from phase 3): on OpenBSD, a forked child
  unveils a temp directory `r`, locks, then fails to read a file outside it and
  succeeds inside it. Also assert that unveiling a nonexistent path dies.
- A unit test for the inventory builder: factor path assembly into a small
  testable sub (or `FuguLib::Sandbox` helper) that takes the config values and
  returns the pair list, so the `@INC` filtering and the config-derived paths
  can be asserted on any platform without unveiling anything.
- Integration (phase 5 expands this): the daemon runs, pairs, and serves with
  unveil active.

### 4.4 Documentation

- `man/openhap/openhapd.8`: list the unveiled paths in the FILES section, and
  note that `openhapd` cannot read anything else — an operator debugging "why
  can't it read my file" needs this to be findable.
- `man/fugulib/Sandbox.3p`: document `unveil`'s die-on-missing-path behaviour
  and the lock semantics.
- `README.md`, `CLAUDE.md`, `web/`: unchanged. As of this phase they are
  accurate.

## Deliverables

- Changes to `bin/openhapd` (inventory, unveil, lock, ordering comment)
- Possibly a small helper in `lib/FuguLib/Sandbox.pm` for `@INC` filtering
- Extended `t/fugulib/sandbox.t`, new inventory unit test
- `man/openhap/openhapd.8` FILES section, `man/fugulib/Sandbox.3p` updates

## Acceptance criteria

- On OpenBSD, `openhapd` completes a full pairing, serves characteristic reads
  and writes, publishes and updates mDNS, and reconnects to a restarted MQTT
  broker, all with unveil locked. The MQTT restart is the sharpest test: it is
  the path that touches the resolver files and lazily `require`s
  `Net::MQTT::Simple`.
- A file outside the unveiled set is unreadable by the running daemon, verified
  from inside the VM rather than asserted in prose.
- Unveiling a nonexistent path is fatal at startup with the path in the message.
- `make check` green on Linux and Darwin, behaviour unchanged.
- `mandoc -Tlint -W warning` clean.
