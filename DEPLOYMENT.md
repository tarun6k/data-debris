# Deployment

How Data Debris gets from this repo to a user's Mac. Two independently deployed pieces:

1. **The app** — signed, notarized, stapled DMG, updated via Sparkle.
2. **The license service** — a Cloudflare Worker that turns Paddle webhooks into
   Ed25519-signed licenses.

> **Status.** The app is not yet signed, notarized or shipping updates — that is Phase 8,
> and the sections marked *(Phase 8 — not yet implemented)* describe the intended process
> rather than scripts that exist today. The license worker is implemented and tested, but
> has never been deployed: both `wrangler.toml` environments still carry
> `TODO-wrangler-kv-namespace-create` KV ids.

---

## Secrets — read this first

Never commit a real secret, and never paste one into a prompt or an issue.

| Where | Holds |
|---|---|
| `.env` (repo root, gitignored) | Paddle config for local Debug builds |
| `services/license-worker/.dev.vars` (gitignored) | same values for `wrangler dev` |
| `wrangler secret put` | the deployed worker's secrets, per environment |
| Keychain / CI secrets | signing identity, notarization and Sparkle keys |

[`.env.example`](.env.example) lists every variable name with empty values. Copy it to
`.env` and fill it in; `.gitignore` covers `.env`, `.env.*` (except `.env.example`) and
`.dev.vars`.

The Ed25519 **private** signing key exists only in `.dev.vars` and Cloudflare secrets. Its
public half is committed on purpose, as `LicensePublicKey.production` in
`Sources/DebrisCore/Licensing/Entitlement.swift` — only the worker holds the private half,
so a valid signature proves an entitlement came from the service. **If you rotate the
signing key, every previously issued entitlement stops verifying**, so ship the new public
key in an app update before switching the worker over.

---

## Part 1 — The license service

### First deploy, per environment

Run from `services/license-worker/`. Do `sandbox` first and exercise a full purchase against
Paddle Sandbox before going near `production`.

**1. Create the KV namespace** and paste the returned id into the matching
`[env.*]` block in `wrangler.toml`, replacing `TODO-wrangler-kv-namespace-create`:

```sh
npx wrangler kv namespace create LICENSES --env sandbox
```

**2. Generate the signing keypair** (once per environment):

```sh
node -e '
const { generateKeyPairSync } = require("node:crypto");
const { publicKey, privateKey } = generateKeyPairSync("ed25519");
console.log("LICENSE_SIGNING_KEY=" + privateKey.export({ type: "pkcs8", format: "der" }).toString("base64"));
console.log("PUBLIC(raw b64) =", publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("base64"));'
```

Put the private half in the worker's secrets (next step). Put the printed public value into
`LicensePublicKey.production` in the app. Do not echo the private key anywhere else.

**3. Set the secrets** — each prompts for a value, none are stored in the repo:

```sh
for name in PADDLE_API_KEY PADDLE_WEBHOOK_SECRET \
            PADDLE_PRICE_1Y_RECURRING PADDLE_PRICE_1Y_ONETIME \
            PADDLE_PRICE_3Y_RECURRING PADDLE_PRICE_3Y_ONETIME \
            LICENSE_SIGNING_KEY RESEND_API_KEY; do
  npx wrangler secret put "$name" --env sandbox
done
```

Non-secret vars (`PADDLE_ENV`, `EMAIL_FROM`) live in `wrangler.toml`.

**4. Deploy:**

```sh
npm test                          # 24 tests, must be green
npm run typecheck
npx wrangler deploy --env sandbox
curl https://<worker-host>/healthz    # expects {"ok":true}
```

**5. Point Paddle at it.** In the Paddle dashboard create a notification destination at
`https://<worker-host>/webhook/paddle` subscribed to `transaction.completed` and
`subscription.*`, and copy its signing secret into `PADDLE_WEBHOOK_SECRET`. The four price
ids from the dashboard select plan, term and auto-renew.

### Routine deploys

```sh
npm test && npm run typecheck && npx wrangler deploy --env production
```

The worker is the payment path: a bad deploy stops purchases and activations. Deploy to
`sandbox` first, verify `/healthz` and one activation, then promote.

### Rollback

```sh
npx wrangler rollback --env production
```

KV data is not rolled back. Schema changes must stay backward compatible with entitlements
already issued — the key layout is documented at the top of `src/store.ts`.

---

## Part 2 — The app *(Phase 8 — not yet implemented)*

### Prerequisites

- Apple Developer Program membership; a **Developer ID Application** certificate.
- An app-specific password or App Store Connect API key for `notarytool`.
- A Sparkle EdDSA keypair (`generate_keys` from the Sparkle distribution). The private key
  belongs in the Keychain, never the repo.

Development builds sign to run locally (`CODE_SIGN_IDENTITY = "-"`, no team) — see
`project.yml`. Release signing must not be committed into `project.yml`; pass it at archive
time.

### Release checklist

1. `make test` — 116 core + 45 app tests green. This is the gate; the safety invariants
   S1–S10 are what these tests protect.
2. Bump the version, and write the "What's new" entries. Any **new catalogue rule must ship
   unticked for Auto Clean** (S9) and be announced in the What's new sheet.
3. Confirm updates change neither the user's Auto Clean selection nor their exclusions.
4. Inject release config (`LICENSE_WORKER_URL`, `PADDLE_CLIENT_TOKEN`, `PADDLE_ENV`,
   the four `PADDLE_PRICE_*`) as Info.plist keys at archive time — release builds read
   Info.plist, Debug builds read `.env`. Point `PADDLE_ENV` at `production`.
5. Archive a **universal** binary (arm64 + x86_64), Hardened Runtime on, App Sandbox off.
6. Sign, notarize, staple:

   ```sh
   xcrun notarytool submit DataDebris.dmg --keychain-profile "<profile>" --wait
   xcrun stapler staple DataDebris.dmg
   spctl -a -vvv -t install DataDebris.app    # expect "accepted / Developer ID"
   ```

7. Build the DMG with a "drag to Applications" layout.
8. Sign the appcast with the Sparkle EdDSA key and publish it to
   `updates.datadebris.app` — this host is hard-coded as `LicenseConfig.updateHost` because
   the Privacy & Security sheet promises it is one of only two hosts the app ever contacts.
   Changing it would break that promise and its text hash.

### Verifying a release

On a clean Mac (or a fresh user account):

- Gatekeeper opens the app with no warning; it prompts to move itself to `/Applications`.
- A scan reports sensible numbers and **no** protected path appears as removable.
- Clean → Undo round-trips: files return to their original paths.
- Purchase against Paddle Sandbox issues a key; activate on two Macs, and confirm a third
  is refused with `activation_limit`.
- Sparkle offers the update, and applying it preserves Auto Clean selections and exclusions.

---

## The two network hosts

The Privacy & Security sheet promises the app contacts only:

| Host | Purpose |
|---|---|
| `updates.datadebris.app` | Sparkle appcast |
| the license worker host | activate / validate / deactivate / recover |

Scanning is entirely local; no file names, paths, contents or results ever leave the
machine. Adding a third host means changing that sheet and its acknowledgement hash — treat
it as a product decision, not a deployment detail.
