# Data Debris license service

One Cloudflare Worker that turns Paddle Billing webhooks into Ed25519-signed
licenses and answers activate / validate / deactivate with a 2-Mac limit.
Storage is a single Workers KV namespace (`LICENSES`); the key layout is
documented at the top of `src/store.ts`.

## Endpoints

| Method | Path | Body | Success | Errors |
|---|---|---|---|---|
| POST | `/webhook/paddle` | raw Paddle event | `{ ok }` | 400 bad signature |
| GET | `/license/by-reference/:ref` | — | `{ key }` | 404 until the webhook lands |
| POST | `/activate` | `{ key, machineId, machineName }` | `{ entitlement }` | 404 `unknown_key`, 402 `inactive`, 409 `activation_limit` |
| POST | `/validate` | `{ key, machineId }` | `{ entitlement }` | 404 `unknown_key`, 402 `inactive` (refunded) |
| POST | `/deactivate` | `{ key, machineId }` | `{ ok }` | — (idempotent) |
| POST | `/recover` | `{ email }` | `{ ok }` | — (always 200) |
| GET | `/healthz` | — | `{ ok }` | — |

Client endpoints are rate-limited to 30/min per IP. `entitlement` is
`base64url(payload JSON) + "." + base64url(Ed25519 signature)`; the payload is
`{ key, plan, expiresAt, status, autoRenew, machines, issuedAt, machineId }`
with dates as Unix epoch seconds. The app verifies the signature with the
bundled public key before trusting any field.

## Local development

```sh
npm install
npm test            # vitest, runs inside workerd via @cloudflare/vitest-pool-workers
npm run dev         # wrangler dev with local KV; reads .dev.vars
```

`wrangler dev` reads secrets from `.dev.vars` (gitignored). Copy the values
from the repo-root `.env` — same variable names — plus the two worker-only
ones below.

## Secrets — never in this repo

Set for each environment with `wrangler secret put <NAME> --env sandbox|production`:

- `PADDLE_API_KEY` — Paddle API key (used to look up the buyer's email).
- `PADDLE_WEBHOOK_SECRET` — from the Paddle notification destination.
- `PADDLE_PRICE_1Y_RECURRING`, `PADDLE_PRICE_1Y_ONETIME`,
  `PADDLE_PRICE_3Y_RECURRING`, `PADDLE_PRICE_3Y_ONETIME` — price IDs from the
  Paddle dashboard; they select plan, term and auto-renew.
- `LICENSE_SIGNING_KEY` — Ed25519 private key, PKCS8 DER, base64. Generate a
  pair (the raw 32-byte public key goes into the app as a constant):

  ```sh
  node -e '
  const { generateKeyPairSync } = require("node:crypto");
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  console.log("LICENSE_SIGNING_KEY=" + privateKey.export({ type: "pkcs8", format: "der" }).toString("base64"));
  console.log("PUBLIC(raw b64) =", publicKey.export({ type: "spki", format: "der" }).subarray(-32).toString("base64"));'
  ```

- `RESEND_API_KEY` — transactional email (license delivery and recovery).

Non-secret vars (`PADDLE_ENV`, `EMAIL_FROM`) live in `wrangler.toml`. Before
the first deploy, create the KV namespace per environment with
`wrangler kv namespace create LICENSES --env …` and replace the TODO ids.
Deployment itself is a later phase; do not deploy from here.
