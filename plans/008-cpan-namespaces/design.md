# CPAN namespace realignment — Design

## Problem

The repository claims three top-level namespaces: `OpenHAP`, `FuguLib`, and
`FuguVM`. The PAUSE guidance on module naming permits a top-level name only for
a nexus of modules, or for a fanciful name that names an application. Three
claims for one project fail that test. Two other faults come with them.

`Lib` carries no information. Every Perl module is a library, so the word does
the same empty work as `API` or `Interface`. `OpenHAP` and `FuguVM` are
applications, and PAUSE puts applications under `App::`.

Nine module names are wrong in four ways. Some name a mechanism instead of a
feature: `FuguVM::Expect` names a CPAN dependency, `OpenHAP::DeviceLoader` and
`OpenHAP::Tasmota::Base` name a role in the code. Some claim more than they
hold: `FuguLib::MDNS` implements no mDNS, and only controls `mdnsd(8)`. Some
collide or mislead: `FuguVM::VM` repeats its parent, `OpenHAP::Server` collides
with `Protocol::HAP::Server`, and `FuguVM::Image` and `FuguVM::ImageCache` are
two caches of two different artefacts. Some are simply stale or empty:
`Protocol::HAP::PIN` uses a word the specification replaced with "setup code",
and `FuguLib::Util` hides three unrelated functions behind a general noun.

`FuguLib::Imsg` mixes two jobs. It encodes and decodes the imsg(3) frame, and it
also owns a socket. The codec is reusable; the socket is not.

`Protocol::HAP` is the one namespace that already follows the guidance. It is
the model for this effort.

The project has no users. A clean break is possible.

## Goals

1. The repository holds five namespaces: `App::OpenHAP`, `App::FuguVM`, `Fugu`,
   `Protocol::HAP`, and `Protocol::Imsg`.
2. The repository claims exactly one top-level name, `Fugu`. It is a nexus of 21
   modules, so the guidance permits it. `App::` and `Protocol::` are shared
   namespaces that the project joins.
3. No module name repeats its parent, describes a dependency instead of a
   feature, claims a capability the module does not hold, or uses a word the
   specification has replaced.
4. `Protocol::Imsg` is a sans-IO codec. `Fugu::Imsg` owns the socket and uses
   the codec.
5. Every implementation of a `Protocol::` contract lives beside the contract.
   `Protocol::HAP::Store::File` joins `Protocol::HAP::Store::Memory`, and one
   test proves the contract over both.
6. Behavior does not change, with two exceptions: `hapctl` prints a device
   class, so its output and its manual change with the package names, and the
   file store takes the path of its directory from the caller.

The products keep their names. The daemon is still OpenHAP, the command is still
`openhapd`, and the VM utility is still FuguVM. The one exception is FuguLib:
the collection itself is now called Fugu, so prose that names the collection
changes with the packages.

## Non-goals

- No CPAN release. No `$VERSION`, no `Makefile.PL`, no distribution main
  modules, and no `no_index` metadata. `TODO.md` records that work.
- No new features and no API changes, except the three that this effort forces:
  the split of `FuguLib::Util`, the split of `FuguLib::Imsg`, and the move of
  the file store into `Protocol::HAP`.

No naming question is out of scope. This is the naming effort, so every name in
the tree is decided here, and none is recorded for later.

## Accepted trade-offs

Four choices in this design have a real argument against them. Take them
knowingly.

1. **`App::` holds no command implementations.** `bin/openhapd` and `bin/hapctl`
   hold the command logic, so `App::OpenHAP::` holds libraries only. The
   counter-precedent is `Mail::SpamAssassin`: an OS-packaged daemon that keeps
   its modules in a domain namespace. Accept `App::` because both products are
   applications first, and a domain namespace would be a second top-level claim.
2. **imsg is not an interoperable wire protocol.** The header is native-endian
   and never crosses a host, while `Protocol::` on CPAN holds interoperable
   protocols. `OpenBSD::` is the honest alternative and it is unusable: OpenBSD
   base perl owns that namespace with `OpenBSD::Pledge`, `OpenBSD::Unveil`, and
   the `pkg_add` tree. `Protocol::Imsg` states the limit in its first paragraph.
3. **`Protocol::HAP::Store::File` opens files inside the protocol tier.** The
   tier holds a sans-IO engine, and a store that writes files is not sans-IO.
   Accept it, because sans-IO describes `Protocol::HAP::Server`, and the store
   is the injected seam that keeps the engine pure. `Protocol::HAP::Controller`
   already opens TCP sockets in this tier, so four files set no new precedent.
   The alternative puts the only file store of `Protocol::HAP::Store` where no
   user of the library looks for it.
4. **Leaf names repeat.** Goal 3 does not claim unique leaf names. `Proxy`,
   `Config`, and `CLI` each repeat, every time as a subclass of the `Fugu::`
   module with the same leaf name.

## The clean-break rule

This effort is evergreen. An old name and its replacement never exist together.

- Each rename is a `git mv` plus a rewrite. No file stays behind.
- No aliases. No `our @ISA` bridges to an old package. No empty compatibility
  module. No `use lib` trick, and no dual name in `bin/`.
- No deprecation period and no warning. A phase deletes the old name in the same
  commit that adds the new one.
- No upgrade path ships. The repository carries no code and no documentation for
  a machine with an older install.
- The old names survive in exactly one place: `plans/001` to `plans/007`. Those
  files record what was true when they were written. Do not rewrite them.

The rule needs a gate, because nothing in `make check` detects a shim today. A
new `t/scripts/namespaces.t` reads the tracked files with `git ls-files`, skips
`plans/`, and fails on any retired name. Phase 1 creates it; every later phase
appends its retired names. It replaces the hand-run greps, which fail two ways:
`grep -v 'App::OpenHAP::'` drops a whole line, so a stale name hides behind a
live one, and `grep -r` reads the generated pages in `build/` and `web/build/`.

## Target names

### Namespaces

| Now               | Target           | Reason                                |
| ----------------- | ---------------- | ------------------------------------- |
| `OpenHAP::`       | `App::OpenHAP::` | An application belongs under `App::`. |
| `FuguVM::`        | `App::FuguVM::`  | An application belongs under `App::`. |
| `FuguLib::`       | `Fugu::`         | `Lib` says nothing. One nexus stays.  |
| `Protocol::HAP::` | unchanged        | It already follows the guidance.      |
| —                 | `Protocol::Imsg` | A new sans-IO codec.                  |

### Modules that change name

| Now                          | Target                           | Reason                                                       |
| ---------------------------- | -------------------------------- | ------------------------------------------------------------ |
| `OpenHAP::Server`            | `App::OpenHAP::Host`             | It hosts the engine. Two modules must not both be `Server`.  |
| `OpenHAP::Storage`           | `Protocol::HAP::Store::File`     | It implements `Protocol::HAP::Store`, so it joins that tier. |
| `OpenHAP::DeviceLoader`      | `App::OpenHAP::Devices`          | It holds the devices. `Loader` names the mechanism.          |
| `FuguVM::VM`                 | `App::FuguVM::Guest`             | The name must not repeat the parent.                         |
| `FuguVM::Expect`             | `App::FuguVM::Console`           | It drives the serial console. `Expect` is the dependency.    |
| `OpenHAP::Tasmota::Base`     | `App::OpenHAP::Tasmota::Device`  | `Base` names a mechanism, as `Loader` did.                   |
| `FuguVM::Image`              | `App::FuguVM::Miniroot`          | It downloads and caches the install media.                   |
| `FuguVM::ImageCache`         | `App::FuguVM::DiskCache`         | It caches installed qcow2 disks, not the media above.        |
| `FuguLib::Util`              | `Fugu::Timeout`                  | `bounded` and `wait_until` are one idea.                     |
| `FuguLib::Util::format_size` | `App::FuguVM::CLI::_format_size` | The command-line interface is its only caller.               |
| `FuguLib::Store`             | `Fugu::StateFile`                | Its own abstract calls it a JSON state file.                 |
| `FuguLib::MDNS`              | `Fugu::Mdnsd`                    | It controls `mdnsd(8)`. It does not implement mDNS.          |
| `FuguLib::Imsg`              | `Fugu::Imsg` + `Protocol::Imsg`  | The codec and the socket separate.                           |
| `Protocol::HAP::PIN`         | `Protocol::HAP::SetupCode`       | The specification says "setup code" [HAP-Pairing §2].        |

Three of these need a word. `Console`, not `Installer`, because the module has
two public verbs and `fuguvm expect <script>` is a documented subcommand that
calls `run_script`. `Miniroot` and `DiskCache`, because both modules cache and
neither name says what: one fetches the install media, the other keeps the disk
the installer produced, and `ImageCache` loads `Image`, so the pair reads as a
cache of the thing above it. `Mdnsd`, because the module sends `IMSG_CTL_*` over
the control socket and no mDNS packet ever leaves it — the same fault as
`Expect`, and a worse one, because `Expect` named a dependency while `MDNS`
claims a capability.

### Names that stay, and why

These were open questions. They are decided.

- `Fugu::MQTT` and `Fugu::SSH` stay out of `Net::`. Neither implements a
  protocol. The first adapts `Net::MQTT::Simple` to a `select` loop and owns the
  reconnect policy; the second drives `ssh(1)`. Host policy belongs in the host
  nexus, and the `Net::` rule governs a top-level claim, which this is not.
- `Fugu::Proxy` stays. It is a caching HTTP proxy, so the name is honest.
- `Fugu::File` stays. Eleven functions is a lot, but they are one domain: files
  and paths. That is what separates it from `Util`.
- `Fugu::Config`, `Fugu::CLI`, `Fugu::Control`, `Fugu::JSONSocket`, and
  `Fugu::EventLoop` stay. Each is accurate inside the nexus.
- Every other `Protocol::HAP::` name stays. `TLV`, `SRP`, `Pairing`, `Session`,
  `Accessory`, `Service`, `Characteristic`, and `Bridge` are the specification's
  own words, and it calls `Server` the accessory server.

## Layering

The split of `Imsg` gives `Fugu::` a reason to use `Protocol::`. Three rules
keep the direction clear.

1. `Protocol::*` uses core Perl and the declared CPAN modules only. It never
   uses `Fugu::` or `App::`.
2. `Fugu::*` uses core Perl, its optional CPAN libraries, and the `Protocol::`
   codecs on an allowlist. The allowlist holds `Protocol::Imsg` today. `Fugu::`
   never uses `App::`, and never uses `Protocol::HAP`.
3. `App::*` uses both.

`t/protocol/boundary.t` enforces all three, but not as it stands. Direction two
matches `^(?:Protocol::HAP|OpenHAP)\b` at line 104. After the rename that
pattern matches nothing, so the rule stops being enforced without one test
failing. Phase 2 must widen it to `^App\b`, and phase 4 must add the
`Protocol::` allowlist. The plans call this out because the acceptance greps
cannot see it: the literal text is `OpenHAP)`, with no trailing colons.

## The file store

`OpenHAP::Storage` holds nothing that is specific to the host. It keeps the
twelve contract methods, the key files, the pairings format, and the counters.
All four are HAP, so the module moves to `Protocol::HAP::Store::File` whole.

Three host dependencies go away. None of them is deep.

- `FuguLib::Log` becomes an injected `logger`, with `Protocol::HAP->null_logger`
  as the default. Every other class in the tier already takes that argument.
- `FuguLib::File` gives the store four of its eleven functions: `read`, `write`
  with a mode, `write_atomic`, and `ensure_dir`. The replacement is about 80
  lines over `Fcntl` and `File::Path`. `atomic_dir`, `sweep_temp`, `share_path`,
  `expand_tilde`, and `valid_name` do not follow it.
- `FuguLib::Store` gives the store a JSON file of counters. The replacement is
  about 40 lines over `JSON::PP`, and it keeps the atomic write.

`Fcntl`, `File::Path`, and `JSON::PP` are core Perl, so direction one of the
layering rules already permits all three. The boundary test needs no new entry.

The duplicated logic that matters is the mode at the open. Two copies of that
rule can drift, and the rule protects the identity of the accessory. Thus one
test asserts the mode of every file that the store creates. Nothing asserts the
mode of `accessory_ltsk` or `pairings.db` today, so this is a gain, not a cost.

`db_path` becomes `path`, and it is required. The `/var/db/openhapd` default
moves to `openhapd`, beside the other path policy. Nothing else about the
constructor changes, and the layout on disk does not change at all.

## The Imsg contract

`Protocol::Imsg` is pure. It takes bytes and returns bytes.

- Constants: `HEADER_SIZE`, `HEADER_TEMPLATE`, `MAX_IMSGSIZE`, `MAX_PAYLOAD`,
  and `FD_MARK`, as in `spec/MDNS-Imsg.md`.
- `Protocol::Imsg->new` makes a decode buffer.
- `encode(type =>, data =>, peerid =>, pid =>)` returns the framed bytes. It
  returns undef with `$!` set to `EMSGSIZE` for an oversized payload. `pid` uses
  `$args{pid} || $$`, because imsg substitutes the sender's pid when the caller
  passes 0 [MDNS-Imsg §3]. That is the one environment value the codec reads.
- `append($bytes)` adds received bytes to the buffer.
- `next_message` pops one whole message and returns a hashref with `type`,
  `peerid`, `pid`, and `data`. It returns undef when more bytes are necessary.
  An invalid length sets `$!` to `EBADMSG` and makes the failure permanent.
- `is_failed` reports that permanent framing failure.
- `reset` empties the buffer and clears the failure. `Fugu::Imsg::close` needs
  it: it empties the buffer today, so a closed connection can never hand out a
  frame that arrived before the close.

`Fugu::Imsg` keeps `new(fh =>)`, `send`, `recv`, `close`, and `is_dead`, with
the same return values and the same `$!` values. It holds one `Protocol::Imsg`
object and does the write loop, the `SIGPIPE` guard, the `IO::Select` poll, and
the read loop.

The transport must also re-export `MAX_PAYLOAD`. `Fugu::Control` chunks its
replies with `FuguLib::Imsg::MAX_PAYLOAD` as a bareword, so the constant leaving
the module is a compile-time abort, not a runtime error.

## Wiring after the change

```mermaid
graph TD
    openhapd[bin/openhapd] --> H[App::OpenHAP::Host]
    hapctl[bin/hapctl] --> D[App::OpenHAP::Devices]
    fuguvm[bin/fuguvm] --> VC[App::FuguVM::CLI] --> G[App::FuguVM::Guest]
    G --> I[App::FuguVM::Console]
    H --> PS[Protocol::HAP::Server]
    H --> SF[Protocol::HAP::Store::File] -. store contract .-> PS
    H --> FH[Fugu: EventLoop Log MQTT MDNS Timeout]
    D --> TAS[App::OpenHAP::Tasmota::*]
    FM[Fugu::Mdnsd] --> FI[Fugu::Imsg] --> PI[Protocol::Imsg]
    FC[Fugu::Control] --> FI
    FC --> PI
```

## Testing and the build

`t/fugulib/` becomes `t/fugu/`. A tier is named after its product, and only this
product name changes. The rename also reaches 29 test files in the other tiers,
3 of which run only under `make integration`.

Six mechanisms fail quietly under a rename, and no acceptance grep can see any
of them: the `skip_all` guards in `t/fugulib/coreperl.t` and `t/fuguvm/vm.t`,
the path-prefix groups in `web/mkindex.sh`, the `TESTS` variable in
`scripts/integration`, the stale guest install that `scripts/vm-provision`
leaves in `@INC`, the `find … -exec perl -cw {} \;` in `check.yml` that always
exits 0, and the `-d "$script_lib/OpenHAP"` unveil probe in `bin/openhapd`. Each
phase names the ones it touches.

`make check` is `lint test tidy`. It does not run `prettier`, `mandoc -Tlint`,
`install`, or `package`, and `lint` and `tidy` read `lib bin scripts` only.
`t/web/site.t` skips without `lowdown` and `mandoc`, which are `develop`
dependencies. Each phase therefore names the extra commands it must run, and
ends with one `make install DESTDIR=` into an empty directory.

The `Makefile` names every namespace directory in `install`, `uninstall`, and
`package`, and renames each 3p page to `FuguLib::<stem>` in two loops.
`App::FuguVM` joins none of them: FuguVM is a development tool and is not
installed. `uninstall` must never remove a shared parent. It does
`rm -rf $(LIBDIR)/Protocol` today, which deletes every other `Protocol::`
distribution on the machine, and `App/` would be worse.

## Phases

1. `FuguLib::` becomes `Fugu::`. Names only, plus the two gates that later
   phases depend on: `t/scripts/namespaces.t` and the CI compile step.
2. `OpenHAP::` becomes `App::OpenHAP::`, with `Host`, `Devices`, and
   `Tasmota::Device`. `OpenHAP::Storage` leaves the host for
   `Protocol::HAP::Store::File`, in a commit of its own: it is the one rewrite
   in this effort, and a bisect must separate it from the namespace move.
3. `FuguVM::` becomes `App::FuguVM::`, with `Guest`, `Console`, `Miniroot`, and
   `DiskCache`.
4. `Protocol::Imsg` splits out of `Fugu::Imsg`.
5. The leaf renames that no namespace move forces: `Fugu::Timeout`,
   `Fugu::StateFile`, `Fugu::Mdnsd`, and `Protocol::HAP::SetupCode`. Then the
   documentation and website pass.

The order follows the dependency direction, from the base to the products. Phase
3 depends on phase 2, because both edit the same regex in `t/web/site.t` and in
`t/protocol/boundary.t`, and the phase-2 state must keep `FuguVM` in both. Each
phase lands whole: the modules, their callers, their tests, their manuals, and
the build rules change together.
