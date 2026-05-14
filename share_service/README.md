# ZK Backpack — share service

The orchestration layer that turns a proof artifact into a shareable,
revocable, server-verified link. Plain Node.js — no framework, no
external dependencies, no database — designed to be small enough to read
in one sitting and trivial to deploy to any Node-friendly host.

## What it does

- Receives encrypted proof artifacts from the Flutter app and persists
  them as envelope-encrypted blobs.
- Mints share tokens with policies: `expiresInMinutes`, `oneTimeView`,
  `maxViews`, and a `selection` describing exactly which fields and
  predicates to reveal.
- Resolves a token, decrypts the underlying artifact, calls the TLSN
  verifier service over HTTP, projects only the authorised claims, and
  hands the recipient back a status + signed HMAC receipt.
- Revokes tokens (soft flag with timestamp; gates every future read).
- Appends every meaningful action to a JSONL audit log.

## Project layout

```
share_service/
├── package.json              # ESM, "start": "node src/server.js", zero deps
├── Dockerfile                # node:20-alpine, copies src/, runs server
├── fly.toml                  # Fly.io app + volume + http_service config
├── .dockerignore
├── .env.example
└── src/
    ├── server.js             # HTTP router, CORS, rate-limit, body cap
    ├── crypto.js             # AES-256-GCM envelope + HMAC-SHA256 receipts
    ├── store.js              # FileStore: proofs.json, shares.json, audit.jsonl
    ├── selection.js          # mirror of the app's selection_evaluator.dart
    └── verifier.js           # outbound call to the TLSN verifier (with timeout)
```

## Endpoints

| Method | Path                              | Owner header | Purpose                                                                                          |
| ------ | --------------------------------- | ------------ | ------------------------------------------------------------------------------------------------ |
| GET    | `/health`                         | no           | Liveness probe (also used by Fly's TCP/HTTP check).                                              |
| POST   | `/proofs`                         | **yes**      | Upload an encrypted proof artifact.                                                              |
| POST   | `/shares`                         | **yes**      | Mint a share token.                                                                              |
| POST   | `/shares/<token>/revoke`          | **yes**      | Soft-revoke a share. Only the owner that minted it can revoke.                                   |
| POST   | `/api/share/resolve`              | no           | Light-weight token status check.                                                                 |
| POST   | `/api/share/verify`               | no           | Full server-side verify.                                                                         |
| GET    | `/api/share/view?token=…`         | no           | Same as `verify` but query-string form, used by the portal.                                      |
| POST   | `/api/share/receipt/verify`       | no           | Re-verifies the HMAC over a previously-issued receipt token.                                     |

Full request/response schemas live in
[`../docs/api_contract.md`](../docs/api_contract.md).

## Environment variables

Just five — three required, two optional.

| Variable           | Required | Notes                                                                                                                                                  |
| ------------------ | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `MASTER_KEY_B64`   | **yes**  | 32-byte base64 envelope key. Service exits fatally if unset. Generate with `node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"`. |
| `VERIFIER_URL`     | **yes**  | TLSN verifier service endpoint. The share service makes a single HTTP call here per share verify.                                                       |
| `PORTAL_BASE_URL`  | **yes**  | Origin of the recipient frontend (`web_portal`). Share URLs minted by `/shares` point here.                                                              |
| `PORT`             | no       | Default `8080`. On Fly.io the platform injects this.                                                                                                    |
| `DATA_DIR`         | no       | Where the FileStore writes state. Default `<share_service>/data` locally, `/data` on Fly.io.                                                            |

Everything else (CORS allow-origin, body size cap, rate-limit window,
verifier timeout, owner header name, etc.) is hardcoded to sensible
production defaults in `src/server.js`. CORS is open (`*`) by design —
the recipient portal needs to fetch from any browser origin, and writes
are gated by the `x-owner-id` header which must be set by an upstream
authenticator.

## Run locally

```bash
cd share_service
cp .env.example .env
# Fill in MASTER_KEY_B64, VERIFIER_URL, PORTAL_BASE_URL.
node src/server.js
# zk_backpack share service listening on http://0.0.0.0:8080
```

The TLSN verifier must be reachable at `VERIFIER_URL` and the
`web_portal` must be reachable at `PORTAL_BASE_URL` for end-to-end
flows. See the [project README](../README.md) for the full
local-development bring-up.

## Deploy to Fly.io

Three commands once you have `flyctl` installed
(`brew install flyctl` on macOS) and you're signed in (`flyctl auth login`).

> The repo root is `zk_backpack/`. The Fly app config and Dockerfile
> live inside `share_service/`. Run all `fly` commands from
> `zk_backpack/share_service/`.

### 1. First-time setup

```bash
cd share_service

# Create the app (reads fly.toml; pick a unique slug; pick the region
# closest to your users — `flyctl platform regions` lists them).
flyctl launch --no-deploy --copy-config

# Create the persistent volume that backs /data (1 GB is far more than
# you need for the demo; raise as needed).
flyctl volumes create share_service_data --size 1 --region iad

# Set the three required secrets. They're encrypted at rest in Fly's
# control plane and surface to the VM as environment variables.
flyctl secrets set \
  MASTER_KEY_B64="$(node -e "console.log(require('crypto').randomBytes(32).toString('base64'))")" \
  VERIFIER_URL="https://mpc-verifier.burnt.com" \
  PORTAL_BASE_URL="https://your-portal.example.com"
```

### 2. Deploy

```bash
flyctl deploy
```

Fly builds the `Dockerfile`, pushes the image, attaches the volume
to `/data`, and runs `node src/server.js` on the `shared-cpu-1x` /
256 MB free-tier VM declared in `fly.toml`.

### 3. Verify

```bash
flyctl status                                        # machine state
curl https://<your-app>.fly.dev/health               # → {"status":"ok"}
flyctl logs                                          # tail server logs
```

### Updating

```bash
git push                                             # to your branch
flyctl deploy                                        # rebuild + roll out
```

Fly does zero-downtime rolling deploys by default for the `[http_service]`
process type.

### Rotating secrets

```bash
flyctl secrets set MASTER_KEY_B64="$(…)"             # triggers a redeploy
```

> Caution: rotating `MASTER_KEY_B64` invalidates every existing
> encrypted blob (the wrap layer can no longer be decrypted). For a
> demo deploy that's fine — old shares simply fail with
> `Encrypted blob missing` style errors. For real use, perform a
> background re-wrap before swapping.

### Costs on the free tier

The defaults in `fly.toml` map cleanly onto Fly's free allowance:

- 1× `shared-cpu-1x`, 256 MB → fits inside the 3 free shared VMs.
- 1 GB persistent volume → fits inside the 3 GB free volume cap.
- HTTPS + global Anycast routing → no extra cost.

No credit card is required during signup as of 2026, but Fly will hold
a card on file once you deploy. Stay within the free allowance and the
monthly bill is $0.

## Why no `node_modules`?

The whole service is built on Node's standard library: `http`,
`crypto`, `fs/promises`, and `fetch` (native since Node 18). Skipping
a package manager means:

- The Dockerfile is ~10 lines and builds in seconds.
- No supply-chain risk from transitive deps.
- The service is trivially auditable end-to-end — the entire HTTP
  surface lives in ~600 lines of `src/server.js`.

If you later need a dependency, drop a `package-lock.json` next to
`package.json` and add a `RUN npm ci --omit=dev` step to the
Dockerfile.

## Security posture

The service ships with the following controls baked in (no env knobs):

- **Fail-closed master key.** Process exits fatally if
  `MASTER_KEY_B64` is missing.
- **Body cap.** 2 MiB per request, streamed and aborted as soon as
  the cap is crossed.
- **Per-IP rate limiting.** Rolling 60-second window, 240 req/IP.
  Bounded memory.
- **Owner identity allow-list.** `x-owner-id` must match
  `/^[A-Za-z0-9._:@-]{1,128}$/`.
- **Path-safe storage.** Share tokens and proof IDs are
  whitelist-validated *and* every blob path is re-resolved with
  `path.resolve(...).startsWith(blobDir)` — no traversal, no symlink
  escape.
- **Verifier timeout.** 15 s `AbortController` around the outbound
  TLSN call.
- **Atomic writes + per-file mutex.** `proofs.json`, `shares.json` and
  blob writes are serialised through an in-process FIFO queue and use
  `fs.rename(tmp, final)` so concurrent operations cannot corrupt
  state.
- **Open CORS.** `Access-Control-Allow-Origin: *`. The API is meant to
  be reachable from the public web; writes remain gated by the
  `x-owner-id` header.
- **Headers.** Every response sets `x-content-type-options: nosniff`
  and `referrer-policy: no-referrer`.

A deeper threat model and a longer-term TEE-hosted design live in
[`../docs/architecture.md`](../docs/architecture.md) and
[`../docs/tee_design.md`](../docs/tee_design.md).
