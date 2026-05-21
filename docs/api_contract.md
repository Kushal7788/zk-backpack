# ZK Backpack API Contract

## POST `/proofs`

Stores encrypted proof blob and metadata.

Request:

```json
{
  "proofId": "proof-123",
  "providerId": "gusto.employees.v1",
  "createdAtUtc": "2026-05-07T10:00:00Z",
  "integrityDigest": "base64",
  "targetHost": "graphql.app.gusto.com",
  "artifact": {}
}
```

Response:

```json
{
  "proofId": "proof-123",
  "status": "stored_encrypted"
}
```

## POST `/shares`

Creates share token.

Request:

```json
{
  "proofId": "proof-123",
  "policyTemplate": "masked",
  "expiresInMinutes": 60,
  "oneTimeView": false,
  "maxViews": 10
}
```

Response:

```json
{
  "token": "token",
  "url": "http://localhost:8080/s/token",
  "expiresAtUtc": "2026-05-07T11:00:00Z"
}
```

## POST `/shares/{token}/revoke`

Revokes active share token.

## POST `/api/share/resolve`

Validates token state (expiry/revocation/view limits).

## POST `/api/share/verify`

Runs server-side decrypt + verify and returns scoped claims and receipt.

## GET `/api/share/view?token=...`

Resolve + verify convenience endpoint for browser portal.

Successful responses include a non-sensitive `share` summary for recipient
display:

```json
{
  "status": "valid",
  "share": {
    "policyTemplate": "selection",
    "expiresAtUtc": "2026-05-07T11:00:00Z",
    "oneTimeView": true,
    "maxViews": 1,
    "views": 1
  }
}
```
