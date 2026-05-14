# Running `share_service` inside a TEE

The current architecture leaves a soft underbelly: the share service
holds the envelope master key, the share registry, and the audit log,
and any operator with shell access to the host can read or alter all
three. This document is the engineering plan for putting the share
service inside a Trusted Execution Environment (TEE) so that:

- The master key is **bound to attested code** running on attested
  hardware, and cannot leave that hardware unencrypted.
- The audit log is **tamper-evident** end-to-end, including against
  the operator.
- The recipient can **prove they spoke to the real service**, not a
  malicious one impersonating it, before submitting a token.
- Plain HTTP is replaced with mTLS terminated *inside* the enclave.

The mobile app, web portal, and TLSN verifier do **not** need to
change. The whole effort is concentrated in `share_service`, its
deployment topology, and how recipients can optionally verify
attestation.

## 1. Which TEE?

Three production-grade options are good fits. Pick one based on cloud
provider and threat model:

| TEE                          | Granularity            | Memory ceiling | What's measured                       | Notable for                                                |
| ---------------------------- | ---------------------- | -------------- | ------------------------------------- | ---------------------------------------------------------- |
| **Intel TDX**                | Whole VM (`TD`)        | up to TiBs     | OVMF + kernel + initramfs + cmdline   | Run an unmodified Node.js + container image inside a TDVM. Best ergonomics for a small Node service. |
| **AMD SEV-SNP**              | Whole VM               | up to TiBs     | OVMF, IDBlock, guest measurement      | Same shape as TDX, often cheaper on AWS / Azure CVM lines. |
| **AWS Nitro Enclaves**       | Sibling micro-VM       | 16 GiB        | EIF (Enclave Image File)              | Strong attestation document, ubiquitous on AWS. Requires vsock plumbing. |
| **Confidential GKE / Confidential VM (AMD SEV)** | Whole VM | up to TiBs | Same as SEV-SNP                     | Drop-in if you already run on GKE.                         |

For the reference deployment we'll describe **Intel TDX** because it
admits an essentially unmodified Node container and gives a clean
DCAP attestation, but the pattern is the same for SEV-SNP and Nitro
modulo SDK calls.

## 2. Trust boundary after TEE adoption

```
   ┌───────────────────────────────────────────────────────────────────┐
   │                       PHYSICAL HOST                                │
   │                                                                    │
   │   ┌───────────────────────────────────────────────────────────┐    │
   │   │              TRUST DOMAIN (Intel TDX)                      │    │
   │   │                                                            │    │
   │   │   ┌─────────────┐    ┌─────────────────────────────┐       │    │
   │   │   │ Quote-Gen   │◄──►│  share_service (Node.js)    │       │    │
   │   │   │   helper    │    │                              │       │    │
   │   │   └─────────────┘    │   ├─ Master key (derived from│       │    │
   │   │                      │   │   sealed KMS unwrap on   │       │    │
   │   │                      │   │   first boot)            │       │    │
   │   │                      │   ├─ FileStore (vTPM-sealed) │       │    │
   │   │                      │   └─ Audit log (hash-chained,│       │    │
   │   │                      │       periodically anchored) │       │    │
   │   │                      └─────────────────────────────┘       │    │
   │   └───────────────────────────────────────────────────────────┘    │
   │                                                                    │
   │   Hypervisor / orchestrator can schedule, snapshot, and reboot     │
   │   the TD but cannot read its memory or alter its measurement.      │
   └───────────────────────────────────────────────────────────────────┘
                  │ TLS terminated *inside* the TD
                  ▼
         clients (mobile app, web portal recipients)
                  ▲
                  │ optional attestation challenge
                  ▼
         attestation verifier (Intel PCS or Azure / GCP equivalent)
```

The operator, the hypervisor, and the cloud provider's privileged
software are now all **outside** the trust boundary. The TLSN
verifier remains its own trust domain — the share service speaks
to it over mTLS, pinning its certificate.

## 3. Key custody — the central problem

Today `share_service` reads `MASTER_KEY_B64` from `.env`. That has to
go: a file on disk an operator can read defeats the entire point of
moving into a TEE.

Adopt **enclave-anchored key release**:

1. Boot the TD. The first thing `share_service` does at startup is
   call `quote-gen` (the local TDX attestation helper) to obtain a
   quote over a fresh `nonce + ephemeral X25519 public key`.
2. Send the quote + ephemeral public key to a **Key Broker Service
   (KBS)** — either Intel's TDX Attestation Service, Microsoft Azure
   Attestation, GCP Confidential Space Attestation, or a self-hosted
   KBS (e.g. CoCo, kbs-rs).
3. The KBS verifies the quote against:
   - the TDX TCB endorsements (CPU + firmware version),
   - the expected `MRTD` (measurement of TD's initial state — your
     image hash),
   - the expected `RTMR` registers (PCRs equivalent — kernel
     command-line, initrd, etc.).
4. If the measurement matches a pre-registered policy
   ("share_service v1.4.0, kernel 6.x, image hash …"), the KBS
   returns the master key wrapped to the ephemeral public key.
5. The TD unwraps in memory and **never** writes the key to disk.

Result: only an exact, attested build of `share_service` can fetch
the master key. Operators who tamper with the image (swap in a
malicious version, downgrade the kernel, etc.) get a measurement
mismatch and the KBS refuses to release the key.

### Rotation

The master key is recoverable after a restart because the KBS will
re-release it to any TD whose measurement still matches. To rotate:

1. Build a new image of `share_service` that, on boot, also asks the
   KBS for `next-master-key`.
2. Re-encrypt every entry in `proof_blobs/` with the new key
   (background job; envelope encryption makes this cheap — re-wrap
   the per-proof DEK, not the artifact).
3. Atomically swap `current-master-key` ← `next-master-key` in the
   KBS policy.

The CPU never sees the plaintext key during transport. Cloud
providers' KBS implementations support this without bespoke code.

## 4. Sealed persistence

The TD memory is private but not durable — a reboot wipes it. To
persist proof blobs and the share registry without re-introducing a
plaintext disk footprint, encrypt every byte under a **sealing key**
that is itself derived from the TD's measurement:

- `seal_key = HKDF(KBS-released-seal-secret, "share-service.seal/v1", measurement)`
- Encrypt `data/*.json` and `data/proof_blobs/*.json` at the
  filesystem layer (`fscrypt` with this seal key, or a userspace
  wrapper writing AES-256-GCM ciphertext to the host filesystem).

The host operator can copy the files anywhere; without the same
attested TD they're opaque ciphertext.

Variants:

- **`fscrypt` per directory** on a TDX VM with a sealed-secret
  initramfs hook. Linearisable, cheap, no app changes.
- **`io_uring` userspace wrapper** that intercepts all reads/writes
  from `share_service/src/store.js`. More portable, more code.
- **vTPM-sealed Nitro EBS layer** if you go Nitro Enclaves — Nitro
  exposes vsock, which makes this trickier but doable with a parent
  EC2 broker that holds the sealed key.

Today's atomic `writeJson(tmp); rename(tmp, final)` already gives us
crash-safe semantics; adding `fscrypt` on top is invisible to the
application.

## 5. Audit log — externally verifiable

`data/audit.jsonl` becomes a hash-chained log:

```
entry_i = {
  at: ISO-8601,
  type: "share_verified" | …,
  …,
  prevHash: SHA-256(entry_{i-1}),
  hash:     SHA-256(canonical(entry_i \\ {hash}))
}
```

Every N minutes (or every N entries) the TD computes the current
`tipHash` and:

1. Signs it with an **enclave attestation key** derived inside the
   TD.
2. Anchors it externally — options:
   - publish to a Sigstore Rekor instance,
   - post to a permissioned transparency log (e.g. trillian),
   - publish a periodic checkpoint via a publicly readable bucket
     plus DNS TXT record.

An auditor (legal, compliance, or the user themself) reads
`tipHash + signature`, fetches the chain since the previous
checkpoint, and replays it. Any rollback, truncation, or insertion
breaks the chain hash and the auditor sees it. The operator cannot
silently delete a `share_revoked` event.

The hash-chain code lives entirely in `store.js`:

```js
// Pseudocode for share_service/src/store.js
async appendAudit(event) {
  const prevHash = await this.tipHash();        // sealed file or in-memory cache
  const enriched = { ...event, prevHash };
  enriched.hash = sha256Canonical(enriched);
  await fs.appendFile(this.auditPath, JSON.stringify(enriched) + '\n');
  this.cacheTip(enriched.hash);
}
```

## 6. Network — terminate TLS inside the TD

Today `share_service` speaks plain HTTP. Inside a TEE we want to
move TLS termination *into* the trust boundary so the operator's
sidecar proxy isn't in a position to MITM clients.

Use Node's built-in `https.createServer`. The cert + key pair are
fetched from the same KBS at boot:

- KBS holds `{tlsCert, tlsKey}` wrapped to the TD's ephemeral pubkey.
- TD unwraps in memory; passes both to `https.createServer`.
- Rotation is the same shape as master-key rotation.

For attested HTTPS, the recipient browser does the normal CA check
*and* the share service exposes:

```
GET /.well-known/zk-backpack/attestation
→ {
  "tdReport":   "<base64>",
  "quote":      "<base64 DCAP quote>",
  "issuedAt":   "2026-05-14T18:35:21.012Z",
  "measurement": { "MRTD": "…", "RTMR0": "…", "RTMR1": "…" }
}
```

The mobile app and the optional desktop verifier ("show me the proof
this server is real") can fetch this endpoint, verify the quote
against the published Intel root, and refuse to upload proofs to a
mismeasured deployment. Browsers don't natively do this — but the
mobile app, which writes the keys it's about to ship secrets to,
absolutely can.

## 7. Receipt signing — Ed25519 + published JWKS

While we're rebuilding key custody, swap the receipt signature from
HMAC-SHA256 (which forces the recipient to re-call the server to
re-verify) to **Ed25519**:

- Signing key (Ed25519 private) sealed inside the TD just like the
  master key.
- Verification key (Ed25519 public) published at
  `GET /.well-known/zk-backpack.jwks` and pinned in the mobile app.
- Recipients can verify the receipt fully offline. The portal still
  offers a one-click verify button but it's a courtesy, not a
  requirement.

The receipt itself stays the same JWT-shaped object; only `alg`
changes from `HS256` to `EdDSA`.

## 8. Putting it together — boot sequence

```
1. orchestrator boots the TDX VM with image hash X
2. share_service starts:
     a. asks quote-gen for a quote over (nonce + ephemeral X25519 pub)
     b. POSTs quote to KBS, KBS attests, returns wrapped secrets:
          - master encryption key
          - filesystem seal secret
          - TLS cert + key
          - Ed25519 signing key
          - audit-log anchor key
     c. unwraps every secret in memory
3. share_service mounts data/ under fscrypt with the seal secret
4. share_service starts https.createServer on :8443 with the TLS pair
5. share_service exposes /.well-known/zk-backpack/attestation
6. mobile app, before uploading any proof, optionally fetches the
   attestation, verifies the quote, and pins the TLS cert observed
   during the handshake against the one bound to the quote
7. normal operation continues
```

A misbehaving operator who hot-patches Node, tampers with the
filesystem, or swaps the image will see the KBS refuse step 2 and
the service will fail to start with `attestation rejected`.

## 9. What stays the same

- The mobile app's vault encryption (already device-side).
- The TLSN verifier service (a separate trust domain).
- The web portal HTML/JS (no changes — it speaks to the share
  service over HTTPS like any other origin).
- The selection grammar and predicate evaluator.
- Existing share tokens stay opaque base64url strings; recipients see
  the same URL shape.

## 10. Migration path

You don't have to switch to a TEE in one shot. A staged path that
keeps the demo bootable at every step:

1. **Move secrets out of `.env`.** Read `MASTER_KEY_B64`, TLS cert
   and Ed25519 key from a cloud KMS (AWS KMS, GCP KMS, HashiCorp
   Vault). This is a one-day refactor on top of `crypto.js`.
2. **Switch receipts to Ed25519** and publish JWKS. Mobile app
   verifies offline; portal optionally calls back.
3. **Add the hash-chained audit log** and an external checkpoint
   publisher (Rekor or a signed S3 object).
4. **Containerise + reproducible builds.** Lock the Node version,
   pin `package.json` (still no deps today — keep it that way).
5. **Lift into TDX / SEV-SNP** with a confidential VM image and a
   KBS releasing the secrets used in steps 1–3.
6. **Drop step 1's plaintext-after-unseal path** — secrets only
   live in TD memory.
7. **Publish `/.well-known/zk-backpack/attestation`** and teach the
   mobile app to pin against it.

After step 7 the share service has the security posture this
document promised: integrity tied to attested code, audit log
tamper-evident, recipients can verify offline, and the worst the
operator can do is deny service.

## 11. References

- Intel TDX module spec — <https://www.intel.com/content/www/us/en/developer/articles/technical/intel-trust-domain-extensions.html>
- Confidential Containers (CoCo) — <https://confidentialcontainers.org>
- AWS Nitro Enclaves attestation document — <https://docs.aws.amazon.com/enclaves/latest/user/nitro-enclave-attestation-process.html>
- TPM-style measurement chain in TDX — RTMR registers, see TDX module ABI.
- IETF RATS architecture (RFC 9334) for general attestation vocabulary.
