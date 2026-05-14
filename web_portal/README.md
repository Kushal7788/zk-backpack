# ZK Backpack Web Portal

Browser-based recipient experience for viewing shared, verified credentials without installing the mobile app.

## What it does

- Accepts a share token or full share URL.
- Calls the backend verification endpoint.
- Renders:
  - verification status (`pending`, `valid`, `invalid`, `expired`, `revoked`)
  - scoped claim payload
  - signed verification receipt
- Supports deep-link flow from `/s/{token}`.

## Tech stack

- Vue 3 (CDN runtime, no build step)
- Plain CSS
- Served by `zk_backpack/share_service` static routes

## File map

- `index.html` - app shell + Vue mount point.
- `app.js` - Vue app logic and API calls.
- `styles.css` - portal UI styling.

## API dependencies

The portal expects these endpoints from `share_service`:

- `GET /api/share/view?token=<token>`
  - Resolve token + run server-side verification + return scoped claims and receipt.
- `GET /s/{token}`
  - Serves this portal with token injected for auto-verify.

## How to run

Start the share service (which also serves this portal):

```bash
cd zk_backpack/share_service
cp .env.example .env
node src/server.js
```

Open one of:

- Manual verify mode: `http://localhost:8080/s/placeholder` (replace token in input)
- Deep-link mode: `http://localhost:8080/s/<real-token>`

## Local dev workflow

1. Update portal files under `zk_backpack/web_portal`.
2. Restart `share_service` if needed.
3. Refresh browser to test UI/API behavior.

## Demo checklist

1. Open a valid `/s/<token>` URL.
2. Show `VALID` status and scoped claims.
3. Copy and show receipt JSON.
4. Revoke token from mobile app.
5. Refresh page to show blocked/revoked status.
