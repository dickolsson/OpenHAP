# HomeKit Accessory Protocol (HAP) Notes

This document provides a protocol-level reference for implementing a HAP server
over IP transport. It documents _what_ HAP requires, independent of any
particular implementation.

**Scope:** IP transport, pairing, encryption, services, characteristics, events.

**Excluded:** Bluetooth LE, Thread, cameras, HomeKit Secure Video, Matter.

---

## 1. Glossary

| Term               | Definition                                                                                                                                              |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Accessory**      | A physical or virtual HomeKit device. Each accessory has a unique `aid` (accessory ID) and contains one or more services.                               |
| **aid**            | Accessory ID. A positive integer uniquely identifying an accessory within a HAP server. The bridge itself is always `aid=1`.                            |
| **Bridge**         | A special accessory (`aid=1`) that aggregates multiple accessories under a single HAP server.                                                           |
| **Characteristic** | A typed value within a service representing a single property (e.g., On, Brightness). Has a unique `iid` within its accessory.                          |
| **Controller**     | A HomeKit client (iOS device, HomePod, Apple TV) that pairs with and controls accessories.                                                              |
| **HKDF**           | HMAC-based Key Derivation Function. HAP uses HKDF-SHA-512 for all key derivation.                                                                       |
| **iid**            | Instance ID. A positive integer uniquely identifying a service or characteristic within an accessory. IID 1 is always the AccessoryInformation service. |
| **LTPK**           | Long-Term Public Key. An Ed25519 public key used for persistent identity. Both controllers and accessories have LTPKs.                                  |
| **LTSK**           | Long-Term Secret Key. The Ed25519 private key corresponding to an LTPK.                                                                                 |
| **Pairing**        | The process of establishing trust between a controller and accessory using a setup code. Results in exchanging LTPKs.                                   |
| **Pair Setup**     | The initial pairing protocol (M1-M6) using SRP-6a to verify the setup code and exchange long-term public keys.                                          |
| **Pair Verify**    | The session establishment protocol (M1-M4) using X25519/Ed25519 to create an encrypted session between previously paired devices.                       |
| **Service**        | A logical grouping of characteristics representing a device function (e.g., LightBulb, Switch). Has a unique `iid` and a type UUID.                     |
| **Session**        | An encrypted HTTP connection between a controller and accessory, established after Pair Verify completes.                                               |
| **Setup Code**     | An 8-digit code in format `XXX-XX-XXX` used during Pair Setup. Also called PIN code.                                                                    |
| **Setup ID**       | A 4-character alphanumeric code used with the setup code to generate QR codes and NFC tags for pairing.                                                 |
| **SRP-6a**         | Secure Remote Password protocol variant used by HAP with SHA-512 instead of SHA-1, and a 3072-bit prime from RFC 5054.                                  |
| **TLV8**           | Type-Length-Value encoding with 8-bit length field. Used for pairing protocol messages and for characteristic values with format `tlv8`.                |
| **UUID**           | Universally Unique Identifier. HAP uses Apple's base UUID `XXXXXXXX-0000-1000-8000-0026BB765291` with a 32-bit short form prefix for standard types.    |

---

## 2. Protocol Overview

HAP operates as an HTTP/1.1 server with these phases:

1. **Discovery** — mDNS/Bonjour advertisement (`_hap._tcp`) announces the
   accessory on the local network with device metadata in TXT records.

2. **Pair Setup** — One-time initial pairing using an 8-digit setup code.
   Establishes long-term trust by exchanging Ed25519 public keys. See
   [HAP-Pairing.md](HAP-Pairing.md).

3. **Pair Verify** — Session establishment for paired controllers. Uses X25519
   ephemeral key exchange and Ed25519 signatures. See
   [HAP-Pairing.md](HAP-Pairing.md).

4. **Encrypted Session** — All subsequent HTTP traffic is encrypted with
   ChaCha20-Poly1305 using session keys from Pair Verify. See
   [HAP-Encryption.md](HAP-Encryption.md).

5. **Accessory Database** — Controllers query the accessory database to discover
   services and characteristics. See [HAP-HTTP.md](HAP-HTTP.md).

6. **Characteristic Operations** — Read, write, and subscribe to characteristic
   values. Events are pushed asynchronously. See [HAP-HTTP.md](HAP-HTTP.md).

---

## 3. Data Model

HAP models devices as a hierarchy:

```
Bridge/Accessory (aid)
  └── Service (iid, type UUID)
        └── Characteristic (iid, type UUID, value, permissions)
```

### 3.1 Accessory

- Has a unique `aid` (1-based integer)
- Contains one or more services
- Must include AccessoryInformation service (UUID `3E`) as the first service

### 3.2 Service

- Has a unique `iid` within its accessory
- Has a type UUID identifying the service type (e.g., `43` = LightBulb)
- Contains required and optional characteristics
- May link to other services (`linked`, an array of service instance IDs)
- May be marked as primary (`primary`) or hidden (`hidden`)

### 3.3 Characteristic

- Has a unique `iid` within its accessory
- Has a type UUID identifying the characteristic type (e.g., `25` = On)
- Has a format (bool, uint8, uint16, uint32, uint64, int, float, string, tlv8,
  data)
- Has permissions (pr, pw, ev, aa, tw, hd, wr)
- May have constraints (minValue, maxValue, minStep, maxLen, valid-values)

---

## 4. Topic Files

Detailed protocol information is organized into these files:

| File                                             | Content                                                              |
| ------------------------------------------------ | -------------------------------------------------------------------- |
| [HAP-TLV8.md](HAP-TLV8.md)                       | TLV8 encoding format, type codes, fragmentation                      |
| [HAP-Pairing.md](HAP-Pairing.md)                 | Pair Setup (M1-M6), Pair Verify (M1-M4), cryptographic parameters    |
| [HAP-Encryption.md](HAP-Encryption.md)           | Session encryption, frame format, HKDF parameters, nonce handling    |
| [HAP-HTTP.md](HAP-HTTP.md)                       | HTTP endpoints, request/response formats, status codes               |
| [HAP-mDNS.md](HAP-mDNS.md)                       | Service discovery, TXT record fields, status flags                   |
| [HAP-Services.md](HAP-Services.md)               | Complete service definitions with UUIDs and characteristics          |
| [HAP-Characteristics.md](HAP-Characteristics.md) | Complete characteristic definitions with UUIDs, formats, constraints |
| [HAP-Categories.md](HAP-Categories.md)           | Accessory category identifiers                                       |

---

## 5. UUID Format

HAP uses a base UUID with a 32-bit prefix for Apple-defined types:

```
Base UUID: XXXXXXXX-0000-1000-8000-0026BB765291
           ^^^^^^^^
           Short form (32 bits, big-endian hex)
```

**Examples:**

| Short Form | Full UUID                              | Type          |
| ---------- | -------------------------------------- | ------------- |
| `3E`       | `0000003E-0000-1000-8000-0026BB765291` | AccessoryInfo |
| `43`       | `00000043-0000-1000-8000-0026BB765291` | LightBulb     |
| `25`       | `00000025-0000-1000-8000-0026BB765291` | On            |

In JSON responses, UUIDs are typically encoded as the short form hex string
without leading zeros (e.g., `"type": "3E"`).

For custom/vendor UUIDs, use a different base UUID (not Apple's).

---

## 6. Protocol Version

```
HAP Protocol Version: 1.1
Version String: "01.01.00"
```

The protocol version is advertised in mDNS TXT records (`pv=1.1`) and reported
via the HAPProtocolInformation service.

---

## 7. References

**Source Files Used:**

- `external/HomeSpan/docs/ServiceList.md` — Service/characteristic tables
- `external/HomeSpan/docs/Categories.md` — Category identifiers
- `external/HomeSpan/docs/TLV8.md` — TLV8 encoding explanation
- `external/HAP-python/pyhap/resources/services.json` — Service definitions
- `external/HAP-python/pyhap/resources/characteristics.json` — Characteristic
  definitions
- `external/HAP-python/pyhap/const.py` — Protocol constants
- `external/HAP-NodeJS/src/lib/HAPServer.ts` — Status codes, HTTP handling
- `external/HAP-NodeJS/src/lib/Advertiser.ts` — mDNS advertisement
- `external/HAP-NodeJS/src/lib/util/hapCrypto.ts` — Encryption implementation
- `external/HAP-NodeJS/src/lib/util/tlv.ts` — TLV encoding
- `external/HAP-NodeJS/src/internal-types.ts` — TLV type codes
- `external/HomeKitADK/HAP/HAPPairing.h` — Pairing constants
- `external/HomeKitADK/HAP/HAPUUID.h` — UUID format
