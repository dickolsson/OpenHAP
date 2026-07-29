# mdnsd Control Protocol: Messages and Semantics

The control protocol a client speaks to `mdnsd(8)` over its local socket:
message types, payload ABIs, the group publish state machine, and the browse,
resolve and lookup shapes. Framing is specified in [MDNS-Imsg.md](MDNS-Imsg.md);
provenance and upstream versions are in [MDNS.md](MDNS.md). File and line
citations refer to the openmdns `0.7` sources the OpenBSD 7.8 port builds;
`mdnsl.c` lives under `mdnsctl/` in that tag (it moved to `libmdns/` upstream
later, unchanged).

---

## 1. Control Socket

- Path: `/var/run/mdnsd.sock` (`MDNSD_SOCKET`, `mdnsd/mdns.h:37`).
- Type: `AF_UNIX`, `SOCK_STREAM` (`mdnsd/control.c:485`).
- Permissions: created with a umask that blocks other-access, then `chmod` 0660
  (`mdnsd/control.c:501-515`). The owner and group are the daemon's; the stock
  rc script runs mdnsd as root, so the socket is root:wheel and a client needs
  an effective uid of 0 or wheel group membership to connect.
- The socket exists only while mdnsd runs: it is unlinked at bind time and on
  cleanup (`mdnsd/control.c:494`, `:540-543`). A client must treat a missing or
  unconnectable socket as "mdnsd not running", a normal condition.
- The listen backlog is 5 (`mdnsd/control.c:40`).

## 2. Message Types

The `imsg_type` enum (`mdnsd/mdns.h:39-58`). Values are positional: the wire
value is the ordinal. Direction is client→daemon (C→D) or daemon→client (D→C).

| value | name                            | direction | payload                      |
| ----- | ------------------------------- | --------- | ---------------------------- |
| 0     | `IMSG_NONE`                     | —         | unused                       |
| 1     | `IMSG_CTL_END`                  | —         | unused by the 0.7 daemon     |
| 2     | `IMSG_CTL_LOOKUP`               | both      | `struct rrset` / `struct rr` |
| 3     | `IMSG_CTL_LOOKUP_FAILURE`       | D→C       | `struct rrset`               |
| 4     | `IMSG_CTL_BROWSE_ADD`           | both      | `struct rrset` / `struct rr` |
| 5     | `IMSG_CTL_BROWSE_DEL`           | both      | `struct rrset` / `struct rr` |
| 6     | `IMSG_CTL_RESOLVE`              | both      | name / `struct mdns_service` |
| 7     | `IMSG_CTL_RESOLVE_FAILURE`      | D→C       | name                         |
| 8     | `IMSG_CTL_GROUP_ADD`            | C→D       | group name (§3.1)            |
| 9     | `IMSG_CTL_GROUP_RESET`          | C→D       | group name (§3.1)            |
| 10    | `IMSG_CTL_GROUP_ADD_SERVICE`    | C→D       | `struct mdns_service` (§4)   |
| 11    | `IMSG_CTL_GROUP_COMMIT`         | C→D       | group name (§3.1)            |
| 12    | `IMSG_CTL_GROUP_ERR_COLLISION`  | D→C       | group name (§3.1)            |
| 13    | `IMSG_CTL_GROUP_ERR_NOT_FOUND`  | D→C       | group name; never sent (§9)  |
| 14    | `IMSG_CTL_GROUP_ERR_DOUBLE_ADD` | D→C       | group name; never sent (§9)  |
| 15    | `IMSG_CTL_GROUP_PROBING`        | D→C       | group name (§3.1)            |
| 16    | `IMSG_CTL_GROUP_ANNOUNCING`     | D→C       | group name (§3.1)            |
| 17    | `IMSG_CTL_GROUP_PUBLISHED`      | D→C       | group name (§3.1)            |

## 3. Request Payloads

The daemon validates every request payload by **exact size**
(`imsg->hdr.len - IMSG_HEADER_SIZE != sizeof(...)`) and silently ignores a
message whose payload size mismatches, logging a warning on its side only
(`mdnsd/control.c:341-344`, `:368-371`, `:400-403`, `:431-434`). A client that
miscomputes a payload size gets no error reply — the request just never
happened.

### 3.1 Group Name Messages

`IMSG_CTL_GROUP_ADD`, `GROUP_RESET`, `GROUP_COMMIT` and every group reply carry
the same payload: a `char[MAXHOSTNAMELEN]` — exactly 256 bytes, the group name
NUL-terminated and NUL-padded to the full width (`mdnsctl/mdnsl.c:235-248`
zeroes the buffer and `strlcpy`s into it; `mdnsd/control.c:346-347`
re-terminates defensively). The usable name length is therefore 255 bytes;
`strlcpy` truncation is rejected client-side (`mdnsctl/mdnsl.c:240-242`).

### 3.2 IMSG_CTL_GROUP_ADD_SERVICE

Payload: one `struct mdns_service`, exactly 864 bytes on LP64 (§4). Semantics on
receipt (`mdnsd/control.c:362-392`):

- An empty `target` is replaced with the daemon's own hostname — the short host
  name plus `.local` (`mdnsd/control.c:375-377`, `fetchmyname` at
  `mdnsd/mdnsd.c:394-405`).
- The group is looked up under the **service's** `name` field, and must exist
  and still be in state `PG_STA_NEW` (added on this connection, not yet
  committed); otherwise the message is dropped with a warning
  (`mdnsd/control.c:379-385`). See §7.
- The service expands to PTR, SRV and TXT records named
  `<name>._<app>._<proto>.local` (`mdnsd/mdns.c:733-743`) — the daemon adds the
  leading underscores, so `app` and `proto` are sent **without** them: `hap`,
  not `_hap`. `mdnsctl` passes its command-line arguments through verbatim
  (`mdnsctl/parser.c:280-287`).
- `proto` must be the literal string `tcp` or `udp` (`mdnsctl/mdnsl.c:301-302`).
- An `addr` of `INADDR_ANY` (zeros) advertises the interface address; this is
  what `mdnsctl publish` sends (`mdnsctl/mdnsctl.c:118-126` passes NULL,
  `mdnsctl/mdnsl.c:295-319` leaves the field zeroed).
- `priority` and `weight` default to 0 the same way.

## 4. struct mdns_service ABI

`struct mdns_service` (`mdnsd/mdns.h:89-100`) goes on the wire as its in-memory
representation — raw `memcpy` on both sides (`mdnsctl/mdnsl.c:272-274`,
`mdnsd/control.c:372`). The layout below is LP64 (`MAXLABELLEN` 64,
`MAXPROTOLEN` 4, `MAXHOSTNAMELEN` 256, `MAXCHARSTR` = `MAXHOSTNAMELEN`),
verified with a compiled `offsetof`/`sizeof` probe of the 0.7 declaration; the
two-pointer `LIST_ENTRY` and the 864-byte total are LP64-specific and do not
hold on a 32-bit architecture.

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

Total size: 864 bytes. Encoding rules:

- `entry` is mdnsd's own list linkage; the client sends it zeroed
  (`mdns_service_init` starts from `bzero`, `mdnsctl/mdnsl.c:295-299`) and the
  daemon overwrites it on receipt. The internal padding at 858 is likewise zero
  from the same `bzero`.
- Every `char[]` field is NUL-terminated and NUL-padded; over-length input is a
  client-side error, not a truncation (`strlcpy` checks throughout
  `mdns_service_init`, `mdnsctl/mdnsl.c:295-319`). Usable lengths: `app` 63,
  `proto` 3, `name` and `target` and `txt` 255.
- `priority`, `weight`, `port` and `addr` are native-endian, like the imsg
  header ([MDNS-Imsg.md](MDNS-Imsg.md) §1).

## 5. TXT Record Encoding

The `txt` field is a single string. When mdnsd serializes the TXT record onto
the mDNS wire it splits that string on `.` into DNS character-strings —
`serialize_dname` with dot-splitting is used for the TXT rdata
(`mdnsd/packet.c:1364-1376`, `:1282-1330`). Consequences:

- A TXT record with several key=value pairs is encoded as one string with `.`
  between the pairs: `k1=v1.k2=v2`.
- There is **no escape mechanism**: a `.` inside a value always splits. This is
  why OpenHAP advertises `pv=1` rather than `pv=1.1` ([HAP-mDNS.md](HAP-mDNS.md)
  §3.5 has the HomeKit-side context).
- Each split segment must fit a DNS character-string: 1-byte length prefix, so
  255 bytes max per segment; the whole `txt` field is capped at 255 usable bytes
  anyway (§4).
- Pair ordering in the advertisement is exactly the ordering in the string; a
  client that wants a deterministic advertisement must order the pairs
  deterministically itself.

## 6. The Group Publish Sequence

A client publishes by sending, on one connection (`mdnsctl/mdnsctl.c:117-127`):

1. `IMSG_CTL_GROUP_ADD` with the group name (§3.1) — creates the group, owned by
   this connection (`mdnsd/control.c:337-359`).
2. `IMSG_CTL_GROUP_ADD_SERVICE` with the `struct mdns_service` (§3.2, §4).
   Repeatable for multiple services in one group.
3. `IMSG_CTL_GROUP_COMMIT` with the group name — moves the group to
   `PG_STA_COMMITED` and starts its entries' state machines
   (`mdnsd/control.c:423-476`).

**The advertisement's lifetime is the connection.** When the control connection
closes — deliberately, or because the client died — mdnsd kills every group
belonging to it and sends goodbye packets (`mdnsd/control.c:604-632`,
`pg_kill`). Withdrawal _is_ closing the socket; there is no unpublish message.

### 6.1 State Machine and Replies

After a commit, each group entry runs UNPUBLISHED → PROBING → ANNOUNCING →
PUBLISHED (`pge_fsm`, `mdnsd/mdns.c:820-953`). The daemon notifies the owning
connection at each transition with a group-name payload (§3.1):

- `IMSG_CTL_GROUP_PROBING` when the first probe is sent
  (`mdnsd/mdns.c:862-866`).
- `IMSG_CTL_GROUP_ANNOUNCING` when the first announcement is sent
  (`mdnsd/mdns.c:903-906`).
- `IMSG_CTL_GROUP_PUBLISHED` when **every** entry of the group is published
  (`mdnsd/mdns.c:945-947`).
- `IMSG_CTL_GROUP_ERR_COLLISION` at any point a conflict is detected; the group
  is killed (`mdnsd/mdns.c:1218-1228`, `mdnsd/control.c:460-466`). Terminal.

`PROBING` and `ANNOUNCING` are progress reports, not terminal; a client waits
for `PUBLISHED` or an error.

### 6.2 Timing

Derived from the constants and the FSM, not yet measured against a live daemon.
The commit schedules the first probe after a random delay of up to 250 ms
(`RANDOM_PROBETIME`, `mdnsd/mdnsd.h:49`, `mdnsd/control.c:470-475`). Three
probes go out 250 ms apart (`INTERVAL_PROBETIME`, `mdnsd/mdnsd.h:48`);
announcements follow at 1 s and then 2 s spacing, and the third announcement
reaches PUBLISHED (`mdnsd/mdns.c:858-947`). End to end, `PUBLISHED` arrives
roughly **4 to 4.5 seconds after the commit**, and can be delayed a further
second or more while the daemon's own address records finish announcing
(`mdnsd/mdns.c:842-856`). A client timeout that means "mdnsd is broken" must
comfortably exceed this; ten seconds is a sound default.

## 7. Group Name and Instance Name

The group name and the service instance name are the same string, enforced
independently at both ends:

- Client side: `mdns_group_add_service` fails unless `group == ms->name`
  (`strcmp`, `mdnsctl/mdnsl.c:270-271`).
- Daemon side: `control_group_add_service` looks the group up under `ms->name`,
  not under any separate group argument (`mdnsd/control.c:380`), so a service
  added under a differently-named group lands in state "invalid group" and is
  dropped.

A client API therefore must not expose group and instance name as independent
parameters; the unusable combination should be inexpressible.

## 8. TXT Replacement and IMSG_CTL_GROUP_RESET

**Same-socket TXT replacement via `GROUP_RESET` does not work in the 0.7 port.**
`control_group_reset` looks the group up with `pg_get(0, msg, NULL)`
(`mdnsd/control.c:408`), but `pg_get` matches on `pg->c == c`
(`mdnsd/mdns.c:1006-1012`) — and a controller-created group has a non-NULL
owner. The lookup can never find it; the reset is logged as "group not found" (a
debug line on the daemon side only) and nothing happens. This is derived from
source, not measured. The downstream consequences for a client that assumed
reset worked:

- The group stays `PG_STA_COMMITED`, so a following `GROUP_ADD_SERVICE` is
  rejected (§3.2) — silently, from the client's perspective (§3).
- A following `GROUP_COMMIT` finds the old group, restarts its entries' state
  machines, and replies with the full PROBING/ANNOUNCING/PUBLISHED sequence —
  for the **old** records. The reply sequence is indistinguishable from a
  successful update.

To replace a TXT record, a client must close the control connection (withdrawing
the group, §6) and republish on a fresh connection. This is also the only
mechanism `mdnsctl` supports. A reconnect requires the `unix` pledge(2) promise;
an already-connected socket does not.

## 9. Reply and Error Semantics

- `IMSG_CTL_GROUP_ERR_COLLISION` — another host (or a stale record) owns a name
  this group probes for, or the collision was detected at commit time after an
  add-service failure (`mdnsd/control.c:444-453`, `:460-466`;
  `mdnsd/mdns.c:1218-1228`). The daemon kills the group; the client's only
  recovery is to rename and republish.
- `IMSG_CTL_GROUP_ERR_NOT_FOUND` — defined, but unreachable in the 0.7 daemon:
  the only code path that would send it first passes the NULL group pointer to
  `control_notify_pg`, which dereferences it (`mdnsd/control.c:454-457`,
  `:795-807`). See the hazard below.
- `IMSG_CTL_GROUP_ERR_DOUBLE_ADD` — defined and handled by the client library
  (`mdnsctl/mdnsl.c:373`, `:585-587`) but never sent by the 0.7 daemon: a
  duplicate `GROUP_ADD` on the same connection is silently ignored instead
  (`mdnsd/control.c:348-353`). A robust client still treats any `ERR_*` type as
  terminal failure.
- Malformed requests (wrong payload size) are dropped without any reply (§3).
  The only client-observable failure signals are an `ERR_*` reply, the absence
  of progress replies, and EOF.

**Hazard — never commit a group that was not added on this connection.**
`control_group_commit` for a name with no group at all reaches
`control_notify_pg(c, NULL, IMSG_CTL_GROUP_ERR_NOT_FOUND)`, which dereferences
the NULL `pg` (`mdnsd/control.c:439-457`, `:795-807`) and crashes mdnsd — taking
mDNS down for the whole host. A client must sequence ADD before COMMIT on the
same connection, unconditionally. (Derived from source; deliberately not
measured against a shared daemon.)

## 10. Worked Example: A Publish Conversation

The full conversation for:

```
mdnsctl publish "OpenHAP Bridge" hap tcp 51827 "c#=1.sf=1"
```

Derived byte-exactly from the encoders cited in §3-§4 and
[MDNS-Imsg.md](MDNS-Imsg.md) §1-§3; it has not yet been re-captured with
`ktrace(1)` against a live mdnsd. All integers are little-endian (the native
order on every supported target). `PPPP` marks the four sender-specific pid
bytes ([MDNS-Imsg.md](MDNS-Imsg.md) §3): the client's pid in messages 1-3,
mdnsd's pid in the replies. Zero runs are elided with `..`; every unlisted byte
is `00`.

Message 1 — `IMSG_CTL_GROUP_ADD`, 272 bytes total:

```
offset  bytes                                boundary
0       08 00 00 00                          type = 8
4       10 01 00 00                          len = 272 (16 + 256)
8       00 00 00 00                          peerid = 0
12      PP PP PP PP                          pid = sender's
16      4f 70 65 6e 48 41 50 20 42 72 69     "OpenHAP Bridge"
        64 67 65
30      00 .. 00                             NUL padding to offset 271
```

Message 2 — `IMSG_CTL_GROUP_ADD_SERVICE`, 880 bytes total:

```
offset  bytes                                boundary
0       0a 00 00 00                          type = 10
4       70 03 00 00                          len = 880 (16 + 864)
8       00 00 00 00                          peerid = 0
12      PP PP PP PP                          pid = sender's
16      00 .. 00                             entry, 16 zero bytes
32      68 61 70                             app = "hap"
35      00 .. 00                             NUL padding to offset 95
96      74 63 70 00                          proto = "tcp"
100     4f 70 65 6e 48 41 50 20 42 72 69     name = "OpenHAP Bridge"
        64 67 65
114     00 .. 00                             NUL padding to offset 355
356     00 .. 00                             target, 256 zero bytes
612     00 00                                priority = 0
614     00 00                                weight = 0
616     73 ca                                port = 51827
618     63 23 3d 31 2e 73 66 3d 31           txt = "c#=1.sf=1"
627     00 .. 00                             NUL padding to offset 873
874     00 00                                struct padding
876     00 00 00 00                          addr = INADDR_ANY
```

(Payload field offsets are §4's offsets plus the 16-byte header.)

Message 3 — `IMSG_CTL_GROUP_COMMIT`, 272 bytes total: identical to message 1
except `type` = `0b 00 00 00` (11).

Replies — three messages from mdnsd, each 272 bytes, spaced per §6.2: identical
to message 1 except `type` = `0f 00 00 00` (15, PROBING), then `10 00 00 00`
(16, ANNOUNCING), then `11 00 00 00` (17, PUBLISHED), and `PPPP` = mdnsd's pid.
The connection then stays open for the lifetime of the advertisement (§6).

## 11. Browse, Resolve and Lookup

Specified for completeness — they share the enum (§2) and the framing — but
OpenHAP implements only publish. The `struct rr` reply payload used by browse
and lookup is mdnsd's internal record structure (`mdnsd/mdnsd.h:106-131`), a
much larger and more volatile ABI than `struct mdns_service`; implementing
against it needs the same measure-first discipline as §4.

### 11.1 Browse

`IMSG_CTL_BROWSE_ADD` with a `struct rrset` payload — `char[256]` dname,
`u_int16_t type` (must be `T_PTR`), `u_int16_t class` (must be `C_IN`), plus the
leading 16-byte `LIST_ENTRY` (`mdnsd/mdnsd.h:81-86`, `mdnsd/control.c:137-160`)
— subscribes this connection to service up/down events for e.g.
`_hap._tcp.local`. The daemon replies with `IMSG_CTL_BROWSE_ADD`/`BROWSE_DEL`
messages carrying a `struct rr` as services come and go. `IMSG_CTL_BROWSE_DEL`
with the same `rrset` payload unsubscribes (`mdnsd/control.c:208-242`).

### 11.2 Resolve

`IMSG_CTL_RESOLVE` with a `char[MAXHOSTNAMELEN]` payload naming a service
instance (`<name>._<app>._<proto>.local`) asks the daemon to resolve its SRV,
TXT and address records (`mdnsd/control.c:244-334`). The daemon replies
`IMSG_CTL_RESOLVE` with a `struct mdns_service` payload (§4) on success — the
one place that struct flows daemon→client (`mdnsd/control.c:751-793`) — or
`IMSG_CTL_RESOLVE_FAILURE` with the name.

### 11.3 Lookup

`IMSG_CTL_LOOKUP` with a `struct rrset` payload (type `T_A`, `T_HINFO`, `T_PTR`,
`T_SRV` or `T_TXT`; class `C_IN`) performs a one-shot query
(`mdnsd/control.c:56-134`). The daemon replies `IMSG_CTL_LOOKUP` with a
`struct rr`, or `IMSG_CTL_LOOKUP_FAILURE` with the `rrset`, when the query times
out.
