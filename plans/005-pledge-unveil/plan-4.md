# Phase 4 — unveil(2)

Restrict the filesystem view. Depends on phase 3 for `FuguLib::Sandbox`, which
already carries the `unveil` and `unveil_lock` API and the required/optional
distinction; this phase builds the path inventory and calls them. It also
depends on phase 1's measurement 6 — the `kdump` of the real path set — because
an inventory derived by reading code is a guess.

At the end of this phase the claims in `README.md` and `web/index.body.html` are
true.

## Tasks

### 4.1 The path inventory

Assembled in `bin/openhapd` from configuration where it is configurable. Every
row carries a **disposition**: _required_ means absent is a broken install and
startup fails with the path in the message; _optional_ means legitimately absent
on a working system, so it is skipped with a debug line.

The disposition column is the whole point of this task. Without it, three paths
that are routinely absent would turn configurations that start today into
startup failures — which design goal 7 forbids.

| path                      | perms | disp.    | needed for                                      |
| ------------------------- | ----- | -------- | ----------------------------------------------- |
| `$db_path`                | `rwc` | required | pairings, device state (`Storage.pm`)           |
| `/dev/urandom`            | `r`   | required | `Crypto.pm:35`                                  |
| library directories (4.2) | `r`   | required | lazy `require` of pure-Perl modules             |
| `$config_file`            | `r`   | optional | re-read on a future reload; **absent is legal** |
| `/var/log/openhapd.log`   | `w`   | optional | daemon-mode log; **absent under `-f`**          |
| `/var/run/mdnsd.sock`     | `rw`  | optional | reconnect, if `update_txt` republishes          |
| `/etc/resolv.conf`        | `r`   | optional | resolver, on MQTT reconnect                     |
| `/etc/hosts`              | `r`   | optional | resolver, on MQTT reconnect                     |
| `/etc/services`           | `r`   | optional | resolver; the third file `dns` grants           |
| `/etc/protocols`          | `r`   | optional | `getprotobyname` on the reconnect path          |
| `/etc/localtime`          | `r`   | optional | `localtime` in log timestamps                   |

**Add whatever measurement 6 found that this table does not list.** The table is
a starting point, not the authority — that is the same discipline phase 1
applies to the mdnsd ABI.

Why each optional row is optional, since getting this wrong is the failure mode:

- **`$config_file`** — `bin/openhapd:32` is
  `$config->load() if -f $config_file`. Running on defaults is supported, and
  `Makefile:130` installs the sample to `$(SYSCONFDIR)/examples/openhapd.conf`,
  never to `/etc/openhapd.conf`; `INSTALL.md:35` tells the operator to copy it.
  A fresh `make install` + `rcctl start` has no config file at all. Note also
  that the justification is weaker than the earlier draft claimed: SIGHUP is
  currently wired to graceful _exit_ (`bin/openhapd:177`), so the "future
  reload" this row serves does not exist yet. Keep the row — it costs one line
  and reload is a real intention — but do not let it be fatal for a feature that
  is not there.
- **`/var/log/openhapd.log`** — created only by `daemonize`
  (`FuguLib/Daemon.pm:55`), which `bin/openhapd:41` skips entirely under `-f`.
  On any host that has only ever run `openhapd -f` — the documented development
  path — the file does not exist. It is also already an open fd by unveil time
  in daemon mode, so the row exists for rotation and reopen, not the current
  write path. (The path is a hardcoded literal at `bin/openhapd:42`, not
  configuration, despite what the earlier draft's preamble said; the inventory
  builder takes it as a constant.)
- **`/var/run/mdnsd.sock`** — exists only while `mdnsd(8)` runs. Making it fatal
  would contradict `design.md`'s contract that a `FuguLib::MDNS` failure stays
  non-fatal and phase 2's criterion that a missing socket leaves the HAP server
  serving. It is also only needed at all if measurement 4 put a reconnect in
  `update_txt`; if it did not, drop the row entirely along with the `unix`
  promise.
- **The resolver files** — only needed when `mqtt_host` is a name. Unveil them
  unconditionally-as-optional rather than conditionally on the config: uniformly
  restricted is easier to reason about than conditionally restricted, and none
  is sensitive to this daemon. `/etc/services` is the third file pledge's `dns`
  promise grants alongside `hosts` and `resolv.conf`; the earlier draft dropped
  it without a reason. `/etc/protocols` is on the reconnect path because
  `IO::Socket::IP` calls `getprotobyname` on every `new()` with a non-numeric
  `Proto`, uncached — the HAP listener at `HAP.pm:158` escapes this only because
  `IO::Socket::INET` pre-populates its proto table from `Socket::IPPROTO_TCP`.

No `x` anywhere. Phase 2 removed the only `exec`, and an unveil that grants `x`
while pledge withholds `exec` is a confusing contradiction in the source.

### 4.2 Enumerate the library directories; do not derive them from `@INC`

The earlier draft said "each `@INC` directory, skipping non-directories". That
is wrong twice over:

- `bin/openhapd:4-5` prepends `"$RealBin/../lib"`. `Makefile:101` installs the
  daemon to `$(BINDIR)` with `PREFIX ?= /usr/local`, so on a real deployment
  that entry is **`/usr/local/lib`** — a directory that exists, so a
  non-directory skip does not catch it, containing every third-party library
  under `/usr/local` rather than a Perl tree. The Perl modules actually live in
  `/usr/local/libdata/perl5/site_perl` (`Makefile:6`). Unveiling all of
  `/usr/local/lib` read-only is a substantial and unintended widening, and it is
  unreviewable when the inventory just says "each `@INC` directory".
- `MQTT.pm:42-45` `unshift`s `/usr/local/libdata/perl5/site_perl` onto `@INC`
  _inside_ `mqtt_connect`. Today that runs at `bin/openhapd:88`, before this
  inventory is built, so the directory happens to be present. Defer the startup
  connect — a natural follow-up when the broker may be down — and a derived set
  silently loses it, `unveil_lock` seals it out, and the reconnect-path
  `require` fails permanently. That is a hidden ordering dependency the plan
  must not rely on.

So: build an **explicit list** — the perl core library directories, the
site_perl directory, and the daemon's own `lib` when running from a source
checkout — and unveil those. Note in the comment why it is a list and not
`@INC`, or someone will "simplify" it back.

Keep the `@INC`-read-only trade-off itself, and say why in the code: Perl's lazy
loading makes "prove nothing loads late" a claim no test can hold over time,
while unveiling the library tree read-only is a few lines and cannot regress.
The comment must say this, or someone will "tighten" it and break the MQTT
reconnect three months later.

### 4.3 Call site and ordering

In `bin/openhapd`, between the mDNS advertisement and the pledge from phase 3:

1. Resolve the lazy load (phase 3, task 3.2) — before unveil, because it reads
   from the library tree.
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

### 4.4 Tests

`t/openhap/openhapd.t`-style coverage cannot exercise unveil without running the
daemon, so split the work:

- **The inventory builder is a unit test.** Factor path assembly into a small
  testable sub that takes the config values and returns the ordered pair list
  with dispositions, so the library-directory enumeration, the disposition
  assignment and the config-derived paths can be asserted on any platform
  without unveiling anything. Assert specifically that a missing `$config_file`
  yields an optional entry (or none) and never a required one — that is the
  regression that would reintroduce the startup failure.
- `t/fugulib/sandbox.t` (extended from phase 3): on OpenBSD, a forked child
  unveils a temp directory `r`, locks, then fails to read a file outside it and
  succeeds inside it — asserting in the parent, per phase 3. Also assert that a
  missing **required** path dies and a missing **optional** path does not.
- Integration (phase 5 expands this): the daemon runs, pairs, and serves with
  unveil active — and starts successfully with no config file, with `mdnsd`
  stopped, and in `-f` mode on a host with no log file.

### 4.5 Documentation

- `man/openhap/openhapd.8`: list the unveiled paths in the FILES section,
  marking which are required and which are optional, and note that `openhapd`
  cannot read anything else — an operator debugging "why can't it read my file"
  needs this to be findable.
- `man/fugulib/Sandbox.3p`: document the required/optional semantics and the
  lock behaviour (phase 3 introduces them; this phase is their first real user).
- `README.md`, `CLAUDE.md`, `web/`: unchanged here. As of this phase the
  pledge/unveil claims are accurate; phase 5 audits them and fixes the FuguLib
  module count.

## Deliverables

- Changes to `bin/openhapd` (inventory builder, unveil, lock, ordering comment)
- The inventory builder factored into a testable sub, with its unit test
- Extended `t/fugulib/sandbox.t`
- `man/openhap/openhapd.8` FILES section, `man/fugulib/Sandbox.3p` updates

## Acceptance criteria

- On OpenBSD, `openhapd` completes a full pairing, serves characteristic reads
  and writes, publishes and updates mDNS, and reconnects to a restarted MQTT
  broker, all with unveil locked. The MQTT restart is the sharpest test: it is
  the path that touches the resolver files and lazily `require`s
  `Net::MQTT::Simple`.
- **Every configuration that started before this phase still starts**: no config
  file, `mdnsd` stopped, and `openhapd -f` on a host with no
  `/var/log/openhapd.log`. Verified in the VM, not asserted in prose.
- A file outside the unveiled set is unreadable by the running daemon, verified
  from inside the VM.
- A missing _required_ path is fatal at startup with the path in the message; a
  missing _optional_ path is not.
- The unveiled library directories are the enumerated list, not raw `@INC`:
  `/usr/local/lib` is not in the view on an installed layout.
- `make check` green on Linux and Darwin, behaviour unchanged.
- `mandoc -Tlint -W warning` clean.
