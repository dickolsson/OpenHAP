# HAP HTTP Endpoints

This document describes the HTTP endpoints, request/response formats, and status
codes used by HAP over IP.

---

## 1. Endpoint Summary

| Method | Path               | Auth Required | Content-Type               | Description                |
| ------ | ------------------ | ------------- | -------------------------- | -------------------------- |
| POST   | `/identify`        | No            | None                       | Trigger identification     |
| POST   | `/pair-setup`      | No            | `application/pairing+tlv8` | Perform pair setup         |
| POST   | `/pair-verify`     | No            | `application/pairing+tlv8` | Perform pair verify        |
| POST   | `/pairings`        | Yes           | `application/pairing+tlv8` | Manage pairings            |
| GET    | `/accessories`     | Yes           | `application/hap+json`     | Get accessory database     |
| GET    | `/characteristics` | Yes           | `application/hap+json`     | Read characteristics       |
| PUT    | `/characteristics` | Yes           | `application/hap+json`     | Write characteristics      |
| PUT    | `/prepare`         | Yes           | `application/hap+json`     | Timed write preparation    |
| POST   | `/resource`        | Yes           | `application/hap+json`     | Request resources (images) |

"Auth Required" = must complete Pair Verify first (encrypted session).

---

## 2. Content Types

From `internal-types.ts:86-90`:

| MIME Type                  | Usage                            |
| -------------------------- | -------------------------------- |
| `application/pairing+tlv8` | Pairing endpoints (TLV8 body)    |
| `application/hap+json`     | Accessory/characteristics (JSON) |
| `image/jpeg`               | Image resources                  |

---

## 3. POST /identify

Triggers the accessory's identification routine (e.g., flash lights, beep).

**Conditions:**

- Only works when accessory is **not paired**
- After pairing, identification is via the Identify characteristic

**Request:**

```http
POST /identify HTTP/1.1
```

No body required.

**Response:**

- `204 No Content` — Success
- `400 Bad Request` — Already paired; body is `application/hap+json`
  `{"status": -70401}` (insufficient privileges)

---

## 4. POST /pair-setup

Pair Setup protocol (M1-M6). See [HAP-Pairing.md](HAP-Pairing.md).

**Request:**

```http
POST /pair-setup HTTP/1.1
Content-Type: application/pairing+tlv8
Content-Length: <length>

<TLV8 body>
```

**Response:**

```http
HTTP/1.1 200 OK
Content-Type: application/pairing+tlv8
Content-Length: <length>

<TLV8 body>
```

**Error Responses:**

| HTTP Code | Condition                    |
| --------- | ---------------------------- |
| `400`     | Bad TLV, state errors        |
| `429`     | Already pairing (Busy error) |
| `500`     | Internal error               |

---

## 5. POST /pair-verify

Pair Verify protocol (M1-M4). See [HAP-Pairing.md](HAP-Pairing.md).

**Request/Response:** Same format as `/pair-setup`.

After successful M4, the connection becomes encrypted.

---

## 6. POST /pairings

Add, remove, or list pairings. Requires encrypted session and Admin permission.

**Request:**

```http
POST /pairings HTTP/1.1
Content-Type: application/pairing+tlv8
Content-Length: <length>

<TLV8 body>
```

See [HAP-Pairing.md](HAP-Pairing.md) for TLV format.

**Error Responses:**

| HTTP Code | Condition                           |
| --------- | ----------------------------------- |
| `470`     | Not verified (no encrypted session) |
| `400`     | Malformed request (bad TLV)         |

Insufficient permissions is not an HTTP-level error: when a non-admin controller
attempts to add, remove, or list pairings, the accessory responds `200 OK` with
a TLV8 body containing State `M2` and Error `0x02` (Authentication).

---

## 7. GET /accessories

Returns the complete accessory database.

**Request:**

```http
GET /accessories HTTP/1.1
```

**Response:**

```http
HTTP/1.1 200 OK
Content-Type: application/hap+json
Content-Length: <length>

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
              "value": "Acme Corp",
              "description": "Manufacturer"
            }
          ]
        }
      ]
    }
  ]
}
```

### 7.1 Accessory Object

| Field      | Type    | Required | Description              |
| ---------- | ------- | -------- | ------------------------ |
| `aid`      | integer | Yes      | Accessory ID (unique)    |
| `services` | array   | Yes      | Array of Service objects |

### 7.2 Service Object

| Field             | Type    | Required | Description                           |
| ----------------- | ------- | -------- | ------------------------------------- |
| `iid`             | integer | Yes      | Instance ID (unique within accessory) |
| `type`            | string  | Yes      | Service type UUID (short form)        |
| `characteristics` | array   | Yes      | Array of Characteristic objects       |
| `primary`         | boolean | No       | Is primary service                    |
| `hidden`          | boolean | No       | Is hidden from UI                     |
| `linked`          | array   | No       | Array of linked service IIDs          |

### 7.3 Characteristic Object

| Field          | Type    | Required | Description                           |
| -------------- | ------- | -------- | ------------------------------------- |
| `iid`          | integer | Yes      | Instance ID                           |
| `type`         | string  | Yes      | Characteristic type UUID (short form) |
| `perms`        | array   | Yes      | Permission strings                    |
| `format`       | string  | Yes      | Value format                          |
| `value`        | varies  | Cond.    | Current value (if readable)           |
| `description`  | string  | No       | Human-readable name                   |
| `unit`         | string  | No       | Unit of measurement                   |
| `minValue`     | number  | No       | Minimum allowed value                 |
| `maxValue`     | number  | No       | Maximum allowed value                 |
| `minStep`      | number  | No       | Minimum step between values           |
| `maxLen`       | integer | No       | Maximum string length                 |
| `maxDataLen`   | integer | No       | Maximum data length (format `data`)   |
| `valid-values` | array   | No       | List of valid enum values             |
| `ev`           | boolean | No       | Event notifications enabled           |

---

## 8. GET /characteristics

Read characteristic values.

**Request:**

```http
GET /characteristics?id=1.10,1.11&meta=1 HTTP/1.1
```

**Query Parameters:**

| Parameter | Description                       |
| --------- | --------------------------------- |
| `id`      | Comma-separated `aid.iid` pairs   |
| `meta`    | Include metadata (`1` or `true`)  |
| `perms`   | Include permissions               |
| `type`    | Include type UUID                 |
| `ev`      | Include event notification status |

**Response:**

```http
HTTP/1.1 200 OK
Content-Type: application/hap+json

{
  "characteristics": [
    {"aid": 1, "iid": 10, "value": true},
    {"aid": 1, "iid": 11, "value": 75}
  ]
}
```

**Error Response (partial failure):**

```http
HTTP/1.1 207 Multi-Status
Content-Type: application/hap+json

{
  "characteristics": [
    {"aid": 1, "iid": 10, "value": true, "status": 0},
    {"aid": 1, "iid": 99, "status": -70409}
  ]
}
```

---

## 9. PUT /characteristics

Write characteristic values and/or subscribe to events.

**Request:**

```http
PUT /characteristics HTTP/1.1
Content-Type: application/hap+json

{
  "characteristics": [
    {"aid": 1, "iid": 10, "value": false},
    {"aid": 1, "iid": 11, "ev": true}
  ]
}
```

**Write Fields:**

| Field      | Type    | Description                          |
| ---------- | ------- | ------------------------------------ |
| `aid`      | integer | Accessory ID                         |
| `iid`      | integer | Instance ID                          |
| `value`    | varies  | New value to write                   |
| `ev`       | boolean | Enable/disable event notifications   |
| `authData` | string  | Base64 additional authorization data |
| `remote`   | boolean | Write performed via remote access    |
| `r`        | boolean | Request write response               |

For timed writes, the request object also carries a top-level `pid` field
(alongside the `characteristics` array) matching a preceding `/prepare` request.

**Response (success):**

```http
HTTP/1.1 204 No Content
```

`204 No Content` applies only when every write succeeds and no write response
was requested. If an entry requested a write response (`r: true`), the server
instead returns `207 Multi-Status` with a body carrying the resulting `value`
(and `status`) for that entry.

**Response (partial failure):**

```http
HTTP/1.1 207 Multi-Status
Content-Type: application/hap+json

{
  "characteristics": [
    {"aid": 1, "iid": 10, "status": 0},
    {"aid": 1, "iid": 11, "status": -70404}
  ]
}
```

---

## 10. PUT /prepare

Prepare for a timed write operation.

**Request:**

```http
PUT /prepare HTTP/1.1
Content-Type: application/hap+json

{
  "ttl": 5000,
  "pid": 12345678
}
```

| Field | Type    | Description                  |
| ----- | ------- | ---------------------------- |
| `ttl` | integer | Time-to-live in milliseconds |
| `pid` | integer | 64-bit transaction ID        |

**Response:**

```http
HTTP/1.1 200 OK
Content-Type: application/hap+json

{
  "status": 0
}
```

The subsequent PUT `/characteristics` must include the same `pid` as a top-level
field of the request object, alongside the `characteristics` array (not inside
the individual characteristic objects):

```http
PUT /characteristics HTTP/1.1
Content-Type: application/hap+json

{
  "pid": 12345678,
  "characteristics": [
    {"aid": 1, "iid": 10, "value": true}
  ]
}
```

---

## 11. POST /resource

Request a resource (e.g., camera snapshot).

**Request:**

```http
POST /resource HTTP/1.1
Content-Type: application/hap+json

{
  "aid": 2,
  "resource-type": "image",
  "image-width": 640,
  "image-height": 480
}
```

**Response:**

```http
HTTP/1.1 200 OK
Content-Type: image/jpeg

<binary image data>
```

---

## 12. HAP Status Codes

From `HAPServer.ts:48-92` and `const.py:84-95`:

| Code     | Name                          | Description                               |
| -------- | ----------------------------- | ----------------------------------------- |
| `0`      | SUCCESS                       | Success                                   |
| `-70401` | INSUFFICIENT_PRIVILEGES       | Insufficient privileges                   |
| `-70402` | SERVICE_COMMUNICATION_FAILURE | Communication failure with service        |
| `-70403` | RESOURCE_BUSY                 | Resource is busy, try again               |
| `-70404` | READ_ONLY_CHARACTERISTIC      | Cannot write read-only characteristic     |
| `-70405` | WRITE_ONLY_CHARACTERISTIC     | Cannot read write-only characteristic     |
| `-70406` | NOTIFICATION_NOT_SUPPORTED    | Events not supported for characteristic   |
| `-70407` | OUT_OF_RESOURCE               | Out of resources                          |
| `-70408` | OPERATION_TIMED_OUT           | Operation timed out                       |
| `-70409` | RESOURCE_DOES_NOT_EXIST       | Resource does not exist (invalid aid.iid) |
| `-70410` | INVALID_VALUE_IN_REQUEST      | Invalid value in request                  |
| `-70411` | INSUFFICIENT_AUTHORIZATION    | Insufficient authorization                |
| `-70412` | NOT_ALLOWED_IN_CURRENT_STATE  | Not allowed in current state              |

---

## 13. HTTP Status Codes

From `HAPServer.ts:119-139`:

### 13.1 Success Codes

| Code  | Name         | Usage                                     |
| ----- | ------------ | ----------------------------------------- |
| `200` | OK           | Success with body                         |
| `204` | No Content   | Success, no body (PUT success)            |
| `207` | Multi-Status | Partial success (include status per item) |

### 13.2 Client Error Codes

| Code  | Name                 | Usage                              |
| ----- | -------------------- | ---------------------------------- |
| `400` | Bad Request          | Malformed request                  |
| `404` | Not Found            | Unknown endpoint                   |
| `422` | Unprocessable Entity | Well-formed but invalid parameters |

### 13.3 Server Error Codes

| Code  | Name                  | Usage                   |
| ----- | --------------------- | ----------------------- |
| `500` | Internal Server Error | Server error            |
| `503` | Service Unavailable   | Max connections reached |

### 13.4 Pairing-Specific Codes

From `HAPServer.ts:148-159`:

| Code  | Name                              | Usage                    |
| ----- | --------------------------------- | ------------------------ |
| `400` | Bad Request                       | Bad TLV, state errors    |
| `405` | Method Not Allowed                | Wrong HTTP method        |
| `429` | Too Many Requests                 | Already pairing          |
| `470` | Connection Authorization Required | No pair-verify performed |
| `500` | Internal Server Error             | Server error             |

---

## 14. Event Notifications

When a characteristic value changes and a client has subscribed (via `ev:true`),
the server pushes an event notification.

**Event Format:**

```http
EVENT/1.0 200 OK
Content-Type: application/hap+json
Content-Length: <length>

{
  "characteristics": [
    {"aid": 1, "iid": 10, "value": true},
    {"aid": 1, "iid": 11, "value": 50}
  ]
}
```

From `hap_event.py:9-18`:

```python
EVENT_MSG_STUB = (
    b"EVENT/1.0 200 OK\r\n"
    b"Content-Type: application/hap+json\r\n"
    b"Content-Length: "
)
```

**Event Coalescing:**

Events are typically coalesced with a 250ms delay to batch multiple changes.
Exceptions (immediate delivery):

- `ProgrammableSwitchEvent` (0x73) — button press
- `ButtonEvent` (0x126)

From `eventedhttp.ts`.

**Subscription Persistence:**

Subscriptions are per-connection. When the connection closes, all subscriptions
are lost.

---

## 15. Characteristic Value Encoding

### 15.1 JSON Encoding by Format

| Format   | JSON Type | Example                  |
| -------- | --------- | ------------------------ |
| `bool`   | boolean   | `true`, `false`          |
| `uint8`  | number    | `255`                    |
| `uint16` | number    | `65535`                  |
| `uint32` | number    | `4294967295`             |
| `uint64` | number    | `9007199254740991`       |
| `int`    | number    | `-1000`                  |
| `float`  | number    | `23.5`                   |
| `string` | string    | `"Hello World"`          |
| `tlv8`   | string    | Base64-encoded TLV8 data |
| `data`   | string    | Base64-encoded binary    |

### 15.2 Type Coercion

HAP accepts:

- Numbers as strings (e.g., `"1"` for bool)
- `1`/`0` for booleans
- Strings `"true"`/`"false"` for booleans

---

## 16. Request/Response Examples

### 16.1 Read Brightness

```http
GET /characteristics?id=1.10 HTTP/1.1

---

HTTP/1.1 200 OK
Content-Type: application/hap+json

{"characteristics":[{"aid":1,"iid":10,"value":75}]}
```

### 16.2 Set Brightness

```http
PUT /characteristics HTTP/1.1
Content-Type: application/hap+json

{"characteristics":[{"aid":1,"iid":10,"value":50}]}

---

HTTP/1.1 204 No Content
```

### 16.3 Subscribe to Events

```http
PUT /characteristics HTTP/1.1
Content-Type: application/hap+json

{"characteristics":[{"aid":1,"iid":10,"ev":true}]}

---

HTTP/1.1 204 No Content
```

### 16.4 Event Notification

```http
EVENT/1.0 200 OK
Content-Type: application/hap+json
Content-Length: 42

{"characteristics":[{"aid":1,"iid":10,"value":25}]}
```
