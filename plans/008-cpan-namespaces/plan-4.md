# Phase 4 — Protocol::Imsg splits out of Fugu::Imsg

`Fugu::Imsg` does two jobs. It frames and unframes imsg(3) messages, and it owns
a socket. The framing is a wire format that another program can reuse. The
socket is host policy. This phase separates them.

The phase depends on phase 1 only.

## Tasks

### 4.1 Create Protocol::Imsg

- New `lib/Protocol/Imsg.pm`. It holds the constants, the header pack and
  unpack, and the message extraction. It performs no system call, and it opens
  no file.
- Move these from `Fugu::Imsg`: `HEADER_SIZE`, `HEADER_TEMPLATE`,
  `MAX_IMSGSIZE`, `MAX_PAYLOAD`, `FD_MARK`, `_encode_header`, `_decode_header`,
  and `_extract_message`. The spec citations move with the code.
- The public API is `new`, `encode`, `append`, `next_message`, `is_failed`, and
  `reset`, as the design defines them.
- `encode` uses `$args{pid} || $$`, not `//`. imsg substitutes the sender's pid
  when the caller passes 0 [MDNS-Imsg §3], so a `//` default would emit a wire
  value that native imsg never produces.
- `reset` empties the buffer and clears the failure flag. `Fugu::Imsg::close`
  needs it.
- Write `lib/Protocol/Imsg.pod`. The first paragraph states three limits: the
  header is native-endian and the format never crosses a host; the module frames
  without descriptor passing, because `FD_MARK` is masked off and never set; and
  `encode` reads `$$` per call, while native imsg seeds the pid once per buffer,
  so a forked child diverges.

### 4.2 Rewrite Fugu::Imsg as the transport

- `Fugu::Imsg` keeps `new(fh =>)`, `send`, `recv`, `close`, and `is_dead`, with
  the same return values and the same `$!` values.
- It holds one `Protocol::Imsg` object. `send` checks the dead flag and sets
  `EPIPE` **first**, then calls `encode`, then does the write loop and the
  `SIGPIPE` guard. The order matters: today a dead connection reports `EPIPE`
  even for an oversized payload, and `Fugu::Control::Client::request` prints
  that `$!` to the operator. Reversed, "the daemon closed the connection"
  becomes "Message too long".
- `recv` calls `next_message`, then polls with `IO::Select`, reads with
  `sysread`, and feeds `append`. A framing failure marks the transport dead.
- `close` calls `reset` on the codec. Without it a closed connection can still
  hand out a frame that arrived before the close, because `recv` extracts before
  it checks the dead flag.
- Re-export the constant:
  `use constant MAX_PAYLOAD => Protocol::Imsg::MAX_PAYLOAD;`.
  `lib/Fugu/Control.pm:307` reads `FuguLib::Imsg::MAX_PAYLOAD` as a bareword, so
  the constant leaving this module is a compile-time abort, not a runtime error.
  `t/fugu/control.t:145` calls it as a function.
- Keep the `{fh}` hash key. `Fugu::Control` and the tests reach into it.

### 4.3 Update the manuals

- Rewrite `man/fugu/Imsg.3p` for the smaller module. The framing rules move to
  the pod; the page documents the socket, the timeout behavior, and the errors.
  It keeps `MAX_PAYLOAD`, which the module still exports.
- Do not add an `.Xr` link to the codec. A sidecar `.pod` is not a 3p page, so
  `.Xr` would point at a page that does not exist. Name `Protocol::Imsg` in the
  SEE ALSO text, and point at `spec/MDNS-Imsg.md`.
- `web/mkindex.sh:150` groups `lib/Protocol/` under the heading "Protocol::HAP
  modules". That heading is now wrong. Rename it, or split the group.

### 4.4 Split the tests

`t/fugu/imsg.t` holds ten subtests. Each one has a destination, and three of
them split rather than move.

| Subtest                                     | Destination                                                                  |
| ------------------------------------------- | ---------------------------------------------------------------------------- |
| round-trip over a socketpair                | transport                                                                    |
| oversized payload is refused, not truncated | both: the bound to the codec, the 16368-byte round trip to the transport     |
| truncated header then EOF returns undef     | transport                                                                    |
| two messages in one read                    | codec, and keep a transport case                                             |
| write after peer close returns undef        | transport; it proves the `SIGPIPE` guard                                     |
| recv timeout returns undef without data     | transport; this is the positive-timeout deadline path                        |
| a zero timeout takes what arrived           | transport                                                                    |
| invalid length poisons the connection       | both: the `EBADMSG` to the codec, the `is_dead` propagation to the transport |
| the header carries peerid and pid           | codec                                                                        |
| close ends the connection for both sides    | transport                                                                    |

- The propagation case is the only new seam this phase creates, so it must have
  a transport test: inject an invalid `len` over a socketpair, assert `is_dead`,
  and assert that a second `recv` returns without blocking. Without it, an
  implementation that forgets `$self->{dead} = 1` passes the suite, and
  `Fugu::Control` spins on a readable but unusable socket forever.
- The zero-timeout subtest builds its split message with `_encode_header`. It
  becomes `Protocol::Imsg->new->encode(...)`, so `t/fugu/imsg.t` gains a codec
  dependency. Name that in the file header.
- `t/conformance/mdns-imsg.t` keeps its file name and its citations. Sections 1
  and 2 and the two accumulation cases of section 4 drive the codec. Two cases
  cannot: `[MDNS-Imsg §2] invalid len drops the connection` and
  `[MDNS-Imsg §4] EOF mid-message is an error` are transport predicates, because
  a codec with `append` and `next_message` has no concept of EOF. They keep
  their socketpair against `Fugu::Imsg`.
- `t/conformance/mdns-control.t`, `t/fugu/control.t`, `t/fugu/mdns.t`, and
  `t/openhap/integration/control.t` use the transport. Only the `MAX_PAYLOAD`
  call site in `t/fugu/control.t` changes.

### 4.5 Extend the boundary test

- `t/protocol/boundary.t` direction two matches `^(?:Protocol::HAP|App)\b` after
  phase 2. Widen it to reject any `^Protocol\b` import that is not on an
  allowlist, and seed the allowlist with `Protocol::Imsg`.
- Direction one already scans all of `lib/Protocol/`, so it covers the new
  module without a change.
- Prove the new rule with a planted `use Protocol::Something;` in a `Fugu::`
  module, and confirm that `use Protocol::Imsg;` passes. A planted
  `use Protocol::HAP;` proves nothing: direction two already rejects it.

### 4.6 Confirm the build

- `Makefile`: `install` and `package` copy `lib/Protocol/*.pm` and
  `lib/Protocol/*.pod` with a glob, so `Protocol/Imsg.pm` and `Imsg.pod` ship
  without a change. Confirm this with an install into an empty directory.
- `t/fugu/coreperl.t` loads each `Fugu::` module with the core paths plus
  `lib/`. `Fugu::Imsg` now requires `Protocol::Imsg`, which is under `lib/` and
  uses core Perl only, so the test still passes. Run it and confirm.
- `t/web/site.t`: the page expectations gain the `Protocol::Imsg` sidecar.

### 4.7 Update the documentation

- Root `CLAUDE.md`: the `lib/Protocol/` row in Layout describes the
  `Protocol::HAP` library. It now holds two libraries. State that `Protocol::`
  is the sans-IO tier.
- `t/CLAUDE.md`: the `t/protocol/` tier row says "the Protocol::HAP library".
- `TODO.md`: record that a `Protocol-Imsg` distribution needs descriptor passing
  or an explicit statement of the subset, and that the native-endian header
  makes the name a compromise.

## Deliverables

- `lib/Protocol/Imsg.pm` and `lib/Protocol/Imsg.pod`.
- A smaller `lib/Fugu/Imsg.pm` and a rewritten `man/fugu/Imsg.3p`.
- `t/protocol/imsg.t`, a smaller `t/fugu/imsg.t`, a retargeted
  `t/conformance/mdns-imsg.t`, and a widened `t/protocol/boundary.t`.
- Updated `web/mkindex.sh`, root `CLAUDE.md`, `t/CLAUDE.md`, `TODO.md`, and
  `t/web/site.t`.

## Acceptance criteria

- `make check` passes, and so do `make prettier` and `make web`.
- `grep -n 'syswrite\|sysread\|IO::Select\|CORE::close' lib/Protocol/Imsg.pm`
  finds nothing.
- The subtest count of `t/protocol/imsg.t` plus `t/fugu/imsg.t` is at least the
  ten that `t/fugu/imsg.t` holds today, and the table in task 4.4 accounts for
  each one.
- `t/protocol/boundary.t` fails on a planted `use Protocol::Something;` inside
  `lib/Fugu/`, and passes with `use Protocol::Imsg;`.
- `make spec-coverage` reports no stale citations, and `spec/MDNS-Imsg.md` stays
  at 4 of 5 sections. Section 5 is uncovered today, and it stays uncovered: a
  subtest that only states what the codec omits asserts nothing, and
  `t/CLAUDE.md` forbids a citation for a section that a test merely mentions.
- `make integration` passes: the control socket and the mdnsd client both use
  the rewritten transport.
- No caller outside `lib/Fugu/Imsg.pm`, `t/fugu/imsg.t`, `t/fugu/control.t`, and
  `t/conformance/mdns-imsg.t` changes in this phase.
