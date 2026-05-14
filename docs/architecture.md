# ZK Backpack — internal architecture

A walk-through of how the three services fit together, where the trust
boundaries sit, what every byte of state is for, and where the known
weaknesses are. Read this before changing anything load-bearing.

## 1. Big picture

```
   ┌──────────────────────────────────────────────────────────────────┐
   │                          MOBILE DEVICE                            │
   │                                                                   │
   │  ┌──────────────┐    progress    ┌────────────────────────────┐   │
   │  │ Flutter app  │ ◄────────────► │  mobile_proof_plugin       │   │
   │  │ (Dart)       │   ProofArtifact│  ├ Dart bridge              │   │
   │  │              │                │  └ Rust core (TLSN MPC)     │   │
   │  └──────┬───────┘                └──────────────┬─────────────┘   │
   │         │ encrypted blob + selection            │                  │
   │         ▼                                       │ WebSocket MPC    │
   │  ┌──────────────────────────┐                   │                  │
   │  │ SecureLocalProofStore    │                   │                  │
   │  │ ├─ SQLite (sqflite)      │                   │                  │
   │  │ └─ AES-GCM key in        │                   │                  │
   │  │    flutter_secure_storage│                   │                  │
   │  └──────────────────────────┘                   │                  │
   └─────────────────────────────────────────────────┼──────────────────┘
                                                     │
                              HTTPS (proof upload,   │ TLSN verifier
                              share mint, revoke)    │ session
                                                     ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │                    SHARE SERVICE (Node.js)                        │
   │                                                                   │
   │  HTTP router  ───►  FileStore  ───►  data/proofs.json             │
   │      │                              ─►  data/shares.json          │
   │      │                              ─►  data/proof_blobs/*.json   │
   │      │                              ─►  data/audit.jsonl          │
   │      │                                                            │
   │      ├─► crypto.js (AES-256-GCM envelope, HMAC-SHA256 receipts)   │
   │      ├─► selection.js (field/predicate projection)                │
   │      └─► verifier.js  ──HTTP──►  mobile_tlsn_verifier_service     │
   │                                          /v1/artifacts/verify     │
   │                                                                   │
   │  Static portal served same-origin at /s/<token>, /app.js, /…      │
   └──────────────────────────────────────────────────────────────────┘
                                                     │
                                                     │ recipient opens link
                                                     ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │                       WEB PORTAL (Vue 3 CDN)                      │
   │  index.html  +  app.js  +  styles.css                             │
   │  - Calls GET /api/share/view                                      │
   │  - Renders: status, claims, predicates, receipt                   │
   │  - Receipt re-verify via POST /api/share/receipt/verify           │
   └──────────────────────────────────────────────────────────────────┘
```

## 2. The proof artifact

The mobile app obtains a `ProofArtifact` from the `mobile_proof_plugin`
plugin. Shape (lightly summarised):

```jsonc
{
  "version": "1",
  "proofId": "proof-…",
  "createdAtUtc": "2026-05-14T18:35:21.012Z",
  "deploymentMode": "hosted",
  "transcriptSummary": { "sentBytes": 1842, "recvBytes": 9123, "targetHost": "api.example.com" },
  "payload": {
    "request":  { "endpoint": { "method": "GET", "host": "api.example.com", "path": "/v1/me" } },
    "response": { "revealedBody": { "name": "Ada Lovelace", "dob": "1815-12-10", "email": "ada@example.com" } },
    "proof":    { "format": "proof.presentation.bincode", "encoding": "base64", "presentation": "…" }
  },
  "integrity": { "digestBase64": "…" }
}
```

The `payload.proof.presentation` blob is what the TLSN verifier actually
checks. The rest is metadata the app and recipient use to format and
gate the experience.

## 3. Mobile vault — `app/lib/src/local_store.dart`

- Storage: a single SQLite database (`zk_backpack.db`) inside the app's
  documents directory, table `proof_records` with columns:
  - `proof_id`, `provider_id`, `created_at_utc`, `integrity_digest`,
    `target_host`
  - `encrypted_artifact_b64`, `nonce_b64`, `mac_b64`
  - `cloud_proof_id`, `share_token`, `share_url`, `share_status`
- Key management: an AES-256 key is generated once per install and kept
  in `flutter_secure_storage`. On iOS that is the system Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), on Android it
  is the Keystore-backed `EncryptedSharedPreferences`. The SQLite file
  itself stays opaque; lose the keychain entry and you lose the vault.
- Each artifact is encrypted with AES-256-GCM (12-byte random nonce,
  separate 16-byte tag stored in the `mac_b64` column).

Why SQLite instead of a single JSON file? Concurrency, atomicity, and
indexable share state — which we display in the vault list.

## 4. Selective disclosure

The mobile app and the server share a *selection grammar* described in:

- `app/lib/src/share_selection.dart` — data types `RevealField` and
  `RevealPredicate`.
- `app/lib/src/selection_evaluator.dart` — client-side preview so the
  user knows exactly what they're about to share.
- `share_service/src/selection.js` — server-side mirror, used during
  `GET /api/share/view` to project the decrypted artifact down to the
  authorised claims.

A `ShareSelection` carries two lists:

```json
{
  "fields": [
    { "path": "$.responseData.name", "label": "Full name" }
  ],
  "predicates": [
    {
      "id": "p1",
      "label": "Adult",
      "sourcePath": "$.responseData.dob",
      "transform": "dateToYearsTillNow",
      "op": ">=",
      "value": 18
    }
  ]
}
```

Supported transforms (in the UI):
- `identity` — value as-is.
- `dateToYearsTillNow` — parses any ISO/`DD-MM-YYYY`/`DD/MM/YYYY` date
  and returns whole years between then and now (0 for future dates).
  Works for DOB, account join date, contract start, etc.
- `parseNumber` — coerces strings to numbers (handles ints and floats).
- `length` — character count of the value's string form.
- `digitsOnly` — strips everything except `0-9` (useful for phone /
  identifier length checks).

Older share records may also carry `dobToAgeYears`, `parseInt`, `lower`,
`upper`, or `extractDigits`. Each is accepted as a silent alias for the
equivalent modern transform; no migration is needed.

Supported ops: `==, !=, >, >=, <, <=, between, contains, startsWith,
endsWith, truthy`. String comparison is case-insensitive (so
`name == "ada"` matches `"Ada"`); add a `digitsOnly` or other transform
first if you need a strict-equality check on canonical form.

The server is the *enforcer*. The client preview is informational. If
the user does not include a predicate, the corresponding source field
stays inside the encrypted blob.

## 5. Share token lifecycle

States and transitions (managed by `share_service/src/store.js`):

```
        POST /shares            POST /shares/:token/revoke
created ──────────────► active ─────────────────────────► revoked (terminal)
                          │
                          │  GET /api/share/view × N
                          ▼
                       active (views++; gated by oneTimeView & maxViews)
                          │
                          │  clock > expiresAtUtc
                          ▼
                       expired (terminal)
```

A token is a 24-byte (`crypto.randomBytes(24)`) base64url string — 192
bits of entropy. The token registry (`shares.json`) carries `ownerId`,
`proofId`, `policyTemplate`, `selection`, `createdAtUtc`,
`expiresAtUtc`, `oneTimeView`, `maxViews`, `views`, and `revoked`.

Revocation is a soft flag. The blob is **not** deleted because the same
proof may back other active tokens for the same owner. To physically
wipe a proof, the user deletes it from the app (an extra
`DELETE /proofs/:id` endpoint can be added — left out today because the
mobile app handles wipe locally and the operator can hard-delete from
disk).

## 6. Server-side verification path

`verifyToken(token)` in `share_service/src/server.js`:

1. Look up the share record by token.
2. Gate: revoked? expired? oneTimeView consumed? maxViews reached? →
   return early with a `403` and a status enum the portal renders.
3. Look up the encrypted blob, decrypt with the envelope key.
4. POST to `${VERIFIER_URL}/v1/artifacts/verify` with the full artifact,
   bounded by `VERIFIER_TIMEOUT_MS`. The verifier returns
   `{integrityVerified, semanticVerified, reason}`.
5. Increment the view counter on the share.
6. Build a receipt payload (`tokenId`, `proofId`, `artifactHash`,
   `verifierResult`, `verifiedAt`), sign it with HMAC-SHA256 under the
   master key, return JSON to the caller.
7. Append a `share_verified` line to `data/audit.jsonl`.

Only after gates pass and the verifier blesses the artifact do scoped
claims leave the process boundary.

## 7. Identity & trust boundaries

There are four trust zones:

| Zone                         | Owns                                            | Trusts                                                    |
| ---------------------------- | ----------------------------------------------- | --------------------------------------------------------- |
| Mobile device                | Notary public key, encryption key, SQLite vault | The OS keystore, the verifier's notary attestation        |
| Share service                | Master envelope key, share registry, audit log  | The mobile app (over `x-owner-id` from upstream auth) and the verifier (TLS + URL pin) |
| TLSN verifier service        | Notary signing key, MPC session machinery       | Nothing about the share service except inbound HTTP       |
| Recipient browser            | Nothing                                         | The share service's TLS cert, the receipt's HMAC          |

The `x-owner-id` header is the *one* spot where the share service trusts
the caller. The expectation is that `share_service` runs behind a
reverse proxy / API gateway that performs authentication (mTLS, OAuth,
session JWT, …) and forwards a vetted identity in this header. Running
the service raw on the open internet without that proxy is not safe.
This is documented in `share_service/README.md` and called out in
[`tee_design.md`](tee_design.md) where attestation can subsume part of
this responsibility.

## 8. Threat model & controls

| Threat                                                                 | Control                                                                                                     |
| ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| Encrypted blob lifted off disk                                         | Two-layer AES-256-GCM (DEK + master) with authenticated tags. Master key in env, never on disk.            |
| Master key leak via fallback default                                   | Removed. The server exits fatally if `MASTER_KEY_B64` is unset.                                              |
| Forged owner identity to revoke / read another owner's proofs          | `requiredOwner()` validates against `/^[A-Za-z0-9._:@-]{1,128}$/` and *every* proof/share check compares `ownerId`. Production must put an authenticator in front of the service. |
| Path traversal via crafted proofId or share token                      | `sanitizeProofId` + `sanitizeToken` whitelists; `FileStore.blobPathFor` re-resolves via `path.resolve` and asserts containment in `blobDir`. |
| OOM via large JSON body                                                | `MAX_BODY_BYTES` ceiling streamed during read; abort with 413 over the limit.                                |
| Token brute-force via `/api/share/resolve` or `/view`                  | 192-bit token entropy + per-IP rate-limit (`RATE_LIMIT_WINDOW_MS` / `RATE_LIMIT_MAX`).                       |
| Hung verifier locks request handlers                                   | `AbortController`-wrapped fetch with `VERIFIER_TIMEOUT_MS`. Failure returns a clear `Verifier service timed out` instead of stalling. |
| Concurrent revoke + view race                                          | `serializeWrites(filePath, task)` in `store.js` runs all mutations on a given JSON file through an in-process FIFO queue. |
| Receipt forgery                                                        | HMAC-SHA256 over `header.body` with `timingSafeEqual` verification.                                          |
| XSS in the portal                                                      | Vue interpolation only; trusted SVG icons via `v-html`. `/s/<token>` HTML-escapes the token before injection. CSP locks `script-src` to `self` + `unpkg.com`. |
| Click-jacking                                                          | `x-frame-options: DENY` on the portal HTML.                                                                   |
| Audit-log tampering                                                    | JSONL is appended atomically; *but* the file itself is not signed. Mitigation: ship logs to an external append-only sink, or use a TEE-backed log (see TEE doc). |

## 9. Known gaps (read before promoting to staging)

1. **Identity.** The `x-owner-id` header trust model assumes an upstream
   authenticator. Stand one up before exposing the service publicly.
2. **TLS.** The service speaks plain HTTP. Terminate TLS at a reverse
   proxy (nginx, Caddy, Cloud Run, etc.) or wire it in here.
3. **Audit log signing.** The JSONL is append-only by convention, not
   cryptographically. A hash-chained log or external sink is the
   production-ready path.
4. **Receipt key publication.** Recipients have to call back into the
   service to re-verify a receipt. To support fully offline recipient
   verification, switch to Ed25519 + publish the verification key
   (e.g. `/.well-known/zk-backpack.jwks`).
5. **Server scale-out.** `FileStore` is single-node. Migrate to
   SQLite/Postgres or KMS-backed S3 to scale horizontally.
6. **Notary key rotation.** The trusted notary keys are configured per
   build. Wire them to a remote KMS for in-flight rotation.

The follow-on document [`tee_design.md`](tee_design.md) walks through how
hosting the share service in a TEE absorbs items 1, 3, 4 (partially),
and 5 simultaneously.

## 10. Data inventory

Everything the system writes lives in two places:

```
zk_backpack/data/
├── proofs.json                         # owner → proof metadata (no plaintext)
├── shares.json                         # token → share record (selection + state)
├── audit.jsonl                         # append-only event log
└── proof_blobs/
    └── <proofId>.json                  # envelope-encrypted artifact
```

On the device:

```
<app docs>/zk_backpack.db               # encrypted SQLite vault
<flutter_secure_storage namespace>      # AES key (Keychain / Keystore)
```

Wiping `data/` resets the backend completely. Uninstalling the app
wipes the device vault (Keychain entries may or may not persist
depending on iOS reinstall policy — test this for your distribution
strategy).

## 11. Where to look in the code

| Concern                           | Path                                                                  |
| --------------------------------- | --------------------------------------------------------------------- |
| Vault encryption                  | `app/lib/src/local_store.dart`                                        |
| Selection types                   | `app/lib/src/share_selection.dart`                                    |
| Client-side selection preview     | `app/lib/src/selection_evaluator.dart`                                |
| Share service client              | `app/lib/src/share_service_client.dart`                               |
| App UI (all screens)              | `app/lib/main.dart`                                                   |
| HTTP routing + gates              | `share_service/src/server.js`                                         |
| Envelope crypto + receipts        | `share_service/src/crypto.js`                                         |
| Persistence + atomic writes       | `share_service/src/store.js`                                          |
| Selection enforcement (server)    | `share_service/src/selection.js`                                      |
| Outbound verifier call            | `share_service/src/verifier.js`                                       |
| Portal UI                         | `web_portal/index.html`, `web_portal/app.js`, `web_portal/styles.css` |
| TLSN verifier API contract        | `../mobile_tlsn_verifier_service/src/handlers.rs:282-345` (`/v1/artifacts/verify`) |
| Flutter plugin entry              | `../mobile_tlsn_plugin/flutter_plugin/lib/src/session_orchestrator.dart:280-298` |

## 12. Sequence diagrams

### Generate & share

```
App        Plugin (Rust)        Verifier              Share service
 │  attestProvider() │              │                        │
 │ ────────────────► │              │                        │
 │                   │ register     │                        │
 │                   │ ───────────► │                        │
 │                   │ MPC WS       │                        │
 │                   │ ◄──────────► │                        │
 │ ◄──ProofArtifact──│              │                        │
 │                                                            │
 │ encrypt locally (AES-GCM, key in keychain)                 │
 │                                                            │
 │ user picks selection in bottom sheet                       │
 │                                                            │
 │ POST /proofs (encrypted artifact)                          │
 │ ──────────────────────────────────────────────────────────►│
 │ ◄────────── { proofId, status:"stored_encrypted" } ────────│
 │ POST /shares (selection, policy)                           │
 │ ──────────────────────────────────────────────────────────►│
 │ ◄────────── { token, url, expiresAtUtc } ──────────────────│
 │ render QR, show URL                                        │
```

### Recipient view

```
Browser           Share service                Verifier
   │ GET /s/<token>     │                         │
   │ ──────────────────►│ serves portal HTML      │
   │ ◄──────────────────│                         │
   │ JS: GET /api/share/view?token=…              │
   │ ──────────────────►│                         │
   │                    │ gate(token)             │
   │                    │ decrypt blob (envelope) │
   │                    │ POST /v1/artifacts/verify
   │                    │ ───────────────────────►│
   │                    │ ◄───────────────────────│
   │                    │ project claims via selection
   │                    │ HMAC-sign receipt        │
   │                    │ append audit            │
   │ ◄──────────────────│ { status, scopedClaims, receipt }
   │ render verified UI │
```
