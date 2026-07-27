# Phase 1 — The mDNS protocol reference

Extract the mdnsd control protocol into `spec/` before writing a line of client
code, and teach the coverage tooling to see it. Independently shippable: it adds
a protocol reference and the citation support for it, with no behaviour change.

This phase exists because phase 2 implements a wire protocol against another
daemon's in-memory struct layout. Deriving that from a header while writing the
client would bury the assumptions in Perl comments. Extracting it first puts
them in the one place this repo already trusts for protocol facts.

## Tasks

### 1.1 Add openmdns to `external/`

`.claude/skills/fetch-external/SKILL.md` clones five reference sources; add a
sixth:

```sh
git clone --depth 1 https://github.com/haesbaert/mdnsd external/openmdns
```

- Add `external/openmdns/mdnsd/mdns.h` and `external/openmdns/libmdns/mdnsl.c`
  to the skill's "verify the key paths exist" list.
- Add a Source Map row: openmdns — mdnsd control protocol,
  `struct mdns_service`, the `imsg_type` enum — best for the mdnsd IPC protocol.
- Note in the skill that `haesbaert/mdnsd` is upstream but the OpenBSD
  `net/openmdns` port may carry patches, and **the installed port is
  authoritative for us**. `cynix/openmdns` is a maintained fork; if the port
  tracks it, clone that instead and say so in the provenance.

### 1.2 Measure the ABI on the installed port

Upstream source gives the field list; it does not give offsets, padding, or what
`mdnsctl` actually puts on the wire. Both measurements happen inside the OpenBSD
VM (`make integration`, or the `openhvf` skill for an interactive shell) and
their output is what the spec records:

1. Compile a short C program against the installed `/usr/local/include/mdns.h`
   printing `sizeof(struct mdns_service)` and `offsetof` for every field.
2. `ktrace -i mdnsctl publish ...` then `kdump`, to capture the `write(2)`
   payloads on the control socket. The first four messages are the conversation
   phase 2 replicates.

Capture 2 settles three things no header can: whether `app` carries `hap` or
`_hap` (`mdnsctl/parser.c` may normalise what `MDNS.pm:93` passes as `hap`),
what `mdnsctl` puts in `target`/`addr`, and what `priority`/`weight` default to.

Also record the OpenBSD version of `/usr/include/imsg.h` — imsg framing is base
system, not openmdns, and is not in `external/`. The installed header is the
authority for it.

Derived layout to check the measurement against (LP64; `MAXLABELLEN` 64,
`MAXPROTOLEN` 4, `MAXHOSTNAMELEN` 256, `MAXCHARSTR` = `MAXHOSTNAMELEN`):

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

864 bytes total. The `LIST_ENTRY` is mdnsd's own list linkage, two pointers
wide, and goes on the wire as zeros. If the measurement disagrees, the
measurement wins and the table in the spec is the measured one — this table is a
cross-check, not a source.

### 1.3 The `spec-mdns` skill

New `.claude/skills/spec-mdns/SKILL.md`, modelled on `spec-mqtt`: objective,
preconditions (`fetch-external` first), primary sources, what to document, scope
boundaries, output structure, formatting guidelines.

Points specific to this skill:

- Primary sources are `external/openmdns/mdnsd/mdns.h` (enum, structs, socket
  path), `external/openmdns/libmdns/mdnsl.c` (client sequences), and
  `external/openmdns/mdnsctl/` (what a real client sends).
- The ABI measurements from 1.2 are an input the skill cannot derive by reading
  code. The skill must say so, and say that regeneration without a fresh
  measurement carries the previous one forward with its provenance intact.
- Scope: the control-socket protocol only. Not the mDNS wire protocol on the
  network (RFC 6762/6763) — mdnsd owns that, and `spec/HAP-mDNS.md` already
  covers what HomeKit needs advertised.
- Provenance block near the top of `MDNS.md`, matching `MQTT.md`'s: extraction
  date, `git -C external/openmdns rev-parse --short HEAD`, the installed port
  version (`pkg_info -Q openmdns`), the OpenBSD release measured on, and the
  `/usr/include/imsg.h` version.

### 1.4 Write the spec files

Three files, per the design. **Numbered `##`/`###` headings throughout** — the
inventory regex in `scripts/spec-coverage:80` matches only `##` and `###` with a
leading number, so a `####` heading cannot be cited and a heading whose number
is missing is invisible. Anything a conformance test needs to cite must be `##`
or `###`.

- `spec/MDNS.md` — index and overview. Glossary (imsg, control socket, group,
  service, probing, announcing, collision), the publish flow end to end, links
  to the topic files, provenance. Unhyphenated, so `spec-coverage` treats it as
  an index and does not count its sections.
- `spec/MDNS-Imsg.md` — framing. Header field layout and byte order, `len`
  counting the header, `MAX_IMSGSIZE`, partial reads and message boundaries,
  `peerid`/`pid` semantics, and the fd-passing facility with an explicit note
  that we do not use it and why (it would need `sendfd`/`recvfd` in the pledge).
- `spec/MDNS-Control.md` — the control protocol. Socket path and permissions
  (root:wheel, hence the `wheel` requirement at `bin/openhapd:116`), the full
  `imsg_type` enum with its ordinal values, the group publish sequence, reply
  and error semantics, the `struct mdns_service` ABI as measured, TXT string
  encoding including the `.` delimiter and its no-escaping consequence, and
  field length limits. Specify browse/resolve/lookup message shapes too — they
  share the enum and framing, cost a paragraph each, and stop the file from
  looking like it describes the whole protocol when it describes a third of it.

Include a byte-exact worked example of a full publish conversation, taken from
the 1.2 capture. That example is what phase 2's conformance test replays.

### 1.5 Teach the tooling about the new family

- `scripts/spec-coverage:109` — extend the citation pattern from
  `(?:HAP|MQTT)[A-Za-z0-9-]*` to include `MDNS`. Without this, `[MDNS-Imsg §2]`
  never matches: the citation is not counted, and — worse — is not stale-checked
  either, so it silently rots when the spec is regenerated.
- `t/CLAUDE.md:58` documents that grep pattern; update it in lockstep, and
  mention the new topic ↔ test mapping in the conformance section.
- `spec/CLAUDE.md` — add the `MDNS.md` / `MDNS-*.md` bullet naming `spec-mdns`
  as the owning skill.
- `.claude/skills/fetch-external/SKILL.md` — the description line lists the
  sources it fetches and the skills that need it; add openmdns and `spec-mdns`.
- Check whether `.claude/skills/compliance-hap/SKILL.md` should learn about the
  new spec family. It audits against `spec/HAP*.md`; an mdnsd-transport audit is
  a separate concern and probably should not be folded in, but decide
  deliberately rather than by omission.

No `Makefile` change: `spec-coverage` globs `spec/*.md` and picks the new files
up on its own.

### 1.6 Verify the tooling actually sees them

`make spec-coverage` must list the two new topic files. Coverage will read 0/N
until phase 2 — that is correct and non-fatal (the script exits nonzero only on
stale citations), and it is what makes this phase shippable alone.

Prove the wiring rather than assuming it: add a temporary citation to a real
section, confirm it counts, then a citation to a nonexistent section, confirm
`make spec-coverage` exits nonzero with `STALE`. Remove both before committing.

## Deliverables

- `spec/MDNS.md`, `spec/MDNS-Imsg.md`, `spec/MDNS-Control.md`
- `.claude/skills/spec-mdns/SKILL.md`
- Changes to `.claude/skills/fetch-external/SKILL.md`, `scripts/spec-coverage`,
  `t/CLAUDE.md`, `spec/CLAUDE.md`

## Acceptance criteria

- The `struct mdns_service` layout in `spec/MDNS-Control.md` is the measured
  one, and the spec says which OpenBSD release and port version it was measured
  on.
- `spec/MDNS-Control.md` contains a byte-exact publish conversation captured
  from a real `mdnsctl`, sufficient for phase 2 to replay without re-deriving
  anything.
- Every section a conformance test will cite is a numbered `##` or `###`
  heading.
- `make spec-coverage` lists both topic files, reports 0 covered sections, and
  exits zero; a deliberately bogus citation makes it exit nonzero with `STALE`.
- `make prettier` clean. `make check` unaffected — no Perl and no tests change,
  and `scripts/spec-coverage` is not in `lint`'s file list, so run it directly.
- Regenerating with `spec-mdns` on a populated `external/` reproduces the files
  modulo the provenance block and the carried-forward measurements.
