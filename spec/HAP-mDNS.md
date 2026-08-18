# HAP mDNS Service Discovery

HAP accessories advertise themselves on the local network using mDNS/Bonjour.
This enables controllers to discover accessories without manual configuration.

---

## 1. Service Type

```
_hap._tcp.local.
```

The service type is `_hap._tcp` (HAP over TCP/IP).

---

## 2. TXT Record Fields

Accessories MUST advertise the following TXT record fields; only `sh` is
optional (needed for QR code and NFC pairing):

| Key  | Description                 | Example             | Required |
| ---- | --------------------------- | ------------------- | -------- |
| `c#` | Configuration number        | `1`                 | Yes      |
| `ff` | Feature flags               | `0`                 | Yes      |
| `id` | Device ID (MAC-like format) | `AA:BB:CC:DD:EE:FF` | Yes      |
| `md` | Model name                  | `MyDevice`          | Yes      |
| `pv` | Protocol version            | `1.1`               | Yes      |
| `s#` | State number                | `1`                 | Yes      |
| `sf` | Status flags                | `1`                 | Yes      |
| `ci` | Category identifier         | `5`                 | Yes      |
| `sh` | Setup hash                  | `Duww+A==`          | Optional |

From `Advertiser.ts:155-170`.

---

## 3. Field Descriptions

### 3.1 Configuration Number (c#)

- Integer starting at 1
- Increments when accessory database changes (services, characteristics)
- Also increments after a firmware update, even if the database is otherwise
  unchanged
- Maximum value: 65535 (wraps to 1)
- Must be persisted across restarts — controllers compare it against their
  cached value, so resetting it on reboot defeats cache validation
- Controllers use this to detect when to refresh cached data

### 3.2 Feature Flags (ff)

Bitmask of pairing feature flags:

| Bit | Value  | Name                    | Description                      |
| --- | ------ | ----------------------- | -------------------------------- |
| 0   | `0x01` | Hardware Authentication | Supports MFi hardware auth       |
| 1   | `0x02` | Software Authentication | Supports software authentication |

From `Advertiser.ts:33-38`.

Most accessories use `ff=0` (no special authentication).

### 3.3 Device ID (id)

- MAC address format: `XX:XX:XX:XX:XX:XX`
- Must be globally unique
- Typically derived from actual MAC or randomly generated
- Used as accessory's pairing identifier
- Persisted across reboots

### 3.4 Model Name (md)

- Human-readable model name
- Displayed in HomeKit UI
- Example: `"Acme Smart Light"`

### 3.5 Protocol Version (pv)

- Current HAP protocol version: `"1.1"`

From `Advertiser.ts:110-111`:

```typescript
static protocolVersion = "1.1";
```

### 3.6 State Number (s#)

- Always `1` for IP transport
- Used for Bluetooth LE state management (not applicable to IP)

### 3.7 Status Flags (sf)

Bitmask of current status:

| Bit | Value  | Name             | Description                  |
| --- | ------ | ---------------- | ---------------------------- |
| 0   | `0x01` | NOT_PAIRED       | Accessory is not paired      |
| 1   | `0x02` | NOT_JOINED_WIFI  | Accessory not joined to WiFi |
| 2   | `0x04` | PROBLEM_DETECTED | Accessory has a problem      |

From `Advertiser.ts:22-26`:

```typescript
export const enum StatusFlag {
  NOT_PAIRED = 0x01,
  NOT_JOINED_WIFI = 0x02,
  PROBLEM_DETECTED = 0x04,
}
```

**Common values:**

| sf Value | Meaning              |
| -------- | -------------------- |
| `1`      | Not paired           |
| `0`      | Paired, ready        |
| `5`      | Not paired + problem |

### 3.8 Category Identifier (ci)

Accessory category for UI icon selection. See
[HAP-Categories.md](HAP-Categories.md).

Example: `ci=5` for Lightbulb.

### 3.9 Setup Hash (sh)

Optional 4-byte hash for QR code pairing:

```typescript
// From Advertiser.ts:175-179
static computeSetupHash(accessoryInfo: AccessoryInfo): string {
  const hash = crypto.createHash("sha512");
  hash.update(accessoryInfo.setupID + accessoryInfo.username.toUpperCase());
  return hash.digest().subarray(0, 4).toString("base64");
}
```

**Computation:**

```
setupHash = Base64(SHA512(SetupID + DeviceID.uppercase())[0:4])
```

The Setup ID is a 4-character alphanumeric code (A-Z, 0-9) used with the setup
code for QR code and NFC pairing.

---

## 4. Service Instance Name

The service is advertised with an instance name matching the accessory's display
name:

```
My Light Bulb._hap._tcp.local.
```

If a naming conflict occurs, mDNS automatically appends a number:

```
My Light Bulb (2)._hap._tcp.local.
```

---

## 5. Hostname

The hostname defaults to the display name with spaces replaced by dashes:

```
My-Light-Bulb.local.
```

---

## 6. Port

The service advertises the TCP port number for HAP connections:

- Default port: `51827` (from `const.py:16`)
- Can be any available port

---

## 7. Discovery Flow

1. Controller sends mDNS query for `_hap._tcp.local.`
2. Accessories respond with SRV and TXT records
3. Controller parses TXT record to determine:
   - Is it paired? (`sf` bit 0)
   - What category is it? (`ci`)
   - Is the database cached version current? (`c#`)
4. Controller shows unpaired accessories in pairing UI
5. Controller connects to IP:port from SRV record

---

## 8. TXT Record Updates

When accessory state changes, update the TXT record:

| Event                        | TXT Field to Update |
| ---------------------------- | ------------------- |
| Pairing added/removed        | `sf` (status flags) |
| Service/characteristic added | `c#` (increment)    |
| Configuration changed        | `c#` (increment)    |
| Problem detected             | `sf` (set bit 2)    |

**Silent updates:** Some mDNS implementations support "silent" TXT updates that
don't trigger announcement packets. Use for frequent updates to avoid network
spam.

---

## 9. Complete TXT Record Example

```
c#=2
ff=0
id=17:45:9E:C3:AF:01
md=OpenHAP Bridge
pv=1.1
s#=1
sf=1
ci=2
sh=aWcyuQ==
```

This describes:

- Configuration version 2
- No special features
- Device ID `17:45:9E:C3:AF:01`
- Model "OpenHAP Bridge"
- Protocol version 1.1
- State number 1
- Not paired (sf=1)
- Category: Bridge (ci=2)
- Setup hash for QR code

---

## 10. Multiple Accessories (Bridge)

A bridge advertises a single mDNS service representing all bridged accessories.
The category should be `2` (Bridge).

Individual bridged accessories are not separately advertised — they appear in
the accessory database returned by GET `/accessories`.

---

## 11. IPv4 and IPv6

HAP accessories should advertise on both IPv4 and IPv6 when available. The mDNS
responder handles announcing the appropriate A and AAAA records.

From `Advertiser.ts:68-70`:

```typescript
disabledIpv6?: boolean;  // Option to disable IPv6
```
