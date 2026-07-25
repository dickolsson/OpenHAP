# HAP Implementation Analysis

This document captures practical knowledge extracted from studying four mature
HAP implementations. The goal is to help developers understand _how_ real
projects solve HAP problems, not just _what_ the protocol requires.

**Provenance:** Extracted 2026-01-06 from unpinned `--depth 1` checkouts of the
implementations listed below; the source commits were not recorded. Regenerating
with the `implementations` skill replaces this notice with the extraction date
and each source repository's commit.

## Source Implementations

| Implementation | Language   | Location               | Notes                                                       |
| -------------- | ---------- | ---------------------- | ----------------------------------------------------------- |
| HAP-python     | Python     | `external/HAP-python/` | JSON service/characteristic definitions, clean architecture |
| HAP-NodeJS     | TypeScript | `external/HAP-NodeJS/` | Powers Homebridge, comprehensive TypeScript types           |
| HomeSpan       | C++        | `external/HomeSpan/`   | ESP32-focused, excellent documentation                      |
| HomeKitADK     | C          | `external/HomeKitADK/` | Apple's archived reference implementation                   |

---

## Architecture: Accessory → Service → Characteristic Hierarchy

All implementations model HAP objects with the same three-level hierarchy:

```
Bridge/Accessory (aid)
  └── Service (iid, type UUID)
        └── Characteristic (iid, type UUID, value, properties)
```

### HAP-python (Python)

Uses class-based hierarchy with JSON definition loading:

```python
# external/HAP-python/pyhap/accessory.py
class Accessory:
    def __init__(self, driver, display_name, aid=None):
        self.aid = aid
        self.services: List[Service] = []
        self.iid_manager = IIDManager()

# external/HAP-python/pyhap/service.py
class Service:
    def __init__(self, type_id: UUID, display_name=None):
        self.type_id = type_id
        self.characteristics: List[Characteristic] = []
        self.linked_services: List[Service] = []
        self.is_primary_service = None

# external/HAP-python/pyhap/characteristic.py
class Characteristic:
    def __init__(self, display_name, type_id: UUID, properties: Dict):
        self.type_id = type_id
        self._properties = properties  # Format, Permissions, min/max, etc.
        self._value = self._get_default_value()
```

**Key insight**: Services and characteristics are loaded from JSON files at
runtime via a `Loader` class, making it easy to add new types without code
changes.

### HAP-NodeJS (TypeScript)

Uses class inheritance with static type definitions:

```typescript
// external/HAP-NodeJS/src/lib/Accessory.ts
class Accessory extends EventEmitter {
  aid: number;
  services: Service[] = [];
  private identifierCache: IdentifierCache;
}

// external/HAP-NodeJS/src/lib/Service.ts
class Service extends EventEmitter {
  UUID: string;
  characteristics: Characteristic[] = [];
  optionalCharacteristics: Characteristic[] = [];
  linkedServices: Service[] = [];
  isPrimaryService?: boolean;
}
```

**Key insight**: Service and characteristic definitions are generated as
TypeScript classes with full type information, enabling compile-time validation.

### HomeSpan (C++)

Uses C++ namespaces for type organization:

```cpp
// Services are in Service:: namespace
Service::LightBulb
Service::Switch
Service::TemperatureSensor

// Characteristics are in Characteristic:: namespace
Characteristic::On
Characteristic::Brightness
Characteristic::CurrentTemperature
```

**Key insight**: Pre-defined constants for enumerated values are inherited by
instances, so `air->setVal(air->GOOD)` works after creating an AirQuality
characteristic.

### HomeKitADK (C)

Uses structs with function pointers for callbacks:

```c
// external/HomeKitADK/HAP/HAPCharacteristic.h
typedef struct {
    const HAPUUID* type;
    uint64_t iid;
    const HAPCharacteristicFormat* format;
    // ... callbacks for read/write
} HAPCharacteristic;
```

---

## Instance IDs (IID) Management

All implementations assign unique IIDs within an accessory:

- **IID 1**: Always the AccessoryInformation service
- **Services**: Get sequential IIDs
- **Characteristics**: Get IIDs after their parent service

HAP-python uses an `IIDManager` class that tracks objects bidirectionally:

```python
# external/HAP-python/pyhap/iid_manager.py
class IIDManager:
    def __init__(self):
        self.iids = {}      # obj -> iid
        self.objs = {}      # iid -> obj
        self.counter = 0

    def assign(self, obj):
        self.counter += 1
        self.iids[obj] = self.counter
        self.objs[self.counter] = obj
```

---

## Service and Characteristic Definitions

### JSON Format (HAP-python)

Services are defined with required and optional characteristics:

```json
// external/HAP-python/pyhap/resources/services.json
{
  "Lightbulb": {
    "UUID": "00000043-0000-1000-8000-0026BB765291",
    "RequiredCharacteristics": ["On"],
    "OptionalCharacteristics": [
      "Brightness",
      "Hue",
      "Saturation",
      "Name",
      "ActiveTransitionCount",
      "TransitionControl",
      "SupportedTransitionConfiguration"
    ]
  }
}
```

Characteristics define format, permissions, and constraints:

```json
// external/HAP-python/pyhap/resources/characteristics.json
{
  "Brightness": {
    "Format": "int",
    "Permissions": ["pr", "pw", "ev"],
    "UUID": "00000008-0000-1000-8000-0026BB765291",
    "minValue": 0,
    "maxValue": 100,
    "minStep": 1
  },
  "On": {
    "Format": "bool",
    "Permissions": ["pr", "pw", "ev"],
    "UUID": "00000025-0000-1000-8000-0026BB765291"
  }
}
```

### UUID Format

All HAP UUIDs use Apple's base UUID with a short form prefix:

```
Base UUID: XXXXXXXX-0000-1000-8000-0026BB765291
           ^^^^^^^^
           Short form (4 bytes)
```

Common constants:

```python
# external/HAP-python/pyhap/const.py
BASE_UUID = "-0000-1000-8000-0026BB765291"
```

### Characteristic Formats

| Format   | Description       | Default |
| -------- | ----------------- | ------- |
| `bool`   | Boolean           | `false` |
| `uint8`  | Unsigned 8-bit    | `0`     |
| `uint16` | Unsigned 16-bit   | `0`     |
| `uint32` | Unsigned 32-bit   | `0`     |
| `uint64` | Unsigned 64-bit   | `0`     |
| `int`    | Signed 32-bit     | `0`     |
| `float`  | IEEE 754 float    | `0.0`   |
| `string` | UTF-8 string      | `""`    |
| `tlv8`   | TLV8 encoded data | `""`    |
| `data`   | Base64 encoded    | `""`    |

### Permissions

| Code | Name                     | Description                              |
| ---- | ------------------------ | ---------------------------------------- |
| `pr` | Paired Read              | Client can read when paired              |
| `pw` | Paired Write             | Client can write when paired             |
| `ev` | Events                   | Supports event notifications             |
| `aa` | Additional Authorization | Write needs additional authorization     |
| `tw` | Timed Write              | Write must use the timed write procedure |
| `hd` | Hidden                   | Not visible in UI                        |
| `wr` | Write Response           | Write returns a response                 |

---

## TLV8 Encoding

### Basic Structure

TLV8 uses 1-byte type, 1-byte length, and up to 255 bytes of value:

```
+------+--------+------------------+
| Type | Length | Value (0-255 B)  |
+------+--------+------------------+
   1B      1B        0-255 B
```

### Fragmentation for Long Values

Values exceeding 255 bytes are split across consecutive TLV items with the same
type. All implementations handle this identically:

```python
# external/HAP-python/pyhap/tlv.py
def encode(*args, to_base64=False):
    for x in range(0, len(args), 2):
        tag = args[x]
        data = args[x + 1]
        total_length = len(data)
        if len(data) <= 255:
            encoded = tag + struct.pack("B", total_length) + data
        else:
            # Fragment into 255-byte chunks
            encoded = b""
            for y in range(0, total_length // 255):
                encoded = encoded + tag + b"\xff" + data[y * 255:(y + 1) * 255]
            remaining = total_length % 255
            encoded = encoded + tag + struct.pack("B", remaining) + data[-remaining:]
```

### Decoding

On decode, consecutive TLV items with the same type are concatenated:

```typescript
// external/HAP-NodeJS/src/lib/util/tlv.ts
export function decode(buffer: Buffer): Record<number, Buffer> {
  const objects: Record<number, Buffer> = {};
  // ...
  if (objects[type]) {
    objects[type] = Buffer.concat([objects[type], data]); // Concatenate fragments
  } else {
    objects[type] = data;
  }
}
```

### TLV Type Codes for Pairing

All implementations use identical type codes:

```typescript
// external/HAP-NodeJS/src/internal-types.ts
export const enum TLVValues {
  METHOD = 0x00, // Pairing method
  IDENTIFIER = 0x01, // Pairing identifier (username)
  SALT = 0x02, // SRP salt (16 bytes)
  PUBLIC_KEY = 0x03, // SRP/X25519 public key
  PASSWORD_PROOF = 0x04, // SRP proof (M1/M2)
  ENCRYPTED_DATA = 0x05, // Encrypted payload
  STATE = 0x06, // Pairing state (M1-M6)
  ERROR_CODE = 0x07, // Error code if failed
  RETRY_DELAY = 0x08, // Retry delay (obsolete)
  CERTIFICATE = 0x09, // X.509 certificate
  SIGNATURE = 0x0a, // Ed25519 signature
  PERMISSIONS = 0x0b, // Controller permissions
  FRAGMENT_DATA = 0x0c, // Non-last fragment (obsolete since R7)
  FRAGMENT_LAST = 0x0d, // Last fragment (obsolete since R7)
  SEPARATOR = 0xff, // List separator
}
```

The real enum additionally defines alias names for several of these codes —
`REQUEST_TYPE` = `METHOD` (0x00), `USERNAME` = `IDENTIFIER` (0x01),
`SEQUENCE_NUM` = `STATE` (0x06), `PROOF` = `SIGNATURE` (0x0a). Code excerpts in
this document use the aliases (`SEQUENCE_NUM`, `USERNAME`, `PROOF`)
interchangeably with the names above.

---

## Pair Setup Protocol

Pair Setup establishes a long-term pairing between controller and accessory
using SRP-6a for password verification and Ed25519 for identity exchange.

### State Machine

```
Controller                                    Accessory
    |                                             |
    |-------- M1: SRP Start Request ------------->|
    |                                             |
    |<------- M2: SRP Start Response -------------|
    |              (salt, B)                      |
    |                                             |
    |-------- M3: SRP Verify Request ------------>|
    |              (A, M1)                        |
    |                                             |
    |<------- M4: SRP Verify Response ------------|
    |              (M2)                           |
    |                                             |
    |-------- M5: Exchange Request -------------->|
    |              (encrypted: id, LTPK, proof)   |
    |                                             |
    |<------- M6: Exchange Response --------------|
    |              (encrypted: id, LTPK, proof)   |
```

### SRP-6a Parameters (HAP-Specific)

HAP uses SRP-6a with these specific parameters:

```cpp
// external/HomeSpan/src/SRP.h
// 3072-bit prime (RFC 5054)
static constexpr char N3072[] = "FFFFFFFF...FFFFFFFF";
static const uint8_t g3072 = 5;   // Generator
static constexpr char I[] = "Pair-Setup";  // Username is always "Pair-Setup"
// Password is the 8-digit setup code: "XXX-XX-XXX"
```

**Critical**: HAP replaces SHA-1 with SHA-512 throughout the SRP calculations.

### HKDF Salt and Info Strings

All implementations use identical HKDF derivation strings:

```python
# external/HAP-python/pyhap/hap_handler.py

# Pair Setup M5 decryption
PAIRING_3_SALT = b"Pair-Setup-Encrypt-Salt"
PAIRING_3_INFO = b"Pair-Setup-Encrypt-Info"
PAIRING_3_NONCE = b"PS-Msg05"  # padded to 12 bytes

# Controller signature verification
PAIRING_4_SALT = b"Pair-Setup-Controller-Sign-Salt"
PAIRING_4_INFO = b"Pair-Setup-Controller-Sign-Info"

# Accessory signature generation
PAIRING_5_SALT = b"Pair-Setup-Accessory-Sign-Salt"
PAIRING_5_INFO = b"Pair-Setup-Accessory-Sign-Info"
PAIRING_5_NONCE = b"PS-Msg06"  # padded to 12 bytes
```

### M1: SRP Start Request

Controller sends:

- `kTLVType_State`: 0x01 (M1)
- `kTLVType_Method`: 0x00 (Pair Setup) or 0x01 (Pair Setup with Auth)

### M2: SRP Start Response

Accessory generates salt and computes SRP public key B:

```typescript
// external/HAP-NodeJS/src/lib/HAPServer.ts
private handlePairSetupM1(connection, request, response): void {
  const salt = crypto.randomBytes(16);
  const srpServer = new SrpServer(srpParams, salt,
    Buffer.from("Pair-Setup"),
    Buffer.from(this.accessoryInfo.pincode),
    key);
  const srpB = srpServer.computeB();

  response.end(tlv.encode(
    TLVValues.SEQUENCE_NUM, PairingStates.M2,
    TLVValues.SALT, salt,
    TLVValues.PUBLIC_KEY, srpB
  ));
}
```

### M3: SRP Verify Request

Controller sends:

- `kTLVType_State`: 0x03 (M3)
- `kTLVType_PublicKey`: Client's SRP public key A
- `kTLVType_Proof`: Client's proof M1

### M4: SRP Verify Response

Accessory verifies the controller's SRP proof M1 and answers with its own SRP
proof M2 (the SRP proofs are conventionally named M1/M2; they are unrelated to
the pairing message numbers M1-M6 carried in the State TLV):

```typescript
// external/HAP-NodeJS/src/lib/HAPServer.ts
srpServer.setA(A);
srpServer.checkM1(M1); // Throws if pincode wrong
const M2 = srpServer.computeM2();

response.end(
  tlv.encode(
    TLVValues.SEQUENCE_NUM,
    PairingStates.M4,
    TLVValues.PASSWORD_PROOF,
    M2,
  ),
);
```

### M5: Exchange Request

Controller sends encrypted TLV containing:

- Controller's pairing identifier (UUID)
- Controller's Ed25519 long-term public key (LTPK)
- Ed25519 signature proving ownership

The encryption key is derived via HKDF:

```python
# external/HAP-python/pyhap/hap_handler.py
session_key = srp_verifier.get_session_key()
hkdf_enc_key = hap_hkdf(
    long_to_bytes(session_key),
    b"Pair-Setup-Encrypt-Salt",
    b"Pair-Setup-Encrypt-Info"
)
```

### M6: Exchange Response

Accessory responds with encrypted TLV containing:

- Accessory's pairing identifier (MAC address)
- Accessory's Ed25519 long-term public key
- Ed25519 signature

---

## Pair Verify Protocol

Pair Verify establishes an encrypted session using X25519 key exchange and
Ed25519 signatures.

### State Machine

```
Controller                                    Accessory
    |                                             |
    |-------- M1: Verify Start Request ---------->|
    |              (X25519 public key)            |
    |                                             |
    |<------- M2: Verify Start Response ----------|
    |              (X25519 pub, encrypted proof)  |
    |                                             |
    |-------- M3: Verify Finish Request --------->|
    |              (encrypted proof)              |
    |                                             |
    |<------- M4: Verify Finish Response ---------|
```

### M1: Verify Start Request

Controller sends X25519 ephemeral public key:

```python
# Controller sends
{
    kTLVType_State: 0x01,
    kTLVType_PublicKey: <32-byte X25519 public key>
}
```

### M2: Verify Start Response

Accessory generates ephemeral X25519 keypair, computes shared secret, creates
signature:

```typescript
// external/HAP-NodeJS/src/lib/HAPServer.ts
private handlePairVerifyM1(connection, request, response, tlvData): void {
  const clientPublicKey = tlvData[TLVValues.PUBLIC_KEY];

  // Generate ephemeral keypair
  const keyPair = hapCrypto.generateCurve25519KeyPair();
  const secretKey = Buffer.from(keyPair.secretKey);
  const publicKey = Buffer.from(keyPair.publicKey);

  // X25519 shared secret
  const sharedSec = Buffer.from(
    hapCrypto.generateCurve25519SharedSecKey(secretKey, clientPublicKey)
  );

  // Sign: accessory_pk || accessory_id || controller_pk
  const material = Buffer.concat([publicKey, usernameData, clientPublicKey]);
  const serverProof = tweetnacl.sign.detached(material, privateKey);

  // Derive encryption key for this exchange
  const outputKey = hapCrypto.HKDF("sha512",
    Buffer.from("Pair-Verify-Encrypt-Salt"),
    sharedSec,
    Buffer.from("Pair-Verify-Encrypt-Info"),
    32
  );

  // Encrypt proof
  const message = tlv.encode(TLVValues.USERNAME, usernameData, TLVValues.PROOF, serverProof);
  const encrypted = hapCrypto.chacha20_poly1305_encryptAndSeal(
    outputKey, Buffer.from("PV-Msg02"), null, message
  );
}
```

### M3: Verify Finish Request

Controller sends encrypted proof of identity:

```python
{
    kTLVType_State: 0x03,
    kTLVType_EncryptedData: <encrypted: username + signature>
}
```

The signature covers: `controller_pk || controller_id || accessory_pk`

### M4: Verify Finish Response

After verification, session keys are derived:

```c
// external/HomeKitADK/HAP/HAPPairingPairVerify.c
// (HAPPairingPairVerifyStartSession; each info constant is local to its
// own block)
static const uint8_t salt[] = "Control-Salt";
static const uint8_t info[] = "Control-Read-Encryption-Key";
static const uint8_t info[] = "Control-Write-Encryption-Key";
```

HKDF-SHA-512 derives the 32-byte accessory-to-controller key from the shared
secret with the read info string, and the 32-byte controller-to-accessory key
with the write info string.

---

## Session Encryption

After Pair Verify completes, all HTTP traffic is encrypted with
ChaCha20-Poly1305.

### Frame Format

```
+------------------+---------------------------+------------+
| Length (2 bytes) | Encrypted Data (n bytes)  | Tag (16 B) |
+------------------+---------------------------+------------+
      LE uint16         Max 1024 bytes           Auth tag
```

### Encryption Process

```typescript
// external/HAP-NodeJS/src/lib/util/hapCrypto.ts
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

### Nonce Handling

- 12-byte nonce: first 4 bytes zero, last 8 bytes = counter (little-endian)
- The snippet above allocates only the 8-byte counter; HAP-NodeJS left-pads it
  to 12 bytes with zero bytes inside `chacha20_poly1305_encryptAndSeal`
- Separate counters for each direction
- Counter increments after each frame

---

## HTTP Endpoints

### Endpoint Summary

| Method | Path               | Authentication | Description                            |
| ------ | ------------------ | -------------- | -------------------------------------- |
| POST   | `/identify`        | No             | Trigger identification (unpaired only) |
| POST   | `/pair-setup`      | No             | Perform pair setup                     |
| POST   | `/pair-verify`     | No             | Perform pair verify                    |
| POST   | `/pairings`        | Yes            | Manage pairings                        |
| GET    | `/accessories`     | Yes            | Get accessory database                 |
| GET    | `/characteristics` | Yes            | Read characteristics                   |
| PUT    | `/characteristics` | Yes            | Write characteristics                  |
| PUT    | `/prepare`         | Yes            | Timed write preparation                |
| POST   | `/resource`        | Yes            | Request resources (images)             |

### Content Types

```typescript
// external/HAP-NodeJS/src/internal-types.ts
export const enum HAPMimeTypes {
  PAIRING_TLV8 = "application/pairing+tlv8",
  HAP_JSON = "application/hap+json",
  IMAGE_JPEG = "image/jpeg",
}
```

### GET /accessories Response

```json
{
  "accessories": [
    {
      "aid": 1,
      "services": [
        {
          "iid": 1,
          "type": "3E",
          "characteristics": [
            {
              "iid": 2,
              "type": "14",
              "perms": ["pw"],
              "format": "bool",
              "description": "Identify"
            },
            {
              "iid": 3,
              "type": "20",
              "perms": ["pr"],
              "format": "string",
              "value": "Manufacturer Name",
              "description": "Manufacturer"
            }
          ]
        }
      ]
    }
  ]
}
```

### GET /characteristics

Query parameters:

- `id`: Comma-separated `aid.iid` pairs (e.g., `1.10,1.11`)
- `meta`: Include metadata (`1` or `true`)
- `perms`: Include permissions
- `type`: Include type UUID
- `ev`: Include event status

Response:

```json
{
  "characteristics": [
    { "aid": 1, "iid": 10, "value": true },
    { "aid": 1, "iid": 11, "value": 75 }
  ]
}
```

### PUT /characteristics

Request body:

```json
{
  "characteristics": [
    { "aid": 1, "iid": 10, "value": false },
    { "aid": 1, "iid": 11, "ev": true }
  ]
}
```

The accessory replies `204 No Content` when every entry succeeds, or
`207 Multi-Status` with a body carrying a per-characteristic `status` code when
any entry fails:

```typescript
// external/HAP-NodeJS/src/lib/HAPServer.ts
if (multiStatus) {
  response.writeHead(HAPHTTPCode.MULTI_STATUS, {
    "Content-Type": HAPMimeTypes.HAP_JSON,
  });
} else {
  response.writeHead(HAPHTTPCode.NO_CONTENT);
}
```

### Status Codes

```typescript
// external/HAP-NodeJS/src/lib/HAPServer.ts
export const enum HAPStatus {
  SUCCESS = 0,
  INSUFFICIENT_PRIVILEGES = -70401,
  SERVICE_COMMUNICATION_FAILURE = -70402,
  RESOURCE_BUSY = -70403,
  READ_ONLY_CHARACTERISTIC = -70404,
  WRITE_ONLY_CHARACTERISTIC = -70405,
  NOTIFICATION_NOT_SUPPORTED = -70406,
  OUT_OF_RESOURCE = -70407,
  OPERATION_TIMED_OUT = -70408,
  RESOURCE_DOES_NOT_EXIST = -70409,
  INVALID_VALUE_IN_REQUEST = -70410,
  INSUFFICIENT_AUTHORIZATION = -70411,
  NOT_ALLOWED_IN_CURRENT_STATE = -70412,
}
```

---

## Event Notifications

### Event Format

Events use a custom `EVENT/1.0` HTTP-like response:

```python
# external/HAP-python/pyhap/hap_event.py
EVENT_MSG_STUB = (
    b"EVENT/1.0 200 OK\r\n"
    b"Content-Type: application/hap+json\r\n"
    b"Content-Length: "
)

def create_hap_event(data):
    bytesdata = to_hap_json({"characteristics": data})
    return b"".join((
        EVENT_MSG_STUB,
        str(len(bytesdata)).encode("utf-8"),
        b"\r\n\r\n",
        bytesdata
    ))
```

### Event Body

```json
{
  "characteristics": [
    { "aid": 1, "iid": 10, "value": true },
    { "aid": 1, "iid": 11, "value": 50 }
  ]
}
```

### Subscription Management

HAP-NodeJS tracks subscriptions per-connection:

```typescript
// external/HAP-NodeJS/src/lib/util/eventedhttp.ts
private registeredEvents: Set<EventName> = new Set();  // "aid.iid" strings

public enableEventNotifications(aid: number, iid: number): void {
  this.registeredEvents.add(aid + "." + iid);
}

public sendEvent(aid: number, iid: number, value, immediateDelivery?: boolean): void {
  if (!this.registeredEvents.has(aid + "." + iid)) {
    return;  // Client not subscribed
  }
  // Queue event for delivery
}
```

### Event Coalescing

HAP-NodeJS batches events with a 250ms delay (`EVENT_COALESCING_DELAY`), except
for immediate-delivery characteristics. Coalescing is a design choice, not a
protocol requirement; see Implementation Differences below:

```typescript
// external/HAP-NodeJS/src/lib/util/eventedhttp.ts
if (immediateDelivery) {
  // Flush immediately (e.g., button press)
  this.handleEventsTimeout();
} else {
  // Coalesce with 250ms delay
  if (!this.eventsTimer) {
    this.eventsTimer = setTimeout(this.handleEventsTimeout.bind(this), 250);
  }
}
```

**Immediate delivery characteristics** (from `Accessory.ts`):

- `ProgrammableSwitchEvent` (0x73)
- `ButtonEvent` (0x126)
- `MotionDetected` (0x22)
- `ContactSensorState` (0x6A)

---

## mDNS Service Discovery

### Service Type

```
_hap._tcp
```

### TXT Record Fields

| Key  | Description                                 | Example             |
| ---- | ------------------------------------------- | ------------------- |
| `c#` | Configuration number (increments on change) | `1`                 |
| `ff` | Feature flags                               | `0`                 |
| `id` | Device ID (MAC-like format)                 | `AA:BB:CC:DD:EE:FF` |
| `md` | Model name                                  | `MyDevice`          |
| `pv` | Protocol version                            | `1.1`               |
| `s#` | State number (always `1` for IP)            | `1`                 |
| `sf` | Status flags                                | `1` (unpaired)      |
| `ci` | Category identifier                         | `5` (lightbulb)     |
| `sh` | Setup hash (optional)                       | Base64 encoded      |

### Status Flags (sf)

```typescript
// external/HAP-NodeJS/src/lib/Advertiser.ts
export const enum StatusFlag {
  NOT_PAIRED = 0x01,
  NOT_JOINED_WIFI = 0x02,
  PROBLEM_DETECTED = 0x04,
}
```

### Setup Hash Computation

```typescript
// external/HAP-NodeJS/src/lib/Advertiser.ts
static computeSetupHash(accessoryInfo: AccessoryInfo): string {
  const hash = crypto.createHash("sha512");
  hash.update(accessoryInfo.setupID + accessoryInfo.username.toUpperCase());
  return hash.digest().subarray(0, 4).toString("base64");
}
```

Here `username` is HAP-NodeJS's name for the accessory's device ID (the mDNS
`id` field, `XX:XX:XX:XX:XX:XX` format), not a display or account name. The hash
input is the 4-character Setup ID concatenated with the uppercased device ID.

### Category Identifiers

```python
# external/HAP-python/pyhap/const.py
CATEGORY_OTHER = 1
CATEGORY_BRIDGE = 2
CATEGORY_FAN = 3
CATEGORY_GARAGE_DOOR_OPENER = 4
CATEGORY_LIGHTBULB = 5
CATEGORY_DOOR_LOCK = 6
CATEGORY_OUTLET = 7
CATEGORY_SWITCH = 8
CATEGORY_THERMOSTAT = 9
CATEGORY_SENSOR = 10
CATEGORY_ALARM_SYSTEM = 11
# ... more categories, up to CATEGORY_TARGET_CONTROLLER = 32
# (HAP-NodeJS's Categories enum extends to 36, TV_STREAMING_STICK)
```

---

## Cryptographic Details

### Algorithm Summary

| Purpose              | Algorithm           | Key Size        | Notes          |
| -------------------- | ------------------- | --------------- | -------------- |
| SRP                  | SRP-6a with SHA-512 | 3072-bit N      | RFC 5054 group |
| Key derivation       | HKDF-SHA-512        | 32 bytes output |                |
| Symmetric encryption | ChaCha20-Poly1305   | 32 bytes        | AEAD           |
| Long-term identity   | Ed25519             | 32 bytes public | Signatures     |
| Session key exchange | X25519              | 32 bytes public | ECDH           |

### HKDF Parameters

All HKDF operations use:

- Hash: SHA-512
- Output length: 32 bytes

### ChaCha20-Poly1305 Nonce Format

```
+-------------------+-------------------------+
| Zero pad (4 bytes)| Counter (8 bytes LE)    |
+-------------------+-------------------------+
```

---

## Error Handling

### TLV Error Codes

```c
// external/HomeKitADK/HAP/HAPPairing.h
typedef enum {
    kHAPPairingError_Unknown = 0x01,
    kHAPPairingError_Authentication = 0x02,  // Bad pincode or signature
    kHAPPairingError_Backoff = 0x03,         // Obsolete
    kHAPPairingError_MaxPeers = 0x04,        // Too many pairings
    kHAPPairingError_MaxTries = 0x05,        // Too many failed attempts
    kHAPPairingError_Unavailable = 0x06,     // Already paired
    kHAPPairingError_Busy = 0x07,            // Another pairing in progress
} HAPPairingError;
```

### Maximum Authentication Attempts

HomeKitADK limits to 100 unsuccessful attempts before refusing all pair-setup
requests:

```c
// external/HomeKitADK/HAP/HAPPairingPairSetup.c
if (numAuthAttempts >= 100) {
    session->state.pairSetup.error = kHAPPairingError_MaxTries;
    return kHAPError_None;
}
```

---

## Implementation Differences

### Where Implementations Agree (Protocol Requirements)

- TLV type codes and encoding
- HKDF salt/info strings
- SRP-6a parameters (N, g, hash)
- Nonce construction for ChaCha20
- mDNS TXT record keys
- HTTP endpoint paths
- JSON response structure

### Where Implementations Differ (Design Choices)

| Aspect              | HAP-python   | HAP-NodeJS         | HomeSpan       | HomeKitADK      |
| ------------------- | ------------ | ------------------ | -------------- | --------------- |
| Service definitions | JSON files   | TypeScript classes | C++ namespaces | C structs       |
| Event coalescing    | Immediate    | 250ms delay        | Immediate      | Configurable    |
| Crypto library      | cryptography | Node crypto        | mbedtls        | PAL abstraction |
| Async model         | asyncio      | Callbacks          | Loop-based     | Callbacks       |

---

## References

- [spec/CLAUDE.md](CLAUDE.md) - How the spec/ documents are generated
- [HAP-python pyhap/](../external/HAP-python/pyhap/) - Python implementation
- [HAP-NodeJS src/lib/](../external/HAP-NodeJS/src/lib/) - TypeScript
  implementation
- [HomeSpan src/](../external/HomeSpan/src/) - ESP32 C++ implementation
- [HomeKitADK HAP/](../external/HomeKitADK/HAP/) - Apple reference
  implementation
