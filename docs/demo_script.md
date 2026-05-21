# 3-Minute Demo Script

Goal: show ZK Backpack as a useful private data product, not just a proof
generator. The demo should make three ideas obvious:

- Verified web data lands in a user-owned vault.
- The user releases only selected facts.
- Access can be bounded and revoked.

## Setup Before Judges

- Have `share_service`, `web_portal`, and the TLSN verifier running.
- Keep at least one proof already generated in Vault in case live proof
  generation is slow.
- Prefer an Aadhaar or Gusto proof if available:
  - Aadhaar: best for an age-gate predicate.
  - Gusto: best for employment proof.
- Have a browser window ready for the recipient portal.

## Main Flow: Private Fact Share (2 min)

1. Open the Flutter app on **Vault**.
2. Point out the Proof Passport grouping:
   - Identity
   - Work
   - Money
   - Travel
   - Reputation
3. Say:

   > Each card is a proof from a real web source, stored locally first. The
   > backpack is useful because I can reuse these proofs without handing over
   > my account or a full document.

4. Open an existing proof card and show the lifecycle row:
   - Local
   - Uploaded
   - Shared
   - Revoked
5. Tap **Share**.
6. Choose a proof recipe:
   - **Prove I am 21+** for Aadhaar, or
   - **Prove employment** for Gusto.
7. Show that the recipe prefilled fields or predicates, then say:

   > The recipe is just a safe preset. I can still inspect and change exactly
   > what leaves my backpack.

8. Select the **One-time** share policy.
9. Tap **Share QR**.
10. Show the QR dialog policy summary:
    - One-time link
    - Up to 1 view
    - Expiry time
11. Open the link in the recipient browser.
12. On the portal, point to **Verification summary**:
    - Server-verified TLSNotary proof
    - Source host
    - Released claim count
    - Conditions met
    - Share policy
    - Receipt/artifact hash
13. Show the revealed information and conditions.
14. Say:

    > The verifier gets the fact they need, plus cryptographic evidence. They
    > do not get my login, the raw proof, or unrelated account data.

## Failure/Control Moment (45 sec)

1. Refresh the same recipient portal link.
2. The one-time link should now show the consumed/blocked state.
3. Say:

   > This is what makes it feel like a private product rather than a static
   > screenshot. The user controls disclosure and the share policy.

4. If you also have another active reusable share, revoke it from the app and
   refresh that portal page to show the revoked state.

## Closing Pitch (15 sec)

Say:

> ZK Backpack turns web accounts into reusable private credentials. A user can
> collect proofs from many sources, keep them in a local encrypted backpack,
> and reveal only the fact a verifier needs.

## Fallback Flow If Live Generation Is Slow

Use this if provider login or proof generation would take too long.

1. Skip live proof generation.
2. Start from an already generated Vault proof.
3. Say:

   > Proof generation is the expensive cryptographic step. For the judge demo,
   > I am using a proof already generated on this phone so we can focus on the
   > product loop.

4. Continue with recipe selection, one-time share, portal verification, refresh
   consumed state, and revoke.

## Optional Fresh Proof Moment

Use this only if time is safe.

1. Go to **Generate**.
2. Show providers grouped by category.
3. Select one provider row.
4. Tap **Generate Proof**.
5. Return to Vault when complete.

Keep this short. The winning story is the backpack and selective sharing, not
waiting on a login flow.

## Judge Callouts

- **Useful today:** age gates, hiring, payroll/income prechecks, account
  ownership, marketplace trust, reputation proofs.
- **Privacy:** recipient sees selected fields and predicates, not the whole
  account payload.
- **Control:** one-time links, expiry, max views, and revocation make proof
  sharing feel user-owned.
- **Trust:** portal verifies the TLSNotary proof server-side before rendering
  claims.
- **Whitepaper tie:** this is a concrete mobile edge for verified-data
  ingestion, private storage, selective disclosure, and predicate access.

## Claims To Avoid During Demo

- Do not claim the whole app is production-ready security.
- Do not claim every disclosure is fully zero-knowledge. Say exact fields are
  selective disclosure and predicates prove conditions without revealing the
  source value.
- Do not claim offline receipt verification yet; current receipt verification
  still calls the service.
- Do not claim full on-chain data-layer, IBE, UCAN, or TEE implementation.
