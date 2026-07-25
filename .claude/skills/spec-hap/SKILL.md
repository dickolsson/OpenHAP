---
name: spec-hap
description:
  Extract the HAP protocol specification from the sources in external/ into
  spec/HAP.md plus topic files spec/HAP-*.md. Use when asked to generate,
  regenerate, or update the HAP spec documents. Requires external/ to be
  populated.
---

# Extract HAP Protocol Specification

## Objective

Produce `spec/HAP.md` — a protocol reference that documents _what_ HAP requires,
independent of any particular implementation. This should be the authoritative
reference for building a HAP server.

## Preconditions

If `external/` is absent or empty, run the `fetch-external` skill first.

If `spec/IMPLEMENTATIONS.md` exists, use it to identify what protocol details
matter in practice.

## Source Strategy

Extract specification details from multiple sources, cross-referencing to ensure
accuracy — the source map in the `fetch-external` skill lists what each source
under `external/` is best for. When sources agree, that's the specification.
When they differ, document the variation.

When extracting specific values (UUIDs, constants, parameters), cite the source
file and line number (e.g., "from `HAPCharacteristic.h:142`") to enable later
verification and updates.

## What to Document

**Protocol Constants** Extract actual values — UUIDs, type codes, status codes,
format identifiers. These should be copy-pasteable into code.

**Data Formats** Document exact encoding rules for TLV8, characteristic values,
HTTP bodies. Include byte-level details where relevant. Provide hex dump
examples showing actual wire format for TLV8 messages and encrypted frames.

**Protocol Flows** Document the message exchange for pair setup (M1-M6), pair
verify (M1-M4), and session establishment. Include what each message contains.

**mDNS/Bonjour** Service type, TXT record fields with their meanings and valid
values.

**HTTP Endpoints** Complete list of endpoints with methods, request formats,
response formats.

**Services and Characteristics** Exhaustive tables of all services with their
UUIDs and required/optional characteristics. Exhaustive tables of all
characteristics with UUIDs, formats, permissions, and constraints. Do not
truncate these tables — completeness is more important than brevity.

**Cryptographic Details** Algorithms, key sizes, HKDF parameters (exact salt and
info strings).

**Session Encryption** How HAP encrypts HTTP after pair verify — frame format,
nonce handling, counter management, maximum frame sizes.

**Error Handling** Document error responses for each endpoint, TLV error codes,
HTTP status codes, and recovery procedures.

**Characteristic Value Encoding** How different data types (bool, int, float,
string, data, TLV8) are encoded in JSON responses and event notifications.

## Scope Boundaries

**Include:** IP transport, pairing, encryption, services, characteristics,
events.

**Exclude:** Bluetooth LE, Thread, cameras, HomeKit Secure Video, Matter.

## Output Structure

Create the HAP protocol specification as **multiple focused files** in `spec/`
rather than one monolithic document. This avoids context limits and makes the
specification easier to navigate and maintain.

**Required:** Create `spec/HAP.md` as an index/overview that:

- Provides a glossary defining key terms (LTPK, aid, iid, pairing, session,
  controller, accessory, etc.)
- Gives a high-level protocol overview
- Links to the topic-specific files for detailed information
- Records provenance near the top: the extraction date and the commit of each
  source repository used (`git -C external/<name> rev-parse --short HEAD`), so
  staleness against upstream can be checked later

**Topic files:** Break out detailed content into separate `spec/HAP-*.md` files.
Let the natural structure of the content guide the split — for example, large
tables (services, characteristics) belong in their own files, as do detailed
protocol flows (pairing, encryption). Don't force a structure; let topics emerge
from what needs documenting.

Each topic file should be self-contained enough to be useful on its own, but can
cross-reference other files in the spec.

## Formatting Guidelines

Use:

- **Numbered sections** (1, 1.1, 1.1.1) within each file for easy
  cross-referencing
- Tables for structured data (services, characteristics, constants)
- Diagrams or step-by-step lists for protocol flows
- Exact values that can be used directly in implementations
- References to source files where details were extracted

Aim for depth over brevity — include edge cases, error conditions, and
implementation notes. When documenting protocol flows, show the complete message
structure at each step. When documenting data formats, include both the encoding
rules and worked examples.

The specification should enable someone to implement HAP without reading any
source code — but with pointers to where to look when more detail is needed.
