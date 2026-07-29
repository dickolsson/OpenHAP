# mdnsd Control Protocol: imsg Framing

How messages are framed on the mdnsd control socket. mdnsd and its clients use
the base-system imsg facility from libutil; this file records the framing as
shipped in OpenBSD 7.8 (`/usr/include/imsg.h`, `src/lib/libutil/imsg.h` rev
1.24; `imsg.c` rev 1.42). Provenance and upstream versions are in
[MDNS.md](MDNS.md).

The 2024 imsg rework changed this header: `len` widened from `uint16_t` to
`uint32_t` and the separate `flags` field was removed. Both header layouts are
16 bytes, but the field set below is the reworked one — do not implement against
pre-7.6 descriptions of imsg.

---

## 1. Header Layout

`struct imsg_hdr` (`imsg.h:55-60`), 16 bytes, no padding:

| offset | field    | C type     | bytes |
| ------ | -------- | ---------- | ----- |
| 0      | `type`   | `uint32_t` | 4     |
| 4      | `len`    | `uint32_t` | 4     |
| 8      | `peerid` | `uint32_t` | 4     |
| 12     | `pid`    | `uint32_t` | 4     |

`IMSG_HEADER_SIZE` is `sizeof(struct imsg_hdr)` = 16 (`imsg.h:31`).

All fields are written in the sender's native byte order (`imsg.c:407-410`
writes the header with host-order `ibuf_set_h32`). Both ends of the control
socket are the same host, so the wire order is the host's — little-endian on
every platform this repository targets (OpenBSD aarch64 and amd64). There is no
byte-order negotiation and no network-order variant.

## 2. Length Semantics

- `len` counts the **whole message**: header plus payload (`imsg.c:403-411` —
  `imsg_close` stores `ibuf_size(msg)`, which includes the header that
  `imsg_create` already added).
- The most significant bit of `len` is reserved: `IMSG_FD_MARK` (`0x80000000U`,
  `imsg.c:35`) marks a message that carries a passed file descriptor. Receivers
  mask it off before using the length (`imsg.c:441`). The mdnsd control protocol
  never sets it (see §5).
- `MAX_IMSGSIZE` is 16384 (`imsg.h:32`), enforced against the whole message on
  both sides: `imsg_create` fails with `ERANGE` when
  `payload + IMSG_HEADER_SIZE` exceeds it (`imsg.c:362-372`), and the reader
  drops the connection when `len < IMSG_HEADER_SIZE` or `len > maxsize`
  (`imsg_parse_hdr`, `imsg.c:436-445`).
- The maximum **payload** is therefore `MAX_IMSGSIZE - IMSG_HEADER_SIZE` = 16368
  bytes. An encoder must refuse larger payloads rather than truncate.

## 3. peerid and pid

- `peerid` is free for the application. mdnsd clients send 0
  (`mdnsctl/mdnsl.c:472-476` — `ibuf_send_imsg` passes `peerid = 0`), and mdnsd
  does not read it.
- `pid` is **sender-specific**: `imsg_create` substitutes the sending process's
  pid when the caller passes 0 (`imsg.c:377-378`, `imsgbuf_init` at `imsg.c:46`
  seeds it from `getpid()`). mdnsd clients always pass 0, so the field carries
  the client's pid on requests and mdnsd's pid on replies. Nothing in the
  control protocol validates it — a captured conversation can only be replayed
  byte-exactly up to this field.

## 4. Message Boundaries and Partial Reads

imsg runs over a stream socket; message boundaries exist only in the framing. A
reader accumulates bytes until it holds 16 header bytes, masks `IMSG_FD_MARK`
off `len`, validates it (§2), then accumulates until `len` total bytes are
buffered; anything beyond `len` begins the next message (`imsg.c:426-455`,
`imsgbuf_read`/`imsg_parse_hdr`). Consequences an implementation must honor:

- A single `read(2)` may return a partial header, a partial payload, or several
  complete messages back to back; none of these is an error.
- EOF mid-message is a protocol error; EOF on a message boundary is a clean
  close.
- An invalid `len` is unrecoverable for the connection — native imsg drops it,
  and so must we.

## 5. File Descriptor Passing

imsg can pass file descriptors as `SCM_RIGHTS` ancillary data on the message
marked with `IMSG_FD_MARK` (`imsg.c:449-452`). The mdnsd control protocol does
not use this facility: no message in the `imsg_type` enum carries an fd, and
`mdnsctl/mdnsl.c` never sends one. OpenHAP's client deliberately omits fd
passing — receiving ancillary fds would require `recvmsg`/`sendmsg` rights that
map to the `sendfd`/`recvfd` pledge(2) promises, which `openhapd` does not hold.
