# HAP Session Encryption

After Pair Verify completes, all HTTP traffic is encrypted with
ChaCha20-Poly1305 using session keys derived from the shared secret.

---

## 1. Session Key Derivation

After Pair Verify M4, both sides derive two encryption keys from the shared
secret established during Pair Verify:

```
SharedSecret = X25519(ephemeralSecretKey, peerEphemeralPublicKey)

AccessoryToControllerKey = HKDF-SHA-512(
    Salt: "Control-Salt",
    IKM:  SharedSecret,
    Info: "Control-Read-Encryption-Key",
    L:    32
)

ControllerToAccessoryKey = HKDF-SHA-512(
    Salt: "Control-Salt",
    IKM:  SharedSecret,
    Info: "Control-Write-Encryption-Key",
    L:    32
)
```

From `HAPPairingPairVerify.c`, function `HAPPairingPairVerifyStartSession`
(lines 40-59; each `info` constant is local to its own block):

```c
static const uint8_t salt[] = "Control-Salt";
static const uint8_t info[] = "Control-Read-Encryption-Key";
static const uint8_t info[] = "Control-Write-Encryption-Key";
```

**Note:** "Read" and "Write" are from the controller's perspective:

- Accessory uses `Control-Read-Encryption-Key` for **outgoing** data
- Accessory uses `Control-Write-Encryption-Key` for **incoming** data

**Transient sessions:** A session can also be secured by transient Pair Setup
(Pair Setup M1-M4 with the Transient flag, used for Software Authentication)
without any Pair Verify. The frame format and nonce rules below are identical,
but the keys are derived from the SRP shared secret `K` instead: salt
`SplitSetupSalt`, info `AccessoryEncrypt-Control` for the
accessory-to-controller key and `ControllerEncrypt-Control` for the
controller-to-accessory key; both nonce counters start at 0 (from
`HAPPairingPairSetup.c`, "Transient Pair Setup Start Session").

---

## 2. Frame Format

Encrypted HTTP data is transmitted as a sequence of frames. Each frame:

```
+------------------+---------------------------+------------+
| Length (2 bytes) | Encrypted Data (n bytes)  | Tag (16 B) |
+------------------+---------------------------+------------+
      LE uint16         Max 1024 bytes           Auth tag
```

| Field          | Size     | Description                                       |
| -------------- | -------- | ------------------------------------------------- |
| Length         | 2 bytes  | Little-endian uint16, plaintext length (max 1024) |
| Encrypted Data | 1-1024 B | ChaCha20-Poly1305 ciphertext                      |
| Auth Tag       | 16 bytes | Poly1305 authentication tag                       |

**Maximum frame payload**: 1024 bytes (`0x400`)

From `hapCrypto.ts:100`:

```typescript
const length = Math.min(total - offset, 0x400);
```

---

## 3. Encryption Process

For each HTTP message (request, response, or `EVENT/1.0` event notification —
events share the accessory-to-controller key and nonce counter with regular
responses):

1. Split plaintext into chunks of at most 1024 bytes
2. For each chunk:
   - Write 2-byte little-endian length
   - Construct 12-byte nonce (see below)
   - Encrypt with ChaCha20-Poly1305:
     - **Key**: Direction-appropriate session key
     - **Nonce**: 12-byte nonce
     - **AAD**: The 2-byte length field
     - **Plaintext**: The chunk data
   - Append ciphertext
   - Append 16-byte auth tag
   - Increment counter
3. Concatenate all frames

From `hapCrypto.ts` (`layerEncrypt`):

```typescript
export function layerEncrypt(data: Buffer, encryption: HAPEncryption): Buffer {
  const chunks: Buffer[] = [];
  const total = data.length;
  for (let offset = 0; offset < total;) {
    const length = Math.min(total - offset, 0x400);
    const leLength = Buffer.alloc(2);
    leLength.writeUInt16LE(length, 0);

    const nonce = Buffer.alloc(8);
    writeUInt64LE(encryption.accessoryToControllerCount++, nonce, 0);

    const encrypted = chacha20_poly1305_encryptAndSeal(
      encryption.accessoryToControllerKey,
      nonce,
      leLength,
      data.subarray(offset, offset + length),
    );
    offset += length;

    chunks.push(leLength, encrypted.ciphertext, encrypted.authTag);
  }
  return Buffer.concat(chunks);
}
```

---

## 4. Nonce Construction

Nonces are 12 bytes constructed from an 8-byte counter:

```
+-------------------+-------------------------+
| Zero pad (4 bytes)| Counter (8 bytes LE)    |
+-------------------+-------------------------+
     0x00000000         Little-endian uint64
```

**Counter rules:**

- Starts at 0 for each session
- Increments by 1 after each frame
- Separate counters for each direction
- Never reuse a nonce with the same key

Example nonce for counter=5:

```
00 00 00 00 05 00 00 00 00 00 00 00
```

From `hapCrypto.ts:58-60`:

```typescript
if (nonce.length < 12) {
  nonce = Buffer.concat([Buffer.alloc(12 - nonce.length, 0), nonce]);
}
```

---

## 5. Decryption Process

For each received frame:

1. Read 2-byte length (little-endian)
2. Read `length` bytes of ciphertext
3. Read 16-byte auth tag
4. Construct 12-byte nonce from counter
5. Decrypt with ChaCha20-Poly1305:
   - **Key**: Direction-appropriate session key
   - **Nonce**: 12-byte nonce
   - **AAD**: The 2-byte length field
   - **Ciphertext**: The encrypted data
   - **Auth Tag**: The 16-byte tag
6. Verify auth tag (reject if invalid)
7. Append plaintext to result
8. Increment counter
9. Repeat until all data consumed

**Fragmentation handling:** Frames may be split across TCP packets. If a frame
is incomplete, buffer the partial data until more arrives.

From `hapCrypto.ts:124-152`:

```typescript
if (realDataLength > availableDataLength) {
  encryption.incompleteFrame = packet.subarray(offset);
  break;
}
```

---

## 6. Session State

Each session maintains:

| State Variable             | Type   | Initial | Description                  |
| -------------------------- | ------ | ------- | ---------------------------- |
| AccessoryToControllerKey   | bytes  | derived | 32-byte encryption key (A→C) |
| ControllerToAccessoryKey   | bytes  | derived | 32-byte encryption key (C→A) |
| AccessoryToControllerCount | uint64 | 0       | Nonce counter for outgoing   |
| ControllerToAccessoryCount | uint64 | 0       | Nonce counter for incoming   |

---

## 7. ChaCha20-Poly1305 Parameters

| Parameter     | Value                          |
| ------------- | ------------------------------ |
| Algorithm     | ChaCha20-Poly1305 (RFC 8439)   |
| Key size      | 32 bytes (256 bits)            |
| Nonce size    | 12 bytes (96 bits)             |
| Auth tag size | 16 bytes (128 bits)            |
| AEAD          | Yes (authenticated encryption) |

---

## 8. Wire Format Example

Encrypting HTTP response `HTTP/1.1 200 OK\r\n\r\n` (19 bytes):

```
Plaintext: "HTTP/1.1 200 OK\r\n\r\n"
Counter: 0

Length field (LE uint16): 13 00
Nonce: 00 00 00 00 00 00 00 00 00 00 00 00
AAD: 13 00
Ciphertext: <19 bytes encrypted>
Auth tag: <16 bytes>

Frame: 13 00 <19 bytes ciphertext> <16 bytes tag>
Total: 2 + 19 + 16 = 37 bytes
```

For a large response (e.g., 2500 bytes):

```
Frame 1: 00 04 <1024 bytes encrypted> <16 bytes tag>  (counter=0)
Frame 2: 00 04 <1024 bytes encrypted> <16 bytes tag>  (counter=1)
Frame 3: C4 01 <452 bytes encrypted> <16 bytes tag>   (counter=2)
```

Total overhead: 3 frames × (2 + 16) = 54 bytes

---

## 9. Error Handling

| Condition                    | Action                           |
| ---------------------------- | -------------------------------- |
| Auth tag verification failed | Close connection immediately     |
| Nonce counter overflow       | Close connection (very unlikely) |
| Incomplete frame at EOF      | Treat as error, close connection |
| Frame length > 1024          | Treat as error, close connection |

**Security note:** Never send unencrypted data after session is established. All
HTTP requests and responses must be encrypted.

---

## 10. Connection Lifecycle

```
1. TCP connection established
2. Client sends unencrypted POST /pair-verify
3. Pair Verify M1-M4 exchange (TLV8, unencrypted)
4. Session keys derived
5. All subsequent HTTP traffic encrypted
6. Connection closed when TCP closes or error
```

Session state is per-connection. A new TCP connection requires new Pair Verify.
