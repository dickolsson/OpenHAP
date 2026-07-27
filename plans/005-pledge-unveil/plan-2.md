# Phase 2 — mDNS client without exec

Replace the `mdnsctl publish` child with a native client speaking imsg over
`/var/run/mdnsd.sock`, implemented against the phase 1 spec. This phase changes
no security posture on its own; it removes the only `exec` in the daemon, which
is what lets phase 3 pledge without `proc exec`. Independently shippable: it
deletes a child process, a log file, and a kill-on-shutdown path.

Depends on phase 1 for `spec/MDNS-Imsg.md` and `spec/MDNS-Control.md` — the
measured `struct mdns_service` layout, the `imsg_type` ordinals, and the
byte-exact publish conversation all come from there, and the conformance tests
cite it.

## Tasks

### 2.1 `FuguLib::Imsg`

Framing only, no mdnsd knowledge:

- `new(fh => $fh)` over an already-connected handle, so tests can use a
  `socketpair` and the module never opens anything itself.
- `send(type => $n, data => $bytes)` — 16-byte native-endian header (`type` u32,
  `len` u16 **including** the header, `flags` u16 zero, `peerid` u32 zero, `pid`
  u32 `$$`) followed by payload. Refuse payloads that would exceed
  `MAX_IMSGSIZE` (16384) rather than truncating.
- `recv(timeout => $seconds)` — buffered, returns `{ type, data }` for one whole
  message, `undef` on timeout or clean EOF; short reads accumulate across calls.
  `IO::Select` for the timeout, never `alarm`.
- No fd passing (`SCM_RIGHTS`): the mdnsd group protocol does not use it, and
  omitting it keeps `sendfd`/`recvfd` out of the promise set.

Ships with `man/fugulib/Imsg.3p`, a `MAN3P` entry in the `Makefile`, and
`t/fugulib/imsg.t`. The module test is platform-independent — round-trip over a
`socketpair`, an oversized payload rejection, a truncated-header read, and a
two-messages-in-one-read case. Byte-exact header assertions belong in the
conformance test (2.3), not here; module tests verify API behaviour and error
paths, the conformance tier verifies the wire format.

The man page documents the API. It does not restate the framing — that is
`spec/MDNS-Imsg.md`'s job — and points there instead.

### 2.2 `FuguLib::MDNS`

The mdnsd group protocol, OpenHAP-agnostic:

- Constants for the `imsg_type` enum values used here. The enum is positional,
  so pin all of `IMSG_NONE`(0) through `IMSG_CTL_GROUP_PUBLISHED`(17) in order,
  taken from `spec/MDNS-Control.md` rather than re-read from the header, with a
  comment citing the section.
- `new(socket_path => ..., group => ...)` defaulting to `/var/run/mdnsd.sock`.
- `connect()` — `IO::Socket::UNIX` `SOCK_STREAM`; returns `undef` with a warning
  when the socket is missing or unreadable, matching how `MDNS.pm:70` treats a
  missing `mdnsctl` today.
- `publish_service(name =>, app =>, proto =>, port =>, txt =>)` — `GROUP_ADD`,
  `GROUP_ADD_SERVICE`, `GROUP_COMMIT`, then read replies with a bounded timeout
  (2s) until `GROUP_PUBLISHED`, an error type, or timeout. `GROUP_PROBING` and
  `GROUP_ANNOUNCING` are logged at debug and are not terminal.
- `update_txt(txt => ...)` — `GROUP_RESET`, `GROUP_ADD_SERVICE`, `GROUP_COMMIT`
  on the **same** socket. No reconnect, no withdraw-and-republish.
- `withdraw()` — close the socket; that is the entire operation.
- `is_published()`.
- TXT records join with `.`, per the encoding section of `spec/MDNS-Control.md`;
  the man page points at that section so the `pv=1` workaround at `HAP.pm:1087`
  has something to cite.
- Group-name and instance-name inputs longer than the field are an error, not a
  silent truncation.
- The `struct mdns_service` field offsets and size come from the spec, as named
  constants in one place, so an openmdns change is a one-line edit next to a
  citation.

Ships with `man/fugulib/MDNS.3p`, a `MAN3P` entry, and `t/fugulib/mdns.t`. The
module test stands up a temporary `AF_UNIX` listener as a fake mdnsd and drives
the reply paths — `PUBLISHED`, `ERR_COLLISION`, `ERR_DOUBLE_ADD`, EOF
mid-conversation, a reply timeout, and an over-length name — on Linux and Darwin
unchanged, which is where CI exercises it.

### 2.3 Conformance tests

Per `t/CLAUDE.md`, one `.t` per normative topic file, named after the lowercased
stem: `t/conformance/mdns-imsg.t` and `t/conformance/mdns-control.t`. This is
the tier that closes the loop opened in phase 1 — the spec records what the
protocol is, these assert our encoder produces it.

Both follow the conformance rules: every subtest name starts with a citation,
wire examples are replayed byte-exactly, vectors live inline with no network and
no `external/`, `Test::More` + `subtest`, `skip_all` on missing CPAN
dependencies.

- `mdns-imsg.t` — header encoding field by field against `[MDNS-Imsg §…]`: byte
  order, `len` counting the header, `MAX_IMSGSIZE` refusal, message-boundary
  handling on a split read.
- `mdns-control.t` — the `imsg_type` ordinals; `struct mdns_service` encoded
  byte-exactly, including the zeroed `LIST_ENTRY`, the internal padding, and NUL
  padding of each fixed field; TXT `.` joining; the full publish conversation
  from the spec's worked example, replayed byte-for-byte; and the reply/error
  type meanings.

The struct assertion is the one that matters most: it is the only thing standing
between an openmdns layout change and a daemon that silently advertises garbage.
Assert the whole 864-byte buffer against a literal, not field by field — a
field-by-field check passes even when the total size or padding is wrong.

`make spec-coverage` should now report real coverage for both topic files where
it reported 0 in phase 1.

### 2.4 Rewire `openhapd` and delete `OpenHAP::MDNS`

- `bin/openhapd`: replace the `OpenHAP::MDNS->new(...)` construction
  (`:108-112`) with `FuguLib::MDNS`, and `register_service` (`:157`) with
  `connect` + `publish_service`, passing `hap`/`tcp` and
  `$hap->get_mdns_txt_records` from the call site.
- `OpenHAP::HAP`: `set_mdns` keeps its signature; `update_txt_records`
  (`HAP.pm:148`) calls `update_txt`.
- The shutdown cleanup (`bin/openhapd:166-176`) calls `withdraw` instead of
  `unregister_service`.
- Delete `lib/OpenHAP/MDNS.pm`, `lib/OpenHAP/MDNS.pod`, and `t/openhap/mdns.t`
  (or move whatever coverage in it is not mdnsctl-specific).
- Remove the `$db_path/mdnsctl.log` machinery and the now-unused `log_dir`
  plumbing. Check whether `FuguLib::Process` retains any other caller; if
  `spawn_command`/`terminate` become dead code, say so in the commit message and
  leave removal to a separate change — `FuguLib` is a library and its API is not
  ours to prune on the way past.

### 2.5 Ordering, privileges, and documentation

- `/var/run/mdnsd.sock` is root:wheel, so the existing requirement that
  `_openhap` be in `wheel` (`bin/openhapd:116`) still holds, and the connection
  can still be made after privdrop. Keep the current ordering — privdrop, then
  advertise — and update the stale comment at `:115-117` that explains it in
  terms of killing a child process.
- `man/openhap/openhapd.8`: the daemon no longer spawns a child, no longer
  writes `mdnsctl.log`, and needs `mdnsd(8)` running rather than `mdnsctl(8)`
  installed. Add `mdnsd(8)` to SEE ALSO.
- `deps/OpenBSD.txt` keeps `openmdns` — the daemon is still required; only the
  CLI is no longer invoked.
- `.claude/skills/openhapd/SKILL.md`: update any procedure that greps for the
  `mdnsctl` child or reads `mdnsctl.log`.

### 2.6 Integration coverage

Extend `t/openhap/integration/` (which never skips — see
`t/openhap/integration/CLAUDE.md`) to assert, inside the VM:

- `mdnsctl browse _hap._tcp` sees the advertised service after `openhapd`
  starts.
- No `mdnsctl` process is a child of `openhapd`, and no `mdnsctl.log` is
  created.
- The TXT record changes after a pairing state change (`sf` flips).
- The advertisement disappears within a few seconds of `openhapd` exiting, which
  is the socket-close contract.

## Deliverables

- `lib/FuguLib/Imsg.pm`, `lib/FuguLib/MDNS.pm`
- `man/fugulib/Imsg.3p`, `man/fugulib/MDNS.3p`, `Makefile` `MAN3P` entries
- `t/fugulib/imsg.t`, `t/fugulib/mdns.t`
- `t/conformance/mdns-imsg.t`, `t/conformance/mdns-control.t`
- New integration assertions in `t/openhap/integration/`
- Changes to `bin/openhapd`, `lib/OpenHAP/HAP.pm`, `man/openhap/openhapd.8`
- Deleted: `lib/OpenHAP/MDNS.pm`, `lib/OpenHAP/MDNS.pod`, `t/openhap/mdns.t`

## Acceptance criteria

- `t/conformance/mdns-control.t` asserts the whole encoded `struct mdns_service`
  against a literal and replays the spec's publish conversation byte-for-byte;
  changing any offset constant makes it fail.
- `make spec-coverage` reports non-zero coverage for `MDNS-Imsg` and
  `MDNS-Control`, and exits zero — no stale citations.
- `mdnsctl browse` in the VM sees the service, its TXT updates on pairing state
  change, and it disappears when the daemon exits.
- `openhapd` spawns no child process at all: `pgrep -P $(pgrep openhapd)` is
  empty.
- A missing or unreachable `/var/run/mdnsd.sock` logs a warning and leaves the
  HAP server serving, exactly as a missing `mdnsctl` does today.
- `make check` green on Linux (tests use `socketpair`/`AF_UNIX` and need no
  mdnsd); `make integration` green on OpenBSD.
- `mandoc -Tlint -W warning` clean for both new man pages.
