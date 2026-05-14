# ZK Backpack Share Service

Node.js API for encrypted proof storage, share-token lifecycle, and web recipient verification.

## Run

```bash
cp .env.example .env
node src/server.js
```

## Security Controls

- Encrypted proof blobs at rest.
- Token-based share links with expiry/revocation.
- Server-side verification using `mobile_tlsn_verifier_service`.
- Signed verification receipt for audit.
- Append-only audit log at `data/audit.jsonl`.
