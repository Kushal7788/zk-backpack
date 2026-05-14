# ZK Backpack — Flutter app

The mobile half of ZK Backpack. The app generates TLSNotary proofs through
the `mobile_proof_plugin` native core, stores them as an encrypted vault on
device, and lets the user create scoped share links — all the way down to a
single field or a zero-knowledge predicate like *"age ≥ 18"*.

## What the app does

| Tab        | Behaviour                                                                                                                                  |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| **Vault**    | Lists locally stored proofs (encrypted). Each card shows the provider, the request endpoint, and a prettified preview of revealed fields. Buttons: **Share**, **Revoke**, **Delete** (with confirmation). |
| **Generate** | Pick a provider from `assets/provider_catalog.json` and run the full TLSN flow (`MobileProofClient.attestProvider`). Live progress is streamed from the native core. The artifact is encrypted and written to the local vault. |
| **Scan**     | Paste a share link or token. The app calls `GET /api/share/view` and shows status + revealed fields + predicate outcomes. The HMAC receipt can be re-verified inline. |

Every share goes through a bottom-sheet selection step where the user picks
fields and adds predicates. Without an explicit selection no fields are
revealed — the policy is opt-in disclosure.

## Project layout

```
app/
├── lib/
│   ├── main.dart                       # all UI (single entry, Material 3)
│   └── src/
│       ├── app_config.dart             # reads .env via flutter_dotenv
│       ├── local_store.dart            # SQLite vault, AES-256-GCM, key in flutter_secure_storage
│       ├── models.dart                 # ProviderConfig, ProofRecord, ShareSelection, ShareViewResponse
│       ├── selection_evaluator.dart    # client-side preview of selection / predicates
│       ├── share_selection.dart        # data types: RevealField, RevealPredicate
│       └── share_service_client.dart   # HTTP client for share_service
├── assets/
│   ├── branding/backpack_logo.png
│   └── provider_catalog.json           # TLSN provider definitions
├── .env.example
└── pubspec.yaml
```

The `mobile_proof_plugin` Flutter plugin is referenced as a path dependency
in `pubspec.yaml`:

```yaml
mobile_proof_plugin:
  path: ../../mobile_tlsn_plugin/flutter_plugin
```

Adjust the path if you cloned the plugin elsewhere.

## Configuration

Copy `.env.example` to `.env` and fill in:

| Key                                 | Required | Notes                                                                |
| ----------------------------------- | -------- | -------------------------------------------------------------------- |
| `PROOF_VERIFIER_URL`                | yes      | TLSN/MPC verifier endpoint.                                          |
| `PROOF_TRUSTED_NOTARY_KEYS_B64`     | yes      | Base64-encoded notary public key the app will trust.                 |
| `PROOF_REQUEST_TIMEOUT_MS`          | no       | Default `300000`.                                                    |
| `PROOF_PREFER_HIGH_BANDWIDTH`       | no       | `true`/`false`.                                                      |
| `PROOF_ENABLE_LOGGING`              | no       | Keep `false` in production.                                          |
| `PROOF_INCLUDE_TELEMETRY_IN_PROOF`  | no       | Keep `false` to minimise data in the proof artifact.                 |
| `PROOF_ENFORCE_NATIVE_CORE`         | no       | Recommended `true`.                                                  |
| `ZK_BACKPACK_SHARE_SERVICE_URL`     | yes      | URL of the running `share_service`.                                  |

The `.env` file is gitignored and bundled as an asset for runtime
(`flutter_dotenv`). It must not contain anything you wouldn't ship in the
APK/IPA.

## Run

```bash
flutter pub get
flutter run -d <device-id>
```

Use `flutter devices` to list available targets. The app supports iOS,
Android, macOS, Linux, Windows, and web (subject to plugin support).

## How a proof becomes a share

1. **Generate** – `MobileProofClient.attestProvider()` opens the provider's
   login WebView, captures the target request, runs the TLSN MPC handshake
   against the verifier, and returns a `ProofArtifact`.
2. **Encrypt locally** – `SecureLocalProofStore.saveEncryptedProof()`
   wraps the artifact JSON with AES-256-GCM. The data key is generated
   once per device and persisted in `flutter_secure_storage` (Keychain
   / Keystore), never in plain SQLite.
3. **Pick what to share** – tapping *Share* opens `_ShareSelectionSheet`.
   The user chooses fields (`reveal $.responseData.name`) and/or
   predicates (`dateToYearsTillNow($.responseData.dob) >= 18`). The sheet
   shows a live, client-side preview using `selection_evaluator.dart`.
4. **Upload + mint** – the app POSTs the encrypted artifact to
   `share_service/proofs`, then mints a share with `share_service/shares`
   (carrying `policyTemplate`, `expiresInMinutes`, `oneTimeView`,
   `maxViews`, and the chosen `selection`).
5. **Display** – a dialog shows the QR (responsive to viewport width),
   the share URL, and a tap-to-copy affordance.
6. **Revoke** – the *Revoke* button on a shared proof posts to
   `/shares/{token}/revoke`. The card flips to a `revoked` pill.
7. **Delete** – the *Delete* button confirms, then removes the encrypted
   row from the local vault. Existing share links remain valid until they
   expire or are revoked — the confirmation dialog says so explicitly.

## State management

Deliberate choice: no `Provider`/`Riverpod`/`Bloc`. `_ZkBackpackHomePageState`
holds vault + scan state via `setState`, with two narrow nested
`StatefulWidget` islands (`_ShareSelectionSheet`, `_ReceiptVerifyTile`).
The app is small enough that adding a state-management library would be
ceremony, not clarity. Refactor when scale demands it.

## Theming

Material 3 with `useMaterial3: true` and a teal seed colour (`#0E7490`).
Light and dark schemes are both generated via `ColorScheme.fromSeed`; the
app follows the system colour mode (`ThemeMode.system`). Rounded corners
(20 dp), no card elevation, focus rings via `OutlineInputBorder` at 16 dp.
All snackbars are floating and pill-shaped.

## Test & verify

```bash
flutter analyze
flutter test
```

There are no integration tests today — the demo flow in
[`../docs/demo_script.md`](../docs/demo_script.md) is the manual smoke
test.

## Known limitations

- The owner header is currently hardcoded (`demo-user-kushal` in
  `main.dart`). For a multi-user build, wire this to whatever
  authentication you put in front of `share_service`.
- The provider catalog (`assets/provider_catalog.json`) is bundled at
  build time. To rotate providers you would ship an app update.
- Receipt verification calls the server's `/api/share/receipt/verify`.
  The HMAC key lives on the server; the app trusts the server's "OK"
  response. Move to Ed25519 + a publishable verifier key if you want
  recipients to verify offline.
