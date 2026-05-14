# ZK Backpack

ZK Backpack is a reference implementation for **portable, verifiable, privacy-preserving credentials**. It generates [zkTLS](https://docs.tlsnotary.org/) proofs on a phone, stores them encrypted in a local vault and in encrypted cloud blob storage, and lets the holder share **scoped, server-verified claims** with anyone over a QR-linked browser page — no recipient install required.

```
┌───────────────┐    zkTLS     ┌──────────────────┐    encrypted    ┌──────────────────┐
│  Flutter app  │ ───proof───► │  share_service   │ ──── blob ────► │  Verifier service│
│  (mobile)     │              │  (Node.js API)   │ ◄── receipt ─── │  (TLSN verifier) │
└──────┬────────┘              └────────┬─────────┘                 └──────────────────┘
       │                                │
       │ QR / share link                │  serves
       ▼                                ▼
┌────────────────────────────────────────────────┐
│  web_portal  (browser recipient, no install)   │
└────────────────────────────────────────────────┘
```

## Repository layout

| Path             | What it is                                                                          |
| ---------------- | ----------------------------------------------------------------------------------- |
| `app/`           | Flutter app — proof generation, encrypted local vault (SQLite + secure key), upload, QR share, optional in-app scan. |
| `share_service/` | Node.js backend — encrypted proof blob storage, share-token lifecycle, server-side verification, signed receipts, append-only audit log. |
| `web_portal/`    | Static Vue 3 (CDN, no build step) recipient UI served by `share_service`.            |
| `docs/`          | API contract and demo script.                                                       |

## Prerequisites

- **Flutter** ≥ 3.22, Dart SDK ≥ 3.11 (`flutter doctor` clean).
- **Node.js** ≥ 18 (the share service uses native ES modules).
- **A running TLSNotary verifier service** (see *External services* below). The default expects it on `http://localhost:7047`.
- The companion Flutter plugin **`mobile_proof_plugin`** is referenced by `app/pubspec.yaml` as a local path dependency:

  ```yaml
  mobile_proof_plugin:
    path: ../../mobile_tlsn_plugin/flutter_plugin
  ```

  Clone it side-by-side or update the path in `app/pubspec.yaml` before running `flutter pub get`.

## External services

ZK Backpack does **not** ship a verifier. You must provide one of:

- A local instance of `mobile_tlsn_verifier_service` exposed on the URL set in `share_service/.env` (`VERIFIER_URL`).
- A hosted MPC verifier — set `PROOF_VERIFIER_URL` on the Flutter side to point at it.

## Quick start

### 1. Clone

```bash
git clone https://github.com/<your-org>/zk_backpack.git
cd zk_backpack
```

### 2. Start the verifier service

Follow the instructions in your verifier project. By convention this repo expects:

```
http://localhost:7047
```

### 3. Start the share service

```bash
cd share_service
cp .env.example .env
# Edit .env — at minimum, generate MASTER_KEY_B64:
#   node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"
node src/server.js
```

The service listens on `http://localhost:8080` and also serves `web_portal/` at `/s/<token>`.

### 4. Run the Flutter app

```bash
cd ../app
cp .env.example .env
# Edit .env — set PROOF_VERIFIER_URL and PROOF_TRUSTED_NOTARY_KEYS_B64
# to match your verifier deployment.
flutter pub get
flutter run
```

## Configuration

### `app/.env` (do not commit)

| Key                                 | Required | Notes                                                                |
| ----------------------------------- | -------- | -------------------------------------------------------------------- |
| `PROOF_VERIFIER_URL`                | yes      | TLSN/MPC verifier endpoint.                                          |
| `PROOF_TRUSTED_NOTARY_KEYS_B64`     | yes      | Base64-encoded notary public key the app will trust.                 |
| `PROOF_REQUEST_TIMEOUT_MS`          | no       | Default `300000`.                                                    |
| `PROOF_PREFER_HIGH_BANDWIDTH`       | no       | `true`/`false`.                                                      |
| `PROOF_ENABLE_LOGGING`              | no       | `false` in production.                                               |
| `PROOF_INCLUDE_TELEMETRY_IN_PROOF`  | no       | Keep `false` to minimise data in the proof artifact.                 |
| `PROOF_ENFORCE_NATIVE_CORE`         | no       | Recommend `true`.                                                    |
| `ZK_BACKPACK_SHARE_SERVICE_URL`     | yes      | URL of the running `share_service`.                                  |

### `share_service/.env` (do not commit)

| Key                | Required | Notes                                                                                   |
| ------------------ | -------- | --------------------------------------------------------------------------------------- |
| `PORT`             | no       | Default `8080`.                                                                          |
| `HOST`             | no       | Default `0.0.0.0`.                                                                       |
| `BASE_URL`         | yes      | Public URL used in generated share links.                                                |
| `DATA_DIR`         | no       | Where encrypted blobs, share state, and audit log are written. Default `./data`.         |
| `MASTER_KEY_B64`   | **yes**  | 32-byte base64 key for envelope encryption of stored blobs. Generate with `openssl rand -base64 32`. |
| `VERIFIER_URL`     | yes      | Verifier service endpoint.                                                               |
| `OWNER_HEADER_NAME`| no       | HTTP header carrying the owner identity. Default `x-owner-id`.                            |

## API surface

See [`docs/api_contract.md`](docs/api_contract.md) for the full contract. Highlights:

- `POST /proofs` — store an encrypted proof blob.
- `POST /shares` — mint a share token (with `expiresInMinutes`, `maxViews`, `oneTimeView`, `policyTemplate`).
- `POST /shares/{token}/revoke` — revoke an active share.
- `GET  /api/share/view?token=…` — resolve, verify, and return scoped claims plus signed receipt (used by the portal).

## Demo script

A 3-minute happy-path + revocation demo is in [`docs/demo_script.md`](docs/demo_script.md).

## Security model

- Proofs are encrypted at rest in both the mobile vault (`flutter_secure_storage` + SQLite) and the backend blob store (envelope encryption with `MASTER_KEY_B64`).
- Share QR codes carry only an opaque tokenised URL — never the raw proof.
- Verification is **server-side**; the portal never sees the raw artifact, only scoped claims and a signed receipt.
- Tokens support expiry, revocation, and max-view counters.
- All share resolutions append to `data/audit.jsonl`.

## Publishing checklist (read before pushing)

This repo is preconfigured to keep sensitive material out of version control:

- `.env` files are gitignored everywhere — only `.env.example` placeholders ship.
- The runtime `data/` directory (proof blobs, share state, audit log) is gitignored.
- `node_modules/`, Flutter build outputs, IDE folders, and lockfiles for ephemeral state are gitignored.

Before your first push, double-check:

```bash
git status --ignored      # confirm .env / data are ignored, not tracked
git ls-files | grep -E "\.env$|/data/"   # should print nothing
```

If you previously committed a real `MASTER_KEY_B64`, notary key, or any other secret, **rotate it** before publishing — git history is forever.

## License

See [`LICENSE`](LICENSE).
