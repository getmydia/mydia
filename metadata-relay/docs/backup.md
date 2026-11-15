# Player backup wire format (`/backup/v1`)

End-to-end encrypted backup for Mydia players. The relay stores ciphertext and
public keys only and never sees plaintext. A vault is a group of devices; each
member owns one slot it alone may write. The Dart client (`player/lib/core/backup/`)
is built against this file. Code: `MetadataRelay.Backup.Handler` (HTTP),
`MetadataRelay.Backup` (rules).

## Conventions

- Base URL: the relay's base URL plus `/backup/v1`.
- Binary values in JSON (signers, box keys, envelopes, handles) are base64url
  **without padding**. Padding is tolerated on input. Ids (`vault_id`,
  `slot_id`, `lookup_hash`) are lowercase hex strings, passed as is.
- JSON requests use `Content-Type: application/vnd.mydia.backup`. Do not use
  `application/json` or any `+json` type: the relay's JSON parser would consume
  the body before the signature can be checked. Slot bodies use
  `application/octet-stream`. Responses are `application/json` unless noted.
- Every error body is `{"error": "<code>"}`.
- A relay without these routes answers 404 with a body that is not JSON
  (`Not found`). A 404 from this API always has a JSON `error`.
- Limits: slot 4 MiB (4,194,304 bytes), JSON body 64 KiB, 16 members per
  vault (the recovery member counts), 600 writes per vault per hour (slot
  writes and member changes share it; enough for several devices playing at
  once), vault idle expiry 180 days.
- Request bodies are never logged.

## Authentication

Every route except `POST /vaults` and `POST /lookup`:

```
Authorization: MydiaSig signer=<b64url pubkey>, ts=<unix ms>, sig=<b64url>
```

`sig` is Ed25519 over the UTF-8 string

```
METHOD \n PATH \n hex(sha256(body)) \n ts
```

`METHOD` is upper case. `PATH` is the full request path including `/backup/v1`,
without query string (for example `/backup/v1/vaults/9f...`). `hex` is lowercase.
`body` is the exact bytes sent; GET and DELETE have an empty body and hash the
empty string. `ts` is the same decimal string as in the header.

The relay checks, in order: header present and well formed, body within its cap,
`ts` within 5 minutes of the relay clock, signature, vault exists, signer is a
member of that vault.

| Failure | Status | `error` |
| --- | --- | --- |
| No `Authorization` header | 401 | `missing` |
| Unparseable header or wrong key/signature length | 401 | `malformed` |
| Signature does not verify | 401 | `bad_signature` |
| `ts` more than 5 minutes off | 401 | `skew`, with header `x-backup-server-time: <unix ms>` |
| Vault id unknown | 404 | `vault_not_found` |
| Valid signature, signer not a member | 403 | `not_member` |

On `skew` the client computes `offset = server_time - local_now`, retries once
with `ts = local_now + offset`, and keeps the offset for later calls.

`vault_not_found` is distinct from `not_found` so a client can tell a deleted
vault from a missing slot.

## Status codes shared by all routes

| Status | `error` | Meaning |
| --- | --- | --- |
| 401, 403, 404 | see above | |
| 409 | `conflict` | Member change against a stale `expected_epoch` |
| 409 | `vault_taken` | Vault creation with a `vault_id` already in use |
| 409 | `stale_epoch` | Slot write with an `x-backup-epoch` that is not the vault epoch |
| 412 | `precondition_failed` | `If-Match` does not equal the slot's current seq |
| 413 | `too_large` | Body over its cap. A `Content-Length` over the cap is refused without reading the body |
| 422 | `invalid` | Malformed or inconsistent JSON or fields |
| 422 | `lookup_taken` | Lookup hash already used by another vault |
| 422 | `too_many_members` | More than 16 members |
| 429 | `rate_limited` | With `retry-after: 3600` |
| 503 | `storage` | The relay could not write the file |

## Endpoints

### `POST /vaults`

Unauthenticated, 10 per hour per client address when address limits are on
(see "Address limits"). Creates a vault at epoch 1
under `vault_id`, which the client chooses (16 random bytes as lowercase hex)
so that the envelopes it seals in this request can bind the vault id. Two members: the first device and the recovery member. The recovery signer
authenticates but never writes a slot.

```
POST /backup/v1/vaults
Content-Type: application/vnd.mydia.backup

{
  "vault_id": "<32 lowercase hex, chosen by the client>",
  "signer": "<b64url 32 bytes>",
  "slot_id": "<16 hex>",
  "envelope": "<b64url>",
  "box_pub": "<b64url 32 bytes>",
  "recovery_signer": "<b64url 32 bytes>",
  "recovery_slot_id": "<16 hex>",
  "recovery_envelope": "<b64url>",
  "recovery_box_pub": "<b64url 32 bytes>",
  "lookup_hash": "<64 hex, sha256 of the lookup handle>"
}
```

`201 {"vault_id": "<32 hex>"}`, echoing the id sent. Errors: 422 `invalid`
(including a missing or malformed `vault_id`), 422 `lookup_taken`, 409
`vault_taken` (the id is in use: pick a new one and seal again), 429.
`slot_id` and `recovery_slot_id` must differ, as must the two signers.

### `POST /lookup`

Unauthenticated (the handle is the credential), 30 per hour per client
address when address limits are on. The handle travels in the body, never the URL, so it stays out of
access logs and caches.

```
POST /backup/v1/lookup
Content-Type: application/vnd.mydia.backup

{"handle": "<b64url of the raw 32-byte lookup handle>"}
```

`200 {"vault_id": "..."}`. A miss or a handle that is not base64url is 404
`not_found`. A body that is not JSON or has no string `handle` is 422
`invalid`; a body over 1 KiB is 413. 429 when limited.

### `GET /vaults/:id`

Member. Returns the manifest.

```
200
ETag: "1-3-2-1786000000000000"

{
  "epoch": 1,
  "members": [
    {"signer": "<b64url>", "box_pub": "<b64url>", "slot_id": "<16 hex>", "recovery": false},
    {"signer": "<b64url>", "box_pub": "<b64url>", "slot_id": "<16 hex>", "recovery": true}
  ],
  "envelope": "<b64url, the requester's own>",
  "recovery_signer": "<b64url>",
  "slots": [
    {"slot_id": "<16 hex>", "seq": 3, "epoch": 1, "size": 1204, "updated_at": 1786000000000}
  ]
}
```

`updated_at` is unix milliseconds. `members` lists every member including the
recovery one; `box_pub` is what a rotating device seals the new vault key to.
`slots` lists only slots that have been written. Send `If-None-Match: <etag>`
to get `304` with an empty body when nothing changed. The ETag is opaque and
changes with any slot write or member change.

### `PUT /vaults/:id/slots/:slot`

The slot's owner. Body is the ciphertext, `Content-Type: application/octet-stream`,
at most 4 MiB.

Headers: `x-backup-epoch: <int>` (required, must equal the vault epoch),
`If-Match: <seq>` (absent for the first write; quotes are tolerated).

```
200
ETag: "4"

{"seq": 4}
```

Errors: 403 `not_owner` (not your slot, and the recovery signer never owns one),
409 `stale_epoch`, 412 `precondition_failed`, 413, 422 (`x-backup-epoch`
missing or not an integer), 429. Slot AAD binds the seq the client expects:
use `If-Match + 1`, or `1` for a first write.

### `GET /vaults/:id/slots/:slot`

Member. `200` with `Content-Type: application/octet-stream`, the ciphertext as
body and `ETag: "<seq>"`. With `If-None-Match: "<seq>"` matching, `304`. A slot
never written is 404 `not_found`.

### `POST /vaults/:id/members`

Member (the recovery signer qualifies; that is how a restoring device adds
itself). One call adds, removes, replaces the recovery key and/or rotates,
compare-and-swapped on the epoch. Charges the vault write budget (429).

```
POST /backup/v1/vaults/:id/members
Content-Type: application/vnd.mydia.backup

{
  "expected_epoch": 1,
  "new_epoch": 2,
  "add": [{"signer": "<b64url>", "slot_id": "<16 hex>", "box_pub": "<b64url>"}],
  "remove": ["<b64url signer>"],
  "envelopes": {"<b64url signer>": "<b64url envelope>"},
  "recovery": {
    "signer": "<b64url>", "slot_id": "<16 hex>", "envelope": "<b64url>",
    "box_pub": "<b64url>", "lookup_hash": "<64 hex>"
  }
}
```

`200 {"epoch": 2}`, the epoch after the change.

Rules:

- `expected_epoch` is required and must equal the vault epoch, else 409
  `conflict`. `new_epoch` defaults to `expected_epoch`; it may be
  `expected_epoch + 1` (a rotation) and nothing else.
- `add`, `remove`, `envelopes` and `recovery` are optional (`recovery: null`
  means none).
- Without rotation, `envelopes` holds exactly one envelope per added signer.
- Removing a member, or replacing the recovery key, requires a rotation, else
  422 `invalid`. The recovery signer can only leave through `recovery`. A
  member may remove itself. Removed members lose their slot and its file.
- On rotation, `envelopes` covers every remaining member and the recovery
  member (a replaced recovery's envelope is `recovery.envelope`, so listing it
  in `envelopes` is optional). Each envelope is the new vault key sealed to
  that member's `box_pub`.
- `recovery` must carry a new signer (the current one is 422 `invalid`) and
  replaces the recovery member, its envelope and the lookup hash at once.
- Errors: 403 `not_member`, 409 `conflict`, 422 `invalid` / `lookup_taken` /
  `too_many_members`, 429.

### `DELETE /vaults/:id`

Member. Deletes the vault, its members and every slot. `204`, empty body.

## Retention

The hourly sweeper deletes any vault with no write for 180 days (or, never
written, created more than 180 days ago), files included. Slot writes and
member changes both count as writes. The backup directory is `BACKUP_DIR`,
default `backup/` beside the SQLite file.

## Address limits

The per-address limits on `POST /vaults` and `POST /lookup` are off unless
`RELAY_BACKUP_ADDRESS_LIMITS` is `1`, `true`, `yes` or `on`. Behind
Cloudflare the relay resolves every caller to a shared address, so the limits
would be one bucket for all installs. They can be turned on once the origin
accepts traffic only from Cloudflare and the relay keys on
`CF-Connecting-IP`, the same precondition as `RELAY_PROXY_RATE_LIMIT`.
