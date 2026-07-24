# HAP Pairing Protocol

This document describes the pairing protocols: Pair Setup for initial pairing
and Pair Verify for session establishment.

---

## 1. Cryptographic Algorithms

| Purpose               | Algorithm           | Key/Output Size     | Notes                  |
| --------------------- | ------------------- | ------------------- | ---------------------- |
| Password verification | SRP-6a with SHA-512 | 3072-bit N          | RFC 5054 group         |
| Key derivation        | HKDF-SHA-512        | 32 bytes output     | RFC 5869               |
| Symmetric encryption  | ChaCha20-Poly1305   | 32 bytes key        | AEAD, 16-byte auth tag |
| Long-term identity    | Ed25519             | 32 bytes public key | Signatures             |
| Session key exchange  | X25519              | 32 bytes public key | Curve25519 ECDH        |

---

## 2. Pair Setup Protocol

Pair Setup establishes a long-term pairing between controller and accessory
using the 8-digit setup code. This occurs once per controller.

### 2.1 State Machine

```
Controller                                    Accessory
    |                                             |
    |-------- M1: SRP Start Request ------------->|
    |              (State=1, Method=0)            |
    |                                             |
    |<------- M2: SRP Start Response -------------|
    |              (State=2, Salt, PublicKey=B)   |
    |                                             |
    |-------- M3: SRP Verify Request ------------>|
    |              (State=3, PublicKey=A, Proof)  |
    |                                             |
    |<------- M4: SRP Verify Response ------------|
    |              (State=4, Proof)               |
    |                                             |
    |-------- M5: Exchange Request -------------->|
    |              (State=5, EncryptedData)       |
    |                                             |
    |<------- M6: Exchange Response --------------|
    |              (State=6, EncryptedData)       |
```

### 2.2 SRP-6a Parameters

HAP uses SRP-6a with these specific parameters (from `SRP.h` and RFC 5054):

| Parameter | Value                                                            |
| --------- | ---------------------------------------------------------------- |
| N         | 3072-bit prime from RFC 5054 (see below)                         |
| g         | 5                                                                |
| Hash      | SHA-512 (replaces SHA-1 in standard SRP)                         |
| I         | `"Pair-Setup"` (fixed username)                                  |
| P         | 8-digit setup code in format `XXX-XX-XXX` (e.g., `"123-45-678"`) |

**3072-bit Prime N (RFC 5054):**

```
FFFFFFFF FFFFFFFF C90FDAA2 2168C234 C4C6628B 80DC1CD1
29024E08 8A67CC74 020BBEA6 3B139B22 514A0879 8E3404DD
EF9519B3 CD3A431B 302B0A6D F25F1437 4FE1356D 6D51C245
E485B576 625E7EC6 F44C42E9 A637ED6B 0BFF5CB6 F406B7ED
EE386BFB 5A899FA5 AE9F2411 7C4B1FE6 49286651 ECE45B3D
C2007CB8 A163BF05 98DA4836 1C55D39A 69163FA8 FD24CF5F
83655D23 DCA3AD96 1C62F356 208552BB 9ED52907 7096966D
670C354E 4ABC9804 F1746C08 CA18217C 32905E46 2E36CE3B
E39E772C 180E8603 9B2783A2 EC07A28F B5C55DF0 6F4C52C9
DE2BCBF6 95581718 3995497C EA956AE5 15D22618 98FA0510
15728E5A 8AAAC42D AD33170D 04507A33 A85521AB DF1CBA64
ECFB8504 58DBEF0A 8AEA7157 5D060C7D B3970F85 A6E1E4C7
ABF5AE8C DB0933D7 1E8C94E0 4A25619D CEE3D226 1AD2EE6B
F12FFA06 D98A0864 D8760273 3EC86A64 521F2B18 177B200C
BBE11757 7A615D6C 770988C0 BAD946E2 08E24FA0 74E5AB31
43DB5BFC E0FD108E 4B82D120 A93AD2CA FFFFFFFF FFFFFFFF
```

### 2.3 M1: SRP Start Request

Controller sends:

| TLV Type | Value                                            |
| -------- | ------------------------------------------------ |
| State    | `0x01` (M1)                                      |
| Method   | `0x00` (PairSetup) or `0x01` (PairSetupWithAuth) |
| Flags    | Optional pairing flags (see below)               |

**Pairing Flags (Type 0x13, from `HAPPairing.h:247-260`):**

| Flag      | Value     | Description                            |
| --------- | --------- | -------------------------------------- |
| Transient | `1 << 4`  | Pair Setup M1-M4 only, no key exchange |
| Split     | `1 << 24` | Used with Transient for split pairing  |

If M1 contained flags, the accessory returns the granted flags in a Flags TLV in
M2, omitted when the resulting value is zero (HomeKitADK echoes
`Transient | Split` together, or `Split` alone, but never `Transient` alone).
When a transient Pair Setup completes at M4, no pairing is stored; the session
immediately becomes encrypted using keys derived from the SRP shared secret `K`:

```
AccessoryToControllerKey = HKDF-SHA-512(
    Salt: "SplitSetupSalt",
    IKM:  K,
    Info: "AccessoryEncrypt-Control",
    L:    32
)
ControllerToAccessoryKey = HKDF-SHA-512(
    Salt: "SplitSetupSalt",
    IKM:  K,
    Info: "ControllerEncrypt-Control",
    L:    32
)
```

### 2.4 M2: SRP Start Response

Accessory generates:

1. Random 16-byte salt `s`
2. Computes verifier: `v = g^x mod N` where `x = H(s | H(I | ":" | P))`
3. Generates random 256-bit `b`
4. Computes public value: `B = (kv + g^b) mod N` where `k = H(N | PAD(g))`;
   `PAD()` left-pads the value with zeros to the 384-byte length of N (RFC 5054)

Response TLVs:

| TLV Type  | Value                  |
| --------- | ---------------------- |
| State     | `0x02` (M2)            |
| Salt      | 16 bytes random        |
| PublicKey | 384 bytes (3072-bit B) |

**Error Response (if applicable):**

| TLV Type | Value                     |
| -------- | ------------------------- |
| State    | `0x02` (M2)               |
| Error    | Error code (see TLV8 doc) |

Common errors:

- `0x06` Unavailable: Already paired (regardless of pairing method)
- `0x07` Busy: Another pairing in progress
- `0x05` MaxTries: Too many failed attempts (limit: 100)

### 2.5 M3: SRP Verify Request

Controller computes:

1. Generates random 256-bit `a`
2. Computes public value: `A = g^a mod N`
3. Computes: `u = H(PAD(A) | PAD(B))` (both values left-padded with zeros to 384
   bytes, RFC 5054), `x = H(s | H(I | ":" | P))`
4. Computes: `S = (B - kg^x)^(a + ux) mod N`
5. Computes session key: `K = H(S)`
6. Computes proof: `M1 = H(H(N) xor H(g) | H(I) | s | A | B | K)`

Request TLVs:

| TLV Type  | Value                  |
| --------- | ---------------------- |
| State     | `0x03` (M3)            |
| PublicKey | 384 bytes (3072-bit A) |
| Proof     | 64 bytes (SHA-512 M1)  |

### 2.6 M4: SRP Verify Response

Accessory:

1. Verifies `A mod N != 0`
2. Computes `u = H(PAD(A) | PAD(B))` (values left-padded with zeros to 384
   bytes, RFC 5054)
3. Computes `S = (Av^u)^b mod N`
4. Computes `K = H(S)`
5. Verifies M1
6. Computes `M2 = H(A | M1 | K)`

Response TLVs:

| TLV Type | Value                 |
| -------- | --------------------- |
| State    | `0x04` (M4)           |
| Proof    | 64 bytes (SHA-512 M2) |

For `PairSetupWithAuth` (Method `0x01`), M4 additionally carries an
EncryptedData TLV: a sub-TLV containing Signature (the MFi proof over a 32-byte
challenge derived via HKDF-SHA-512 with salt `MFi-Pair-Setup-Salt` and info
`MFi-Pair-Setup-Info` from the SRP session key `K`) and Certificate (the Apple
Authentication Coprocessor certificate), encrypted with the Pair Setup
encryption key (see 2.7) and nonce `PS-Msg04`.

**Error Response:**

| TLV Type | Value                          |
| -------- | ------------------------------ |
| State    | `0x04` (M4)                    |
| Error    | `0x02` (Authentication failed) |

### 2.7 M5: Exchange Request

Controller derives encryption key and sends encrypted identity:

**Key Derivation:**

```
SessionKey = K (from SRP)
EncryptionKey = HKDF-SHA-512(
    Salt: "Pair-Setup-Encrypt-Salt",
    IKM:  SessionKey,
    Info: "Pair-Setup-Encrypt-Info",
    L:    32
)
```

**Controller Signature:**

```
iOSDeviceX = HKDF-SHA-512(
    Salt: "Pair-Setup-Controller-Sign-Salt",
    IKM:  SessionKey,
    Info: "Pair-Setup-Controller-Sign-Info",
    L:    32
)
iOSDeviceInfo = iOSDeviceX || iOSDevicePairingID || iOSDeviceLTPK
iOSDeviceSignature = Ed25519_Sign(iOSDeviceLTSK, iOSDeviceInfo)
```

**Sub-TLV (to be encrypted):**

| TLV Type   | Value                          |
| ---------- | ------------------------------ |
| Identifier | Controller's pairing ID (UUID) |
| PublicKey  | Controller's LTPK (32 bytes)   |
| Signature  | Ed25519 signature (64 bytes)   |

**Encryption:**

```
EncryptedData = ChaCha20-Poly1305-Encrypt(
    Key:   EncryptionKey,
    Nonce: 4 zero bytes then "PS-Msg05" (12 bytes; see Nonce Format section),
    AAD:   empty,
    Data:  SubTLV
)
```

Request TLVs:

| TLV Type      | Value                         |
| ------------- | ----------------------------- |
| State         | `0x05` (M5)                   |
| EncryptedData | Ciphertext + 16-byte auth tag |

### 2.8 M6: Exchange Response

Accessory decrypts, verifies signature, stores pairing, and responds with its
identity:

**Accessory Signature:**

```
AccessoryX = HKDF-SHA-512(
    Salt: "Pair-Setup-Accessory-Sign-Salt",
    IKM:  SessionKey,
    Info: "Pair-Setup-Accessory-Sign-Info",
    L:    32
)
AccessoryInfo = AccessoryX || AccessoryPairingID || AccessoryLTPK
AccessorySignature = Ed25519_Sign(AccessoryLTSK, AccessoryInfo)
```

**Sub-TLV (to be encrypted):**

| TLV Type   | Value                                |
| ---------- | ------------------------------------ |
| Identifier | Accessory's pairing ID (MAC address) |
| PublicKey  | Accessory's LTPK (32 bytes)          |
| Signature  | Ed25519 signature (64 bytes)         |

**Encryption:**

```
EncryptedData = ChaCha20-Poly1305-Encrypt(
    Key:   EncryptionKey,
    Nonce: "PS-Msg06" (padded to 12 bytes with zeros),
    AAD:   empty,
    Data:  SubTLV
)
```

Response TLVs:

| TLV Type      | Value                         |
| ------------- | ----------------------------- |
| State         | `0x06` (M6)                   |
| EncryptedData | Ciphertext + 16-byte auth tag |

**Error Response:**

| TLV Type | Value                          |
| -------- | ------------------------------ |
| State    | `0x06` (M6)                    |
| Error    | `0x02` (Authentication failed) |

Sent when the M5 EncryptedData fails to decrypt (bad auth tag) or the
iOSDeviceInfo signature does not verify.

---

## 3. Pair Verify Protocol

Pair Verify establishes an encrypted session using previously exchanged LTPKs.
This occurs at the start of each connection.

### 3.1 State Machine

```
Controller                                    Accessory
    |                                             |
    |-------- M1: Verify Start Request ---------->|
    |              (State=1, PublicKey)           |
    |                                             |
    |<------- M2: Verify Start Response ----------|
    |              (State=2, PublicKey,           |
    |               EncryptedData)                |
    |                                             |
    |-------- M3: Verify Finish Request --------->|
    |              (State=3, EncryptedData)       |
    |                                             |
    |<------- M4: Verify Finish Response ---------|
    |              (State=4)                      |
```

### 3.2 M1: Verify Start Request

Controller generates ephemeral X25519 keypair and sends public key:

| TLV Type  | Value                              |
| --------- | ---------------------------------- |
| State     | `0x01` (M1)                        |
| PublicKey | 32 bytes (X25519 ephemeral public) |

### 3.3 M2: Verify Start Response

Accessory:

1. Generates ephemeral X25519 keypair
2. Computes shared secret:
   `SharedSecret = X25519(accessoryEphemeralSK, controllerEphemeralPK)`
3. Derives encryption key:

```
SessionKey = HKDF-SHA-512(
    Salt: "Pair-Verify-Encrypt-Salt",
    IKM:  SharedSecret,
    Info: "Pair-Verify-Encrypt-Info",
    L:    32
)
```

4. Signs:
   `AccessoryInfo = accessoryEphemeralPK || accessoryPairingID || controllerEphemeralPK`

```
AccessorySignature = Ed25519_Sign(AccessoryLTSK, AccessoryInfo)
```

**Sub-TLV:**

| TLV Type   | Value                        |
| ---------- | ---------------------------- |
| Identifier | Accessory's pairing ID       |
| Signature  | Ed25519 signature (64 bytes) |

**Encryption:**

```
EncryptedData = ChaCha20-Poly1305-Encrypt(
    Key:   SessionKey,
    Nonce: "PV-Msg02" (padded to 12 bytes),
    AAD:   empty,
    Data:  SubTLV
)
```

Response TLVs:

| TLV Type      | Value                             |
| ------------- | --------------------------------- |
| State         | `0x02` (M2)                       |
| PublicKey     | 32 bytes (accessory ephemeral PK) |
| EncryptedData | Ciphertext + 16-byte auth tag     |

### 3.4 M3: Verify Finish Request

Controller:

1. Computes shared secret:
   `SharedSecret = X25519(controllerEphemeralSK, accessoryEphemeralPK)`
2. Derives SessionKey (same as accessory)
3. Decrypts M2's EncryptedData
4. Looks up accessory's LTPK by pairing ID
5. Verifies accessory's signature
6. Signs:
   `ControllerInfo = controllerEphemeralPK || controllerPairingID || accessoryEphemeralPK`

```
ControllerSignature = Ed25519_Sign(ControllerLTSK, ControllerInfo)
```

**Sub-TLV:**

| TLV Type   | Value                        |
| ---------- | ---------------------------- |
| Identifier | Controller's pairing ID      |
| Signature  | Ed25519 signature (64 bytes) |

**Encryption:**

```
EncryptedData = ChaCha20-Poly1305-Encrypt(
    Key:   SessionKey,
    Nonce: "PV-Msg03" (padded to 12 bytes),
    AAD:   empty,
    Data:  SubTLV
)
```

Request TLVs:

| TLV Type      | Value                         |
| ------------- | ----------------------------- |
| State         | `0x03` (M3)                   |
| EncryptedData | Ciphertext + 16-byte auth tag |

### 3.5 M4: Verify Finish Response

Accessory:

1. Decrypts M3's EncryptedData
2. Looks up controller's LTPK by pairing ID
3. Verifies controller's signature
4. Derives session encryption keys (see Encryption document)

Response TLVs:

| TLV Type | Value       |
| -------- | ----------- |
| State    | `0x04` (M4) |

**Error Response:**

| TLV Type | Value                          |
| -------- | ------------------------------ |
| State    | `0x04` (M4)                    |
| Error    | `0x02` (Authentication failed) |

---

## 4. HKDF Parameters Summary

All HKDF operations use:

- **Hash**: SHA-512
- **Output Length**: 32 bytes

| Context                | Salt                              | Info                              |
| ---------------------- | --------------------------------- | --------------------------------- |
| Pair Setup Encryption  | `Pair-Setup-Encrypt-Salt`         | `Pair-Setup-Encrypt-Info`         |
| Controller Signature   | `Pair-Setup-Controller-Sign-Salt` | `Pair-Setup-Controller-Sign-Info` |
| Accessory Signature    | `Pair-Setup-Accessory-Sign-Salt`  | `Pair-Setup-Accessory-Sign-Info`  |
| Pair Verify Encryption | `Pair-Verify-Encrypt-Salt`        | `Pair-Verify-Encrypt-Info`        |
| Session Read Key       | `Control-Salt`                    | `Control-Read-Encryption-Key`     |
| Session Write Key      | `Control-Salt`                    | `Control-Write-Encryption-Key`    |

From `hap_handler.py` and `HAPPairingPairVerify.c` (function
`HAPPairingPairVerifyStartSession`).

---

## 5. Nonce Format

Nonces for pairing encryption are 12 bytes: 4 zero bytes followed by the ASCII
string (which is 8 bytes for all pairing nonces):

| Message | Nonce String | Hex (12 bytes)             |
| ------- | ------------ | -------------------------- |
| M5      | `PS-Msg05`   | `0000000050532D4D73673035` |
| M6      | `PS-Msg06`   | `0000000050532D4D73673036` |
| PV M2   | `PV-Msg02`   | `0000000050562D4D73673032` |
| PV M3   | `PV-Msg03`   | `0000000050562D4D73673033` |

Construction: `pack('x[4]') . "PS-Msg05"` → 4 zero bytes + 8 ASCII bytes = 12
bytes total.

---

## 6. Pairing Storage

### 6.1 Controller Permissions

| Value  | Permission | Description                          |
| ------ | ---------- | ------------------------------------ |
| `0x00` | User       | Regular user, cannot manage pairings |
| `0x01` | Admin      | Can add, remove, and list pairings   |

The first controller to pair gets Admin permission.

### 6.2 Stored Pairing Data

For each paired controller, store:

- **Pairing ID**: UTF-8 string (typically UUID format, max 36 bytes)
- **LTPK**: 32-byte Ed25519 public key
- **Permissions**: 1 byte

For the accessory, store:

- **Pairing ID**: MAC-address format `XX:XX:XX:XX:XX:XX`
- **LTPK**: 32-byte Ed25519 public key
- **LTSK**: 32-byte Ed25519 secret key

---

## 7. Add/Remove/List Pairings

After initial pairing, controllers with Admin permission can manage pairings via
POST `/pairings`:

### 7.1 Add Pairing

Request:

| TLV Type    | Value                       |
| ----------- | --------------------------- |
| State       | `0x01` (M1)                 |
| Method      | `0x03` (AddPairing)         |
| Identifier  | New controller's pairing ID |
| PublicKey   | New controller's LTPK       |
| Permissions | `0x00` or `0x01`            |

Response:

| TLV Type | Value       |
| -------- | ----------- |
| State    | `0x02` (M2) |

### 7.2 Remove Pairing

Request:

| TLV Type   | Value                   |
| ---------- | ----------------------- |
| State      | `0x01` (M1)             |
| Method     | `0x04` (RemovePairing)  |
| Identifier | Controller's pairing ID |

Response:

| TLV Type | Value       |
| -------- | ----------- |
| State    | `0x02` (M2) |

When the last admin pairing is removed, accessory should:

1. Remove all pairings
2. Update mDNS to show unpaired

The accessory keeps its long-term identity (LTPK/LTSK): reference
implementations generate a new LTSK only when none exists in persistent storage
(i.e. after a factory reset), not when the last pairing is removed.

### 7.3 List Pairings

Request:

| TLV Type | Value                 |
| -------- | --------------------- |
| State    | `0x01` (M1)           |
| Method   | `0x05` (ListPairings) |

Response (for each pairing, separated by 0xFF):

| TLV Type    | Value                   |
| ----------- | ----------------------- |
| State       | `0x02` (M2)             |
| Identifier  | Controller's pairing ID |
| PublicKey   | Controller's LTPK       |
| Permissions | Permission byte         |
| Separator   | (between pairings)      |

### 7.4 Error Responses

On failure, all three methods respond with State `0x02` (M2) plus an Error TLV:

| Error  | Condition                                                         |
| ------ | ----------------------------------------------------------------- |
| `0x02` | Requesting controller lacks Admin permission (all three methods)  |
| `0x01` | Add Pairing: identifier exists but LTPK differs; storage failures |
| `0x04` | Add Pairing: no free pairing slots (MaxPeers)                     |

If Add Pairing is called with an identifier that already exists and a matching
LTPK, the accessory updates the stored permissions and returns success. Remove
Pairing for a pairing that does not exist returns success.

---

## 8. Authentication Attempt Limits

From `HAPPairingPairSetup.c`:

- Maximum unsuccessful attempts: **100**
- After limit reached, respond with error `0x05` (MaxTries)
- Counter is stored persistently (HomeKitADK keeps it in the key-value store) so
  it survives reboots, and is reset only after a successful SRP proof
  verification
