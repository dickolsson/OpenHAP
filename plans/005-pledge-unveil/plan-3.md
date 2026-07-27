# Phase 3 — `FuguLib::Sandbox` and pledge(2)

Build the platform abstraction and apply the pledge. Depends on phase 2: while
`openhapd` spawns `mdnsctl`, the promise set would need `proc exec` and the
exercise would be close to pointless.

## Tasks

### 3.1 `FuguLib::Sandbox`

One module, both mechanisms, three platforms. The whole point is that callers
never write `if ($^O eq 'openbsd')`.

```perl
FuguLib::Sandbox->is_supported;                 # 1 on OpenBSD, '' elsewhere
FuguLib::Sandbox->pledge(promises => $string);  # 1, or die
FuguLib::Sandbox->unveil(paths => \@pairs);     # 1, or die
FuguLib::Sandbox->unveil_lock;                  # 1, or die
```

- On OpenBSD, `OpenBSD::Pledge` and `OpenBSD::Unveil` are loaded at compile
  time. They are base-system modules; failing to load them there means a broken
  Perl, so that is fatal at `use` time rather than a runtime fallback to "no
  protection".
- Off OpenBSD every method is a no-op returning 1, and logs **once** at debug
  (`'sandbox: %s is a no-op on %s'`). Once, not per call, so a daemon that
  re-pledges does not flood the log; and at debug rather than silence so a test
  reading logs can tell enforcement from emulation.
- `pledge` and `unveil` failures `die` with the promise string or path and `$!`.
  Fail closed: there is no `force => 0` and no warn-and-continue mode. A daemon
  that cannot restrict itself must not start.
- `unveil(paths => [[$path, $perms], ...])` applies pairs in order and reports
  which pair failed. `$path` that does not exist is a failure, not a skip — a
  typo'd path silently accepted is the failure mode that makes unveil useless.
- `unveil_lock` calls `OpenBSD::Unveil::unveil()` with no arguments.
- Keep it stateless: class methods, no object. It wraps two syscalls that are
  themselves process-global.

Ships with `man/fugulib/Sandbox.3p`, a `MAN3P` entry, and `t/fugulib/sandbox.t`.

The test must be meaningful on both kinds of platform, which needs care:

- Everywhere: `is_supported` agrees with `$^O`; a no-op platform returns 1 from
  every method and does not die.
- On OpenBSD only: fork a child, `pledge('stdio')` in it, have it attempt
  `socket(AF_INET)`, and assert it dies of `SIGABRT` — pledge violations abort,
  they do not return `EPERM`. Assert in the **child**, never the parent, or the
  test process pledges itself and takes the rest of the suite down.
- On OpenBSD only: a child that unveils `$tmpdir` read-only, locks, and then
  fails to open a file outside it.
- A bogus promise string dies rather than being accepted.

Guard the OpenBSD-only cases with `plan skip_all` at the file level only if the
whole file is OpenBSD-specific; here it is not, so guard per-subtest and make
the skip message name the reason.

### 3.2 Preload everything that would `dlopen` later

`prot_exec` stays out of the promise set, so no shared object may be opened
after the pledge. Two known offenders load lazily (see the design), and both are
handled in `bin/openhapd` before pledging:

- Explicitly `use`/`require` the XS runtime dependencies: `Crypt::Ed25519`,
  `Crypt::Curve25519`, `Crypt::AuthEnc::ChaCha20Poly1305`,
  `Crypt::KeyDerivation`, `Digest::SHA`, `JSON::XS`, `Net::MQTT::Simple`,
  `Sys::Syslog`.
- Force `Math::BigInt` to load its GMP backend by performing one modular
  exponentiation. `Math::BigInt::GMP` is pulled in on first use, and first use
  is otherwise during SRP at pairing time — long after the pledge.
- Call `localtime` once so the zone file is cached.

Put this in one clearly commented block — a `_preload` sub in `bin/openhapd` —
with a comment saying _why_, because the next person to read it will otherwise
delete it as redundant `use` statements. Note in the comment that adding an XS
dependency means adding it here.

### 3.3 Apply the pledge in `bin/openhapd`

After the mDNS advertisement is established and before the signal handlers and
`$hap->run()`:

```
stdio rpath wpath cpath fattr flock inet dns unix
```

Derivation is in the design; the code carries a comment per promise so a future
reader can shrink the set safely. Also:

- Both `-f`/foreground and daemon mode pledge identically. Foreground differs
  only in where the log goes, which is already an open fd by then.
- `-n`/`--check` exits at `bin/openhapd:34-37`, before any of this. Leave it
  alone; a config check is not a long-running process.
- Log at info that the pledge was applied, naming the promise set. On a no-op
  platform, log nothing at info — the debug line from 3.1 is enough — so the
  absence of that info line is itself a signal.

### 3.4 Documentation

- `man/fugulib/Sandbox.3p` is the API reference for the module (FuguLib is
  documented in man3p, not in sidecars).
- `man/openhap/openhapd.8`: state the promise set and that OpenBSD is the only
  platform where it is enforced. The full SECURITY section lands in phase 5,
  once unveil is in place; here, one accurate paragraph.
- Do not touch `README.md`, `CLAUDE.md`, or `web/` — their claims become fully
  true at the end of phase 4, and hedging them for one phase then unhedging them
  is churn.

## Deliverables

- `lib/FuguLib/Sandbox.pm`, `man/fugulib/Sandbox.3p`, `Makefile` `MAN3P` entry
- `t/fugulib/sandbox.t`
- Changes to `bin/openhapd` (preload block, pledge call)
- `man/openhap/openhapd.8` paragraph

## Acceptance criteria

- On OpenBSD, `openhapd` starts, pairs, serves characteristics, publishes mDNS,
  and survives an MQTT broker restart — all under the pledge. The MQTT case
  matters most: reconnection is the one code path that resolves names and loads
  `Net::MQTT::Simple` after the pledge point, and it is the likeliest thing to
  abort in production rather than in a test.
- A full SRP pairing completes under the pledge, proving the `Math::BigInt::GMP`
  preload works. Without it this aborts, and only at pairing time.
- `t/fugulib/sandbox.t` proves a pledge violation aborts a child process on
  OpenBSD, and proves the no-op contract elsewhere.
- `make check` green on Linux and Darwin with behaviour byte-identical to
  before.
- `kdump`/`ktrace` of a running `openhapd` shows no `pledge` violation and no
  `mmap` with `PROT_EXEC` after startup.
- `mandoc -Tlint -W warning` clean.
