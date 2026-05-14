# ZK Backpack — web portal

A no-install, browser-only viewer for a shared ZK Backpack credential.
Open the link in any browser and you see what the proof says — nothing
more, nothing less. The portal never holds the raw proof or notary
signature; the `share_service` API does the verification and returns
scoped claims plus a signed receipt.

The portal runs as its **own service** on its own port. The
`share_service` no longer serves portal HTML — it's purely the API + data
layer. Mobile-app QR codes encode the portal URL; the portal's JavaScript
then calls back into the `share_service` API across origins.

```
        recipient                                  owner
            ▼                                        ▼
   ┌────────────────────┐                ┌─────────────────────┐
   │  web_portal :8081  │ ── /api ──►    │  share_service :8080│
   │  (this service)    │                │  (CORS-enabled API) │
   └────────────────────┘                └─────────────────────┘
```

## What it does

- Accepts a share token, a `/s/<token>` URL, or a paste-in value.
- Calls `GET {SHARE_SERVICE_URL}/api/share/view` for the verification
  status, scoped claims, and signed receipt.
- Renders verification states: `verified`, `inconclusive`, `expired`,
  `revoked`, `consumed`, `max views reached`.
- Surfaces revealed fields and predicate outcomes.
- One-click receipt signature re-verification via
  `POST {SHARE_SERVICE_URL}/api/share/receipt/verify`.

## File map

```
web_portal/
├── package.json         # ESM, "start": "node server.js"
├── server.js            # standalone HTTP server (no deps)
├── index.html           # Vue 3 mount point, runtime config injection
├── app.js               # Vue setup, cross-origin fetch, rendering
├── styles.css           # light + dark via prefers-color-scheme
└── .env.example
```

No build step. The portal stays auditable as three small files that go
on the wire as-is.

## Configuration

| Key                  | Required | Notes                                                                              |
| -------------------- | -------- | ---------------------------------------------------------------------------------- |
| `PORT`               | no       | Default `8081`.                                                                    |
| `HOST`               | no       | Default `0.0.0.0`.                                                                 |
| `BASE_URL`           | no       | Default `http://localhost:8081`. Used by the server to resolve relative URLs.      |
| `SHARE_SERVICE_URL`  | **yes**  | Where the portal's frontend will `fetch` the API. The portal injects this into the page at render time. Set it to whatever URL is reachable from the *recipient's* device. |

## Run

```bash
cd web_portal
cp .env.example .env
node server.js
# zk_backpack web portal listening on http://localhost:8081
#   -> share_service at http://localhost:8080
```

Then start the share service alongside it:

```bash
cd ../share_service
node src/server.js
```

You'll need both running, plus the TLSN verifier — the portal is just
the recipient view.

## Cross-origin behaviour

Because the portal and the share service now live on different origins,
fetches from the portal go through CORS preflight. The share service
ships with `CORS_ALLOWED_ORIGIN=*` by default; lock it down to the
exact portal origin in production. See
`../share_service/.env.example`.

## Mobile + LAN access

If you're scanning the QR with a real phone, both services must be on
URLs the phone can reach. Use the dev-machine's LAN IP, not `localhost`:

```env
# web_portal/.env
BASE_URL=http://192.168.1.42:8081
SHARE_SERVICE_URL=http://192.168.1.42:8080

# share_service/.env
PORTAL_BASE_URL=http://192.168.1.42:8081
BASE_URL=http://192.168.1.42:8080
```

Restart both services after changing those.

## How it renders claims safely

- All values go through Vue interpolation (`{{ … }}`) — never `v-html`
  for untrusted data — so hostile field values render as text, not
  markup.
- Only a small set of trusted inline SVGs are rendered via `v-html`.
- `prettifyKey()` strips JSONPath prefixes and humanises camelCase.
- `humanizeDateLike()` detects ISO-8601 strings and shows them via the
  recipient's locale.
- The server-rendered `/s/<token>` and `SHARE_SERVICE_BASE` placeholders
  are HTML-escaped before they reach the page, and the response carries
  a strict `Content-Security-Policy` plus `x-frame-options: DENY`.
- The `connect-src` directive in CSP is built dynamically from
  `SHARE_SERVICE_URL` so the portal can only reach the configured API
  origin.

## Demo checklist

1. Mint a share in the mobile app → the QR encodes
   `http://<portal-host>:8081/s/<token>`.
2. Open the link in any browser → status flips to **Verified**, scoped
   claims appear, predicates show ✓/✗.
3. Hit *Verify signature* → pill turns green: `Signature OK`.
4. Switch the OS to dark mode → portal flips to a deep, low-contrast
   palette without a page reload.
5. Revoke the share from the mobile app and refresh → status flips to
   **Revoked**.
