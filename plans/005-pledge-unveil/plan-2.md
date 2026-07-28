# Phase 2 — mDNS client without exec

Replace the `mdnsctl publish` child with a native client speaking imsg over
`/var/run/mdnsd.sock`, implemented against the phase 1 spec. This phase changes
no security posture on its own; it removes the only `exec` in the daemon, which
is what lets phase 3 pledge without `proc exec`. Independently shippable: it
deletes a child process, a log file, and a kill-on-shutdown path.

Depends on phase 1 for `spec/MDNS-Imsg.md` and `spec/MDNS-Control.md`, and
specifically on measurements 2, 4 and 5 from task 1.2 — the `imsg_hdr` layout,
whether same-socket TXT replacement works, and whether the group name must equal
the instance name. **Those three decide this phase's API. Do not start until
they are recorded in the spec.**

## Tasks

### 2.1 `FuguLib::Imsg`

Framing only, no mdnsd knowledge:

- `new(fh => $fh)` over an already-connected handle, so tests can use a
  `socketpair` and the module never opens anything itself.
- `send(type => $n, data => $bytes)` — header **as recorded in
  `spec/MDNS-Imsg.md`** from the installed `/usr/include/imsg.h`, followed by
  payload. Do not hardcode a layout from this plan: the field set changed in the
  2024 imsg rework (`len` widened to `uint32_t`, `flags` removed), so a
  plan-time guess would be wrong on one side of that change. Pin the field
  widths and order as named constants in one place, with a comment citing the
  spec section.
- Refuse payloads that exceed the **payload** bound rather than truncating.
  `MAX_IMSGSIZE` bounds the whole message, so the bound is
  `MAX_IMSGSIZE - sizeof(imsg_hdr)`, not `MAX_IMSGSIZE`.
- `recv(timeout => $seconds)` — buffered, returns `{ type, data }` for one whole
  message, `undef` on timeout or clean EOF; short reads accumulate across calls.
  `IO::Select` for the timeout, never `alarm`.
- **`$SIG{PIPE}`.** Writing to a socket the peer has closed raises SIGPIPE,
  which Perl does not ignore by default and `IO::Socket::UNIX` does not
  suppress. `send` must localise `$SIG{PIPE} = 'IGNORE'` and return `undef` with
  `$!` set to `EPIPE`, or a peer that closes mid-conversation kills the whole
  process — which is exactly what the EOF test in 2.2 exercises.
- A private encoder seam. The conformance test in 2.3 has to assert encoded
  bytes against a literal, and none of the public methods returns them, so
  expose the header encoder as a testable internal (`_encode_header`) rather
  than leaving the test to scrape a socketpair.
- No fd passing (`SCM_RIGHTS`): the mdnsd group protocol does not use it, and
  omitting it keeps `sendfd`/`recvfd` out of the promise set.

**No logging.** No module under `lib/FuguLib/` references a logger, and the
convention is that the caller decides — `Privdrop` dies, `Process` reports
through `on_error`/`on_success` callbacks. Return outcomes; let `bin/openhapd`
log. Reaching for `$OpenHAP::logger` from `lib/FuguLib/` would contradict the
namespace split in `CLAUDE.md` and would die in `t/fugulib/*.t`, which sets no
OpenHAP globals.

Ships with `man/fugulib/Imsg.3p`, a `MAN3P` entry in the `Makefile`, and
`t/fugulib/imsg.t`. The module test is platform-independent — round-trip over a
`socketpair`, an oversized payload rejection, a truncated-header read, a
two-messages-in-one-read case, and a write-after-peer-close returning `undef`
rather than dying. Byte-exact header assertions belong in the conformance test
(2.3), not here.

The man page documents the API. It does not restate the framing — that is
`spec/MDNS-Imsg.md`'s job — and points there instead.

### 2.2 `FuguLib::MDNS`

The mdnsd group protocol, OpenHAP-agnostic:

- Constants for the `imsg_type` enum values used here. The enum is positional,
  so pin all of `IMSG_NONE`(0) through `IMSG_CTL_GROUP_PUBLISHED`(17) in order,
  taken from `spec/MDNS-Control.md` rather than re-read from the header, with a
  comment citing the section.
- `new(socket_path => ...)` defaulting to `/var/run/mdnsd.sock`. **No separate
  `group` parameter** if measurement 5 confirmed that mdnsd looks the group up
  under the service's name and `libmdns` enforces `group == name`: in that case
  the group name is derived from the instance name inside `publish_service`, and
  the unusable combination is simply not expressible. If measurement 5 refuted
  it, keep `group` and say so.
- `connect()` — `IO::Socket::UNIX` `SOCK_STREAM`; returns `undef` when the
  socket is missing or unreachable, matching how `MDNS.pm:70` treats a missing
  `mdnsctl` today. The caller logs.
- `publish_service(name =>, app =>, proto =>, port =>, txt =>, timeout =>)` —
  `GROUP_ADD`, `GROUP_ADD_SERVICE`, `GROUP_COMMIT`, then read replies until
  `GROUP_PUBLISHED`, an error type, or timeout. `GROUP_PROBING` and
  `GROUP_ANNOUNCING` are not terminal. `timeout` defaults to 2s but **must be a
  parameter**: with it hardcoded, the timeout subtest is an unavoidable 2-second
  wall-clock wait in every `make check` run and cannot be made resilient to
  timing variation as `CLAUDE.md` requires.
- `txt` is a **formatted string**, already `key=value` pairs joined per the
  encoding section of `spec/MDNS-Control.md`. `FuguLib::MDNS` does not know what
  a TXT key means. See 2.4 for where the formatting lives.
- `update_txt(txt => ...)` — mechanism **per measurement 4**. If same-socket
  `GROUP_RESET` → `GROUP_ADD_SERVICE` → `GROUP_COMMIT` was shown to work, do
  that. If it was shown to re-announce the stale record or to crash mdnsd — the
  likely outcome from reading `control_group_reset`'s `pg_get(0, msg, NULL)`
  lookup — then `update_txt` closes and republishes, which is what
  `MDNS.pm:176-183` does today and what `control_close` cleans up correctly.
  Retain `name`/`app`/`proto`/`port` from `publish_service` so `update_txt` can
  re-send `GROUP_ADD_SERVICE` without them being passed again. Whichever path is
  taken, comment it with the spec citation, because the wrong one fails
  silently.
- `withdraw()` — close the socket; that is the entire operation.
- `is_published()` — used by `OpenHAP::HAP` to avoid driving updates onto an
  unpublished handle (2.4).
- Group-name and instance-name inputs longer than the field are an error, not a
  silent truncation.
- The `struct mdns_service` field offsets and size come from the spec, as named
  constants in one place, so an openmdns change is a one-line edit next to a
  citation. Include the architecture the layout was measured on in that comment
  — the `LIST_ENTRY` width and the 864-byte total are LP64-specific.
- No logging, for the reasons in 2.1.

Ships with `man/fugulib/MDNS.3p`, a `MAN3P` entry, and `t/fugulib/mdns.t`. The
module test stands up a temporary `AF_UNIX` listener as a fake mdnsd and drives
the reply paths — `PUBLISHED`, `ERR_COLLISION`, `ERR_DOUBLE_ADD`, EOF
mid-conversation, a short reply timeout, and an over-length name — on Linux and
Darwin unchanged, which is where CI exercises it. The EOF case depends on 2.1's
`$SIG{PIPE}` handling and the timeout case on the `timeout` parameter; neither
is testable without them.

### 2.3 Conformance tests

Per `t/CLAUDE.md`, one `.t` per normative topic file, named after the lowercased
stem: `t/conformance/mdns-imsg.t` and `t/conformance/mdns-control.t`. This is
the tier that closes the loop opened in phase 1 — the spec records what the
protocol is, these assert our encoder produces it.

Both follow the conformance rules: every subtest name starts with a citation,
wire examples are replayed byte-exactly, vectors live inline with no network and
no `external/`, `Test::More` + `subtest`, `skip_all` on missing CPAN
dependencies.

- `mdns-imsg.t` — header encoding field by field against `[MDNS-Imsg §…]`, via
  2.1's `_encode_header` seam: field widths and order as measured, whether `len`
  counts the header, the payload-bound refusal, and message-boundary handling on
  a split read. Do not assert "byte order" against a little-endian capture while
  the encoder uses native-endian `pack` — that assertion is tautological on
  every host this repo runs on and protects nothing. Assert the field _layout_,
  which is what can actually be wrong.
- `mdns-control.t` — the `imsg_type` ordinals; `struct mdns_service` encoded
  byte-exactly, including the zeroed `LIST_ENTRY`, the internal padding, and NUL
  padding of each fixed field; TXT `.` joining; the reply/error type meanings;
  and the publish conversation from the spec's worked example.

Two constraints on "byte-exact" that the spec's worked example must respect:

- **The header carries the sender's pid.** The captured conversation holds
  `mdnsctl`'s pid; our encoder writes the test process's. Assert the
  sender-specific bytes are _well-formed_ (the pid field equals `$$`) and the
  rest byte-for-byte, and say so in the subtest name. Claiming a literal
  whole-message match would be a criterion no implementation can meet.
- **Assert the whole `struct mdns_service` buffer against a literal**, not field
  by field — a field-by-field check passes even when the total size or padding
  is wrong. This is the assertion that matters most: it is the only thing
  standing between an openmdns layout change and a daemon that silently
  advertises garbage. Guard it on LP64 so it fails as a skip with a reason on a
  32-bit OpenBSD rather than as a mysterious 8-byte mismatch.

`make spec-coverage` should now report real coverage for both topic files where
it reported 0 in phase 1.

### 2.4 Rewire `openhapd`, move the TXT formatting, and delete `OpenHAP::MDNS`

- **Move the TXT formatting into `OpenHAP::HAP`.** `plan-2`'s earlier draft
  claimed this knowledge "already lives in `HAP::get_mdns_txt_records`". It does
  not: `HAP.pm:1085-1106` returns a bare hashref, and the `key=value` formatting
  _and_ the deterministic `sort keys` ordering live at `MDNS.pm:85-87`, inside
  the module being deleted. Add a method beside `get_mdns_txt_records` that
  returns the formatted string, and keep the ordering deterministic — mdnsd's
  TXT delimiter makes ordering observable, and `t/openhap/mdns.t:239` tests it
  today. That test's successor lives in `t/openhap/hap.t`.
- `bin/openhapd`: replace the `OpenHAP::MDNS->new(...)` construction
  (`:108-112`) with `FuguLib::MDNS`, and `register_service` (`:157`) with
  `connect` + `publish_service`, passing `hap`/`tcp` and the formatted TXT
  string from the call site. Log the outcome here — the module does not.
- **`OpenHAP::HAP` must guard on `is_published`.** `set_mdns` keeps its
  signature, but `$hap->set_mdns($mdns)` runs at `bin/openhapd:113`, long before
  the connect, and `HAP::_refresh_mdns` (`HAP.pm:138-153`) guards only on
  `defined $self->{mdns}` before calling the update at `:148`. Today that is
  safe _only_ because `OpenHAP::MDNS::update_txt_records` short-circuits with
  `return 1 unless $self->{registered}` (`MDNS.pm:181`) — a guard inside the
  deleted module. Without a replacement, a daemon that started with `mdnsd` down
  writes to a closed handle the first time a user pairs. Add the `is_published`
  check in `_refresh_mdns`, and make `update_txt` a no-op when unpublished as
  well: two guards, because this one kills the daemon at pairing time. (Note:
  there is no `HAP::update_txt_records` sub — `HAP.pm:148` is a _call_ into the
  mdns object from `HAP::_refresh_mdns`.)
- The shutdown cleanup (`bin/openhapd:166-176`) calls `withdraw` instead of
  `unregister_service`.
- Remove the `$db_path/mdnsctl.log` machinery and the now-unused `log_dir`
  plumbing. Check whether `FuguLib::Process` retains any other caller; if
  `spawn_command`/`terminate` become dead code, say so in the commit message and
  leave removal to a separate change — `FuguLib` is a library and its API is not
  ours to prune on the way past.

### 2.5 The full consumer inventory

Deleting `lib/OpenHAP/MDNS.pm` and `.pod` breaks five other files. Every one
needs a disposition **in this phase**, or neither `make check` nor
`make integration` can be green as the acceptance criteria require:

| file                                   | disposition                                                                                                                                                                                                                                                        |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `t/openhap/mdns.t`                     | Delete. Move the TXT-ordering coverage (`:239`) to `t/openhap/hap.t` against the new formatter.                                                                                                                                                                    |
| `t/conformance/hap-mdns.t`             | **Rewrite, do not delete.** `:23` does `use_ok('OpenHAP::MDNS')` and `:37`, `:94`, `:181`, `:190` construct it. Re-point those four subtests at `OpenHAP::HAP`'s TXT formatter and the `FuguLib::MDNS` call arguments. See the note below.                         |
| `t/openhap/integration/mdns-cleanup.t` | **Rewrite or delete — its premise is inverted.** `:32` asserts `mdnsctl_count > 0` and `:37` asserts captured mdnsctl PIDs. Integration tests never skip, so this fails deterministically after this phase. Fold whatever survives into the new assertions in 2.6. |
| `t/openhap/integration/mdns.t`         | `:19-22` dies unless the `mdnsctl` _binary_ exists. Change the precondition to `mdnsd` running; `mdnsctl` is now only a test tool for browsing.                                                                                                                    |
| `scripts/integration`                  | Still `pkill`s `mdnsctl` as pre-run cleanup (`:41-49`) and greps for it in failure diagnostics (`:98`). Both become dead; remove them.                                                                                                                             |

`t/conformance/hap-mdns.t` deserves care beyond "make it compile":
**`[HAP-mDNS §10]` is cited nowhere else in the tree** — only at
`t/conformance/hap-mdns.t:89`, inside one of the four subtests that constructs
the deleted module. `[HAP-mDNS §4]` and `[HAP-mDNS §6]` are likewise cited there
and otherwise only in `t/openhap/integration/mdns.t`, which moves them out of
`make check` and into the VM. So a careless rewrite silently lowers HAP-mDNS
coverage, and phase 5's "coverage no lower than phase 2 left it" would then
measure against an already-regressed baseline. **Record HAP-mDNS coverage before
and after this phase and keep it equal.**

### 2.6 Ordering, privileges, and documentation

- Keep the current ordering — privdrop, then advertise — and update the stale
  comment at `bin/openhapd:115-117`, which explains it in terms of killing a
  child process.
- **Do not assert the wheel privilege model without measuring it.** The comment
  at `:116` says `_openhap` must be in `wheel` to reach `/var/run/mdnsd.sock`
  (root:wheel 0660). But `FuguLib::Privdrop::drop_privileges` calls only
  `POSIX::setgid`/`setuid` and never `setgroups`/`initgroups`, and Perl's
  `$) = $gid` assignment at `Privdrop.pm:73` itself invokes `setgroups` — which
  would _drop_ wheel rather than keep it. Whatever actually grants access today,
  it is not obviously the stated mechanism. Measure it in the VM (`id` as the
  running daemon, plus an `unveil`-free connect attempt) and write down what is
  true. Phase 5 documents this in `openhapd.8`, so a false claim here becomes a
  false claim about a privilege boundary in an installed man page.
- `man/openhap/openhapd.8`: the daemon no longer spawns a child and needs
  `mdnsd(8)` running rather than `mdnsctl(8)` installed. Add `mdnsd(8)` to SEE
  ALSO. Note that neither this page nor `.claude/skills/openhapd/SKILL.md`
  currently mentions `mdnsctl` or `mdnsctl.log`, so there is no stale text to
  fix there — only the new requirement to state.
- `deps/OpenBSD.txt` keeps `openmdns` — the daemon is still required; only the
  CLI is no longer invoked by `openhapd`. It remains a test dependency for
  browsing.
- `.github/workflows/`: the workflows filter on explicit path includes
  (`81baa1b`). Confirm `lib/FuguLib/**`, `t/fugulib/**`, `t/conformance/**` and
  `spec/**` are covered, or the new tests silently never run in CI.

### 2.7 Integration coverage

Extend `t/openhap/integration/` (which never skips — see
`t/openhap/integration/CLAUDE.md`) to assert, inside the VM:

- `mdnsctl browse _hap._tcp` sees the advertised service after `openhapd`
  starts.
- No child process at all: `pgrep -P $(pgrep openhapd)` is empty, and no
  `mdnsctl.log` is created.
- The TXT record changes after a pairing state change (`sf` flips). This is the
  assertion that catches a broken `update_txt` — and given measurement 4, it is
  the most important test in this phase, because the failure mode is a _silent_
  stale record with a successful-looking reply sequence. Assert the browsed TXT,
  never the return value.
- The advertisement disappears within a few seconds of `openhapd` exiting, which
  is the socket-close contract.
- The daemon starts and serves with `mdnsd` stopped, logging a warning.

Assert on observable behaviour, not on log contents —
`t/openhap/integration/CLAUDE.md` forbids parsing logs.

## Deliverables

- `lib/FuguLib/Imsg.pm`, `lib/FuguLib/MDNS.pm`
- `man/fugulib/Imsg.3p`, `man/fugulib/MDNS.3p`, `Makefile` `MAN3P` entries
- `t/fugulib/imsg.t`, `t/fugulib/mdns.t`
- `t/conformance/mdns-imsg.t`, `t/conformance/mdns-control.t`
- A TXT formatter on `OpenHAP::HAP` plus its test in `t/openhap/hap.t`
- Rewritten `t/conformance/hap-mdns.t`; rewritten or deleted
  `t/openhap/integration/mdns-cleanup.t`; changed
  `t/openhap/integration/mdns.t`, `scripts/integration`
- New integration assertions in `t/openhap/integration/`
- Changes to `bin/openhapd`, `lib/OpenHAP/HAP.pm`, `man/openhap/openhapd.8`
- Deleted: `lib/OpenHAP/MDNS.pm`, `lib/OpenHAP/MDNS.pod`, `t/openhap/mdns.t`

## Acceptance criteria

- `t/conformance/mdns-control.t` asserts the whole encoded `struct mdns_service`
  against a literal; changing any offset constant makes it fail.
- `make spec-coverage` reports non-zero coverage for `MDNS-Imsg` and
  `MDNS-Control`, exits zero, and **HAP-mDNS coverage is unchanged from before
  this phase**.
- `mdnsctl browse` in the VM sees the service, the browsed TXT updates on a
  pairing state change, and the advertisement disappears when the daemon exits.
- `openhapd` spawns no child process at all: `pgrep -P $(pgrep openhapd)` is
  empty.
- A missing or unreachable `/var/run/mdnsd.sock` logs a warning and leaves the
  HAP server serving; pairing while unpublished does not kill the daemon.
- `make check` green on Linux (tests use `socketpair`/`AF_UNIX` and need no
  mdnsd); `make integration` green on OpenBSD — which requires every row of 2.5
  to have been carried out.
- `mandoc -Tlint -W warning` clean for both new man pages.
