import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";
import { generateKeyPairSync } from "node:crypto";

// Fresh Ed25519 keypair per test run; nothing key-like is committed. The raw
// 32-byte public key is handed to tests via TEST_PUBLIC_KEY so they can verify
// entitlement signatures the way the app does.
const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const privatePkcs8B64 = privateKey.export({ type: "pkcs8", format: "der" }).toString("base64");
const publicRawB64 = publicKey
  .export({ type: "spki", format: "der" })
  .subarray(-32)
  .toString("base64");

export default defineWorkersConfig({
  test: {
    poolOptions: {
      workers: {
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: {
          bindings: {
            // Fixture values; chosen to not collide with real Paddle prefixes.
            PADDLE_ENV: "sandbox",
            PADDLE_API_KEY: "fixture-paddle-api-key",
            PADDLE_WEBHOOK_SECRET: "fixture-webhook-secret",
            PADDLE_PRICE_1Y_RECURRING: "price-1y-recurring",
            PADDLE_PRICE_1Y_ONETIME: "price-1y-onetime",
            PADDLE_PRICE_3Y_RECURRING: "price-3y-recurring",
            PADDLE_PRICE_3Y_ONETIME: "price-3y-onetime",
            LICENSE_SIGNING_KEY: privatePkcs8B64,
            RESEND_API_KEY: "fixture-resend-key",
            TEST_PUBLIC_KEY: publicRawB64,
          },
        },
      },
    },
  },
});
