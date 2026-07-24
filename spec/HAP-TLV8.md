# HAP TLV8 Encoding

TLV8 (Type-Length-Value with 8-bit length) is the wire format used for HAP
pairing protocol messages.

---

## 1. Basic Structure

Each TLV8 record consists of:

```
+------+--------+------------------+
| Type | Length | Value (0-255 B)  |
+------+--------+------------------+
   1B      1B        0-255 B
```

- **Type**: 1 byte (0x00-0xFF) identifying the TLV meaning
- **Length**: 1 byte (0x00-0xFF) indicating value length
- **Value**: 0-255 bytes of data

---

## 2. Fragmentation

Values exceeding 255 bytes MUST be split across consecutive TLV records with the
same Type. The decoder concatenates values from sequential same-type records.

**Encoding long values:**

```
Value length: 500 bytes

Record 1: Type=X, Length=255, Value[0..254]
Record 2: Type=X, Length=245, Value[255..499]
```

**Decoding rule:** When encountering consecutive TLV records with the same Type,
concatenate their Values into a single logical value.

Every fragment except the last MUST be exactly 255 bytes; only the final
fragment may be shorter. Strict decoders depend on this: HAP-NodeJS's
`decodeWithLists` merges a record into the previous one only when the preceding
record has the same Type and a Length of exactly 255, and rejects adjacent
same-type records otherwise.

---

## 3. Separators

To encode multiple distinct values with the same Type (a list), separate them
with a zero-length TLV of a different Type. Pairing messages define Type `0xFF`
(Separator) for this purpose; in generic TLV8 characteristic payloads the
separator Type is arbitrary, as long as the characteristic does not use it for
something else:

```
Record 1: Type=0x01, Length=32, Value[32 bytes]  // First identifier
Record 2: Type=0xFF, Length=0                     // Separator
Record 3: Type=0x01, Length=32, Value[32 bytes]  // Second identifier
```

Without the separator, the decoder would concatenate the values.

---

## 4. Value Encoding

### 4.1 Integers

Unsigned integers are encoded in **little-endian** format, using the minimum
bytes needed (1, 2, 4, or 8 bytes):

| Value | Bytes | Hex Encoding  |
| ----- | ----- | ------------- |
| 1     | 1     | `01`          |
| 256   | 2     | `00 01`       |
| 65536 | 4     | `00 00 01 00` |

### 4.2 Strings

UTF-8 encoded, **without** null terminator. Length indicates string bytes:

```
"Hello" → Type, 0x05, 0x48 0x65 0x6C 0x6C 0x6F
```

### 4.3 Binary Data

Raw bytes, length indicates byte count.

### 4.4 Nested TLV

A TLV value can itself be a complete TLV8 structure (sub-TLV).

---

## 5. Pairing TLV Type Codes

These type codes are used in pair-setup, pair-verify, and pairings endpoints:

| Code   | Name          | Description                                           | Source             |
| ------ | ------------- | ----------------------------------------------------- | ------------------ |
| `0x00` | Method        | Pairing method (see Methods table)                    | `HAPPairing.h:108` |
| `0x01` | Identifier    | Pairing identifier (UTF-8 string, max 36 bytes)       | `HAPPairing.h:114` |
| `0x02` | Salt          | SRP salt (16+ bytes random)                           | `HAPPairing.h:120` |
| `0x03` | PublicKey     | Curve25519, SRP public key, or signed Ed25519 key     | `HAPPairing.h:126` |
| `0x04` | Proof         | SRP proof (M1/M2) or Ed25519 password proof           | `HAPPairing.h:132` |
| `0x05` | EncryptedData | Encrypted payload with auth tag appended              | `HAPPairing.h:138` |
| `0x06` | State         | Pairing state: 1=M1, 2=M2, 3=M3, 4=M4, 5=M5, 6=M6     | `HAPPairing.h:144` |
| `0x07` | Error         | Error code if failed (omit if success)                | `HAPPairing.h:150` |
| `0x08` | RetryDelay    | Seconds to wait before retry (obsolete since R3)      | `HAPPairing.h:158` |
| `0x09` | Certificate   | X.509 certificate (for MFi auth)                      | `HAPPairing.h:164` |
| `0x0A` | Signature     | Ed25519 or Apple Authentication Coprocessor signature | `HAPPairing.h:170` |
| `0x0B` | Permissions   | Controller permissions (0x00=user, 0x01=admin)        | `HAPPairing.h:178` |
| `0x0C` | FragmentData  | Non-last fragment (obsolete since R7)                 | `HAPPairing.h:187` |
| `0x0D` | FragmentLast  | Last fragment (obsolete since R7)                     | `HAPPairing.h:196` |
| `0x0E` | SessionID     | Session resume identifier                             | `HAPPairing.h:203` |
| `0x13` | Flags         | Pairing type flags (32-bit)                           | `HAPPairing.h:209` |
| `0xFF` | Separator     | Zero-length TLV separating list items                 | `HAPPairing.h:215` |

---

## 6. Pairing Methods

| Value  | Name              | Description                        |
| ------ | ----------------- | ---------------------------------- |
| `0x00` | PairSetup         | Standard pair setup                |
| `0x01` | PairSetupWithAuth | Pair setup with MFi authentication |
| `0x02` | PairVerify        | Session establishment              |
| `0x03` | AddPairing        | Add additional controller pairing  |
| `0x04` | RemovePairing     | Remove a controller pairing        |
| `0x05` | ListPairings      | List all current pairings          |
| `0x06` | PairResume        | Resume a previous session (R14+)   |

From `HAPPairing.h:51-76`.

---

## 7. Pairing Error Codes

| Value  | Name           | Description                                      |
| ------ | -------------- | ------------------------------------------------ |
| `0x01` | Unknown        | Generic error for unexpected conditions          |
| `0x02` | Authentication | Setup code or signature verification failed      |
| `0x03` | Backoff        | Wait RetryDelay before retry (obsolete since R3) |
| `0x04` | MaxPeers       | Server cannot accept more pairings               |
| `0x05` | MaxTries       | Too many failed authentication attempts          |
| `0x06` | Unavailable    | Pairing method unavailable                       |
| `0x07` | Busy           | Server busy, cannot accept pairing now           |

From `HAPPairing.h:82-102` and `HAPServer.ts:33-43`.

---

## 8. Wire Format Examples

### 8.1 Pair Setup M1 Request

```
06 01 01    // State = 0x01 (M1)
00 01 00    // Method = 0x00 (PairSetup)
```

Hex dump: `06 01 01 00 01 00`

### 8.2 Pair Setup M2 Response

```
06 01 02                    // State = 0x02 (M2)
02 10 <16 bytes salt>       // Salt (16 bytes)
03 <fragmented>             // PublicKey (384 bytes, see below)
```

A TLV8 length field is a single byte, so the 384-byte value cannot be carried in
one record; the SRP public key B is split into two fragments:

```
03 FF <255 bytes>           // First fragment
03 81 <129 bytes>           // Second fragment (384-255=129)
```

### 8.3 Error Response

```
06 01 02    // State = M2
07 01 02    // Error = 0x02 (Authentication)
```

---

## 9. Base64 Encoding

When TLV8 data is transmitted in JSON (e.g., for TLV8 characteristics), it MUST
be base64-encoded:

```json
{
  "value": "BgEBAAEA"
}
```

Decoded: `06 01 01 00 01 00` (M1 request)

---

## 10. Parser Rules

1. **Unknown types**: Silently ignore TLV types not expected by the context
2. **Missing required types**: Return error
3. **Consecutive same types**: Concatenate values (fragmentation)
4. **Zero-length values**: Valid; used for separators and empty data
5. **Order**: TLVs may appear in any order unless specifically required
