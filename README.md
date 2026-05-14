# ZK Backpack

Portable, verifiable, privacy-preserving credentials — generated on a phone,
shared as a scoped link, verified server-side, viewed in a browser.

ZK Backpack is a reference implementation of a small system that turns
[TLSNotary](https://docs.tlsnotary.org/) proofs into shareable credentials.
You generate a proof inside the mobile app, store it encrypted in a local
vault, choose exactly which fields (or zero-knowledge predicates, like *"age
≥ 18"*) you want to expose, and hand out a single QR/URL. The recipient opens
the link in any browser, and the share service decrypts the proof, runs it
through the TLSN verifier, and renders only the scoped claims you authorized
— along with a signed receipt.

```
┌───────────────┐                ┌──────────────────┐                ┌──────────────────┐
│  Flutter app  │  encrypted     │  share_service   │   /v1/...      │ TLSN verifier    │
│  (mobile)     │ ───proof────►  │   (Node.js)      │ ─verify──────► │  service (Rust)  │
│  • vault      │                │  • blob store    │ ◄─attest───── │  (TLSNotary)     │
│  • selective  │                │  • share tokens  │                └──────────────────┘
│    sharing    │                │  • revocation    │
│  • revoke     │                │  • receipts      │
└──────┬────────┘                └────────┬─────────┘
       │  QR / share link                 │   serves /s/<token>
       ▼                                  ▼
┌────────────────────────────────────────────────┐
│  web_portal — recipient UI, no install needed  │
└────────────────────────────────────────────────┘
```

## What it demonstrates

1. **Self-custody.** Proofs live on the user's device first. Local-only is
   the default; uploading is opt-in per share.
2. **Selective disclosure.** A proof can carry many fields, but the user
   chooses which to reveal *per share*. Predicates (`dob → age ≥ 21`) let
   them prove a fact without leaking the source value.
3. **Server-side verification.** The recipient never touches the raw proof,
   notary signature, or transcript. They get a status, the scoped claims,
   and a receipt that can be re-verified independently.
4. **Revocation.** A share token can be killed at any moment. Existing
   tokens also support expiry, max-views and one-time-view policies.
5. **Auditable.** Every store/share/verify/revoke action is appended to a
   tamper-evident audit log (`data/audit.jsonl`).

## Spec coverage

| Spec requirement                                            | Where it lives                                       |
| ----------------------------------------------------------- | ---------------------------------------------------- |
| Generate & store proofs as a local vault                    | `app/lib/src/local_store.dart` (SQLite + AES-256-GCM, key in OS keychain) |
| Share selective fields, all fields, or zero-knowledge predicates | `app/lib/src/share_selection.dart`, `app/lib/src/selection_evaluator.dart`, `share_service/src/selection.js` |
| Share service orchestrating the backend                     | `share_service/src/server.js`                       |
| Web portal — no install required                            | `web_portal/index.html`, `web_portal/app.js`, served by `share_service` at `/s/<token>` |
| Revoke a shared link                                        | `POST /shares/<token>/revoke` (`share_service/src/server.js`), exposed in the app vault UI |
| Real proof verification (not a stub)                        | `share_service/src/verifier.js` → `mobile_tlsn_verifier_service` at `POST /v1/artifacts/verify` |
| Concise, non-breaking proof rendering                       | `app/lib/main.dart` (prettified key/value rows), `web_portal/app.js` (`prettifyKey`, `printable`) |
| Industry-practice security                                  | See [`docs/architecture.md`](docs/architecture.md) → "Threat model & controls" |
| Internal architecture doc                                   | [`docs/architecture.md`](docs/architecture.md)       |
| Path to a TEE-hosted share service                          | [`docs/tee_design.md`](docs/tee_design.md)           |

## Repository layout

| Path             | What it is                                                                                                    |
| ---------------- | ------------------------------------------------------------------------------------------------------------- |
| [`app/`](app)                       | Flutter app — proof generation, encrypted vault, selective sharing, QR display, in-app verification.     |
| [`share_service/`](share_service)   | Node.js backend — encrypted blob storage, share token lifecycle, server-side TLSN verification, signed receipts, audit log. |
| [`web_portal/`](web_portal)         | Static Vue 3 (no build step) recipient UI served same-origin by `share_service`.                              |
| [`docs/`](docs)                     | API contract, architecture, TEE deep-dive, demo script.                                                       |
| [`data/`](data)                     | Runtime state (gitignored): encrypted blobs, share registry, audit log.                                       |

Each subdirectory has its own `README.md` with run instructions and a deep
walk-through of its code.

## Prerequisites

| Component         | Version                       |
| ----------------- | ----------------------------- |
| Flutter           | ≥ 3.22 (Dart SDK ≥ 3.11)      |
| Node.js           | ≥ 18 (uses native `fetch`, ESM) |
| TLSN verifier     | A running instance of [`mobile_tlsn_verifier_service`](../mobile_tlsn_verifier_service) — or a hosted MPC verifier — exposed at the URL set in `share_service/.env` (`VERIFIER_URL`). |
| Flutter plugin    | The app expects [`mobile_tlsn_plugin/flutter_plugin`](../mobile_tlsn_plugin/flutter_plugin) at a sibling path; update `app/pubspec.yaml` if you clone it elsewhere. |

## Quick start

```bash
# 1. Start the TLSN verifier service.
#    (See mobile_tlsn_verifier_service/README.md.)
#    Defaults to http://localhost:7047

# 2. Configure and start the share service.
cd share_service
cp .env.example .env
node -e "console.log(require('crypto').randomBytes(32).toString('base64'))" \
  | xargs -I{} sed -i '' 's|MASTER_KEY_B64=.*|MASTER_KEY_B64={}|' .env
node src/server.js
# Listening on http://localhost:8080

# 3. Configure and run the Flutter app.
cd ../app
cp .env.example .env
# Edit .env — set PROOF_VERIFIER_URL and PROOF_TRUSTED_NOTARY_KEYS_B64
flutter pub get
flutter run
```

End-to-end demo: generate → share with selection → open link in a browser →
revoke → reopen link. See [`docs/demo_script.md`](docs/demo_script.md).

## Configuration

### `app/.env`

| Key                                  | Required | Notes                                                                     |
| ------------------------------------ | -------- | ------------------------------------------------------------------------- |
| `PROOF_VERIFIER_URL`                 | yes      | TLSN/MPC verifier endpoint used during proof generation.                  |
| `PROOF_TRUSTED_NOTARY_KEYS_B64`      | yes      | Base64-encoded notary public key the app will trust.                      |
| `PROOF_REQUEST_TIMEOUT_MS`           | no       | Default `300000`.                                                          |
| `PROOF_PREFER_HIGH_BANDWIDTH`        | no       | `true`/`false`.                                                            |
| `PROOF_ENABLE_LOGGING`               | no       | `false` in production.                                                     |
| `PROOF_INCLUDE_TELEMETRY_IN_PROOF`   | no       | Keep `false` to minimise data in the proof artifact.                       |
| `PROOF_ENFORCE_NATIVE_CORE`          | no       | Recommended `true`.                                                        |
| `ZK_BACKPACK_SHARE_SERVICE_URL`      | yes      | URL of the running `share_service`.                                        |

### `share_service/.env`

Just five — three required, two optional. Everything else (CORS allow-origin,
body cap, rate-limit window, verifier timeout, owner header name, etc.) is
hardcoded to sensible defaults in `share_service/src/server.js`.

| Key                | Required | Notes                                                                                                                                                  |
| ------------------ | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `MASTER_KEY_B64`   | **yes**  | 32-byte base64 envelope key. Service refuses to start if unset. Generate with `node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"`. |
| `VERIFIER_URL`     | **yes**  | TLSN verifier service endpoint.                                                                                                                         |
| `PORTAL_BASE_URL`  | **yes**  | Origin of the recipient frontend (`web_portal`). Share URLs minted by `/shares` point here.                                                              |
| `PORT`             | no       | Default `8080`. On Fly.io the platform injects this.                                                                                                    |
| `DATA_DIR`         | no       | Where the FileStore writes state. Default `share_service/data` locally, `/data` on Fly.io (volume mount).                                               |

## Deploying `share_service` to Fly.io

The `share_service/` directory ships with a `Dockerfile` and `fly.toml`
sized for Fly's free tier (one `shared-cpu-1x` / 256 MB VM + a 1 GB
persistent volume). End-to-end deploy:

```bash
cd share_service
flyctl launch --no-deploy --copy-config
flyctl volumes create share_service_data --size 1 --region <region>
flyctl secrets set \
  MASTER_KEY_B64="$(node -e "console.log(require('crypto').randomBytes(32).toString('base64'))")" \
  VERIFIER_URL="https://mpc-verifier.burnt.com" \
  PORTAL_BASE_URL="https://your-portal.example.com"
flyctl deploy
```

Full instructions, costs, secret-rotation guidance, and the security
posture live in [`share_service/README.md`](share_service/README.md).

## Security model (at a glance)

- **Encryption at rest.** Mobile vault: AES-256-GCM with a key kept in
  `flutter_secure_storage` (iOS Keychain / Android Keystore). Backend blob
  store: per-proof DEK wrapped by `MASTER_KEY_B64`, also AES-256-GCM.
- **No raw proof on the wire to recipients.** Verification is server-side.
  The recipient sees `status`, `scopedClaims`, and a HMAC-signed receipt
  they can replay against `/api/share/receipt/verify`.
- **Share gates.** Tokens carry `expiresAtUtc`, `revoked` flag, optional
  `oneTimeView` and `maxViews`. Every view increments a counter and is
  logged.
- **Identity boundary.** The backend trusts an `x-owner-id` header *only*
  when set by an upstream authenticator (e.g. mTLS sidecar, OAuth proxy).
  See [`docs/architecture.md`](docs/architecture.md) → "Identity & trust
  boundaries" for why this is acceptable and what to put in front of it
  for production.
- **Defensive controls.** Body-size caps, per-IP rate limiting, request
  timeout on outbound verifier calls, opaque base64url tokens, path-safe
  proof IDs, atomic JSON writes, CSP + `X-Frame-Options: DENY` on the
  portal HTML, no inline secrets in `.env.example`.
- **What is *not* yet hardened.** This is a reference implementation. See
  [`docs/architecture.md`](docs/architecture.md) → "Known gaps". For a
  production posture, run the share service inside a TEE (Intel TDX, AWS
  Nitro Enclaves, or Confidential GKE) with the design in
  [`docs/tee_design.md`](docs/tee_design.md).

## API surface

See [`docs/api_contract.md`](docs/api_contract.md). Highlights:

- `POST /proofs` — store an encrypted proof blob.
- `POST /shares` — mint a share token (`expiresInMinutes`, `maxViews`,
  `oneTimeView`, `policyTemplate`, optional `selection`).
- `POST /shares/{token}/revoke` — revoke an active share.
- `GET  /api/share/view?token=…` — resolve + verify + return scoped claims
  and signed receipt (used by the portal).
- `POST /api/share/receipt/verify` — re-verify a receipt's HMAC.

## Publishing checklist

The repo is preconfigured to keep secrets and runtime state out of git:

- `.env` files are gitignored everywhere; only `.env.example` ships.
- `data/` (blobs, shares.json, audit.jsonl) is gitignored.
- `node_modules/`, Flutter build outputs, IDE folders, lockfiles for
  ephemeral state are gitignored.

```bash
git status --ignored
git ls-files | grep -E "\.env$|/data/"   # must print nothing
```

If you ever committed a real `MASTER_KEY_B64` or notary key, **rotate it
before pushing** — git history is forever.

## License

See [`LICENSE`](LICENSE).
