# Phase 1 — mDNS without exec

Replace the `mdnsctl publish` child with a native client speaking imsg over
`/var/run/mdnsd.sock`. This phase changes no security posture on its own; it
removes the only `exec` in the daemon, which is what lets phase 2 pledge without
`proc exec`. Independently shippable: it deletes a child process, a log file,
and a kill-on-shutdown path.

## Tasks

### 1.1 Verify the mdnsd ABI before writing the client

`FuguLib::MDNS` sends a raw `struct mdns_service`, so the wire format is
openmdns' in-memory layout. Derive it, then **prove** it against the installed
port rather than trusting the derivation. Two independent checks, both run
inside the OpenBSD VM (`make integration`, or the `openhvf` skill for an
interactive shell):

1. Compile a three-line C program against `/usr/local/include/mdns.h` that
   prints `sizeof(struct mdns_service)` and `offsetof` for every field, and
   compare with the table below.
2. Capture what `mdnsctl publish` actually sends.
   `ktrace -i mdnsctl publish ...` plus `kdump` shows the `write(2)` payloads on
   the control socket; the first four messages are the conversation to
   replicate.

Check 2 also settles three things the header cannot: whether `app` carries `hap`
or `_hap` (`mdnsctl/parser.c` may normalise what `MDNS.pm:93` passes as `hap`),
what `mdnsctl` puts in `target`/`addr`, and what `priority`/`weight` default to.

Derived layout (LP64), to be confirmed, not assumed:

| offset | field      | C type           | bytes |
| ------ | ---------- | ---------------- | ----- |
| 0      | `entry`    | `LIST_ENTRY`     | 16    |
| 16     | `app`      | `char[64]`       | 64    |
| 80     | `proto`    | `char[4]`        | 4     |
| 84     | `name`     | `char[256]`      | 256   |
| 340    | `target`   | `char[256]`      | 256   |
| 596    | `priority` | `u_int16_t`      | 2     |
| 598    | `weight`   | `u_int16_t`      | 2     |
| 600    | `port`     | `u_int16_t`      | 2     |
| 602    | `txt`      | `char[256]`      | 256   |
| 858    | (padding)  |                  | 2     |
| 860    | `addr`     | `struct in_addr` | 4     |

864 bytes total, from `MAXLABELLEN` 64, `MAXPROTOLEN` 4, `MAXHOSTNAMELEN` 256
and `MAXCHARSTR` = `MAXHOSTNAMELEN`. The `LIST_ENTRY` is mdnsd's own list
linkage, two pointers wide, and is sent as zeros.

Record the confirmed numbers in the commit message and as constants in the code.
If the measured layout differs, the constants change and the rest of the phase
is unaffected — that is the point of doing this first.

### 1.2 `FuguLib::Imsg`

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
`t/fugulib/imsg.t`. The test is platform-independent — round-trip over a
`socketpair`, byte-exact header assertions, an oversized payload rejection, a
truncated-header read, and a two-messages-in-one-read case.

### 1.3 `FuguLib::MDNS`

The mdnsd group protocol, OpenHAP-agnostic:

- Constants for the `imsg_type` enum values used here. The enum is positional,
  so pin all of `IMSG_NONE`(0) through `IMSG_CTL_GROUP_PUBLISHED`(17) in order
  and name the openmdns version they came from in a comment.
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
- TXT records join with `.`, preserving the convention and hazard documented at
  `MDNS.pm:80-82`; the module states the constraint in its man page so the
  `pv=1` workaround at `HAP.pm:1087` has something to point at.
- Group-name and instance-name inputs longer than the field are an error, not a
  silent truncation.

Ships with `man/fugulib/MDNS.3p`, a `MAN3P` entry, and `t/fugulib/mdns.t`. The
test stands up a temporary `AF_UNIX` listener as a fake mdnsd, asserts the exact
bytes of all four messages against the confirmed layout, and drives the reply
paths: `PUBLISHED`, `ERR_COLLISION`, `ERR_DOUBLE_ADD`, EOF mid-conversation, and
a reply timeout. It runs on Linux and Darwin unchanged, which is where CI will
exercise it.

### 1.4 Rewire `openhapd` and delete `OpenHAP::MDNS`

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

### 1.5 Ordering, privileges, and documentation

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

### 1.6 Integration coverage

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
- `t/fugulib/imsg.t`, `t/fugulib/mdns.t`, new integration assertions
- Changes to `bin/openhapd`, `lib/OpenHAP/HAP.pm`, `man/openhap/openhapd.8`
- Deleted: `lib/OpenHAP/MDNS.pm`, `lib/OpenHAP/MDNS.pod`, `t/openhap/mdns.t`

## Acceptance criteria

- The measured `struct mdns_service` layout matches the constants in
  `FuguLib::MDNS`, verified by task 1.1 and asserted by a test that fails loudly
  on mismatch.
- `mdnsctl browse` in the VM sees the service, its TXT updates on pairing state
  change, and it disappears when the daemon exits.
- `openhapd` spawns no child process at all: `pgrep -P $(pgrep openhapd)` is
  empty.
- A missing or unreachable `/var/run/mdnsd.sock` logs a warning and leaves the
  HAP server serving, exactly as a missing `mdnsctl` does today.
- `make check` green on Linux (unit tests use `socketpair`/`AF_UNIX` and need no
  mdnsd); `make integration` green on OpenBSD.
- `mandoc -Tlint -W warning` clean for both new man pages.
