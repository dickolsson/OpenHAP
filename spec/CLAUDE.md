# spec/

Applies when working on files under `spec/`.

## Purpose

`spec/*.md` are the curated protocol references OpenHAP implements against, and
the normative source the conformance tier cites:

- `HAP.md` — index and overview; entry point into the `HAP-*.md` topic files
- `HAP-*.md` — HAP topic files: TLV8, pairing, encryption, HTTP, mDNS, services,
  characteristics, categories
- `MQTT.md` — index and overview; entry point into the `MQTT-*.md` topic files
- `MQTT-*.md` — Tasmota MQTT topic files: transport, device control, state
  reporting, sensors
- `MDNS.md` — index and overview; entry point into the `MDNS-*.md` topic files
- `MDNS-*.md` — OpenBSD mdnsd control protocol topic files: imsg framing, the
  control socket protocol OpenHAP publishes mDNS services through
- `IMPLEMENTATIONS.md` — practical patterns from the reference implementations

Scope is IP transport, pairing, encryption, services, characteristics, events,
and the Tasmota MQTT surface OpenHAP bridges. Bluetooth LE, Thread, cameras,
HomeKit Secure Video, and Matter are out of scope.

## Writing changes

These are hand-maintained documents. Edit them in place — deepen a section, fix
an error, add a missing case — and keep every claim traceable: cite the upstream
source file (and line, where it helps) a value or behavior comes from, as the
surrounding text does. Local clones of those upstream repositories, if you keep
any, belong in the gitignored `external/`.

Structure is load-bearing, not cosmetic:

- Numbered `##`/`###` headings are the citation anchors. `make spec-coverage`
  parses them and fails on any test citation pointing at a section that no
  longer exists, so renumbering or resequencing sections breaks tests in
  `t/conformance/` — update the citations in the same change.
- One normative topic file maps to one conformance test file (`spec/HAP-TLV8.md`
  ↔ `t/conformance/hap-tlv8.t`); adding a topic file means adding its test file.
  See `t/CLAUDE.md`.
- Tables are catalogs the tests loop over; unnumbered rows are cited as
  `§<section>/<row>`, so row labels are anchors too.
- Wire examples and known-answer vectors are replayed byte-exactly by tests.
  Correct them only against a source, never to match the code.
