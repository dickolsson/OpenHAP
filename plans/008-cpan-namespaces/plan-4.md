# Phase 4 — Protocol::Imsg splits out of Fugu::Imsg

`Fugu::Imsg` does two jobs. It frames and unframes imsg(3) messages, and it owns
a socket. The framing is a wire format that any program can reuse. The socket is
host policy. This phase separates them, and puts the codec in the namespace that
CPAN uses for sans-IO protocol codecs.

The phase depends on phase 1. The public API of the transport does not change,
so its callers change nothing.

## Tasks

### 4.1 Create Protocol::Imsg

- New `lib/Protocol/Imsg.pm`. It holds the constants, the header pack and
  unpack, and the message extraction. It performs no system call, and it opens
  no file.
- Move these from `Fugu::Imsg`: `HEADER_SIZE`, `HEADER_TEMPLATE`,
  `MAX_IMSGSIZE`, `MAX_PAYLOAD`, `FD_MARK`, `_encode_header`, `_decode_header`,
  and `_extract_message`. The spec citations move with the code.
- The public API is `new`, `encode`, `append`, `next_message`, and `is_failed`,
  as the design defines them. `_encode_header` and `_decode_header` stay
  private: the tests reach them through `encode` and `next_message`.
- `encode` returns undef with `$!` set to `EMSGSIZE` for an oversized payload.
  `next_message` returns undef with `$!` set to `EBADMSG` for an invalid length,
  and `is_failed` then reports 1 forever.
- `pid` defaults to `$$`. Document it as the one environment value that the
  codec reads.
- Write `lib/Protocol/Imsg.pod`. State in the first paragraph that the module
  implements the framing subset without descriptor passing: `FD_MARK` is masked
  off, never set. A reader must not expect `SCM_RIGHTS`.

### 4.2 Rewrite Fugu::Imsg as the transport

- `Fugu::Imsg` keeps `new(fh =>)`, `send`, `recv`, `close`, and `is_dead`. The
  behavior, the return values, and the `$!` values do not change.
- It holds one `Protocol::Imsg` object. `send` calls `encode`, then does the
  write loop and the `SIGPIPE` guard. `recv` calls `next_message`, then polls
  with `IO::Select` and reads with `sysread`, and feeds `append`.
- A framing failure in the codec marks the transport dead, as it does today.
- The read buffer lives in the codec. The transport keeps only the handle and
  the dead flag.

### 4.3 Update the manuals

- Rewrite `man/fugu/Imsg.3p` for the smaller module. The framing rules move to
  the pod; the page documents the socket, the timeout behavior, and the errors.
- Do not add an `.Xr` link to the codec. A sidecar `.pod` is not a 3p page, so
  `.Xr` would point at a page that does not exist. Name `Protocol::Imsg` in the
  SEE ALSO text, and point at `spec/MDNS-Imsg.md`.
- The documentation table in the root `CLAUDE.md` sends `Fugu::` modules to 3p
  pages and every other module to a sidecar. This split follows that rule, and
  no module gets both.

### 4.4 Split the tests

- New `t/protocol/imsg.t`. Move the byte-level subtests from `t/fugu/imsg.t`:
  the header encoding, the length bounds, the oversized payload, the invalid
  length, and the partial-message extraction. They drive `encode`, `append`, and
  `next_message` on plain strings, with no socketpair.
- `t/fugu/imsg.t` keeps the transport subtests: the socketpair round trip, the
  short read across calls, the timeout of 0, the clean EOF, and the dead
  connection.
- `t/conformance/mdns-imsg.t` keeps its file name and its citations. It loads
  `Protocol::Imsg` for the framing rules in sections 1 to 4. Section 5, on
  descriptor passing, states what the codec does not implement.
- `t/conformance/mdns-control.t`, `t/fugu/control.t`, `t/fugu/mdns.t`, and
  `t/openhap/integration/control.t` use the transport. They change nothing.

### 4.5 Extend the boundary test

- `t/protocol/boundary.t` gains direction three: `Fugu::` may use a `Protocol::`
  module on an allowlist, and that allowlist holds `Protocol::Imsg` only. Any
  other `Protocol::` import under `lib/Fugu/` fails the test, and
  `Protocol::HAP` fails it by name.
- Direction one already scans all of `lib/Protocol/`, so it covers the new
  module without a change.
- Prove the new failure mode once by hand before commit: plant a
  `use Protocol::HAP;` in a `Fugu::` module and watch the test fail.

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
  is the sans-IO tier, and that `Protocol::Imsg` is the imsg(3) codec.
- `t/CLAUDE.md`: the `t/protocol/` tier row says "the Protocol::HAP library".
- `TODO.md`: record that a `Protocol-Imsg` distribution would need descriptor
  passing, or an explicit statement of the subset, before a release.

## Deliverables

- `lib/Protocol/Imsg.pm` and `lib/Protocol/Imsg.pod`.
- A smaller `lib/Fugu/Imsg.pm` and a rewritten `man/fugu/Imsg.3p`.
- `t/protocol/imsg.t`, a smaller `t/fugu/imsg.t`, a retargeted
  `t/conformance/mdns-imsg.t`, and an extended `t/protocol/boundary.t`.
- Updated root `CLAUDE.md`, `t/CLAUDE.md`, `TODO.md`, and `t/web/site.t`.

## Acceptance criteria

- `make check` passes.
- `grep -rn 'syswrite\|sysread\|IO::Select\|CORE::close' lib/Protocol/Imsg.pm`
  finds nothing.
- `t/protocol/boundary.t` passes, and fails correctly on a planted
  `use Protocol::HAP;` inside `lib/Fugu/`.
- `make spec-coverage` reports no stale citations, and `spec/MDNS-Imsg.md` keeps
  full section coverage.
- `make integration` passes: the control socket and the mdnsd client both use
  the rewritten transport.
- The transport API is unchanged. No caller outside `lib/Fugu/Imsg.pm` and its
  tests changes in this phase.
