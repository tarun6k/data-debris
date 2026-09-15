#!/usr/bin/env node
// Live-test helper: Paddle's sandbox cannot reach a wrangler-dev worker on
// 127.0.0.1, so this stands in for the notification delivery. It signs a
// transaction.completed event exactly like Paddle does (HMAC of "ts:body"
// with the webhook secret from .dev.vars — read in-process, never printed)
// and POSTs it to the local worker.
//
//   node scripts/simulate-checkout.mjs <reference> [machineId] [priceVar]
//
// priceVar defaults to PADDLE_PRICE_1Y_ONETIME.

import { createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const [reference, machineId, priceVar = "PADDLE_PRICE_1Y_ONETIME"] = process.argv.slice(2);
if (!reference) {
  console.error("usage: simulate-checkout.mjs <reference> [machineId] [priceVar]");
  process.exit(1);
}

const vars = Object.fromEntries(
  readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", ".dev.vars"), "utf8")
    .split("\n")
    .filter((l) => l.includes("=") && !l.startsWith("#"))
    .map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1).trim()]),
);
const secret = vars.PADDLE_WEBHOOK_SECRET;
const priceId = vars[priceVar];
if (!secret || !priceId) {
  console.error(`missing PADDLE_WEBHOOK_SECRET or ${priceVar} in .dev.vars`);
  process.exit(1);
}

const body = JSON.stringify({
  event_id: `evt-sim-${Date.now()}`,
  event_type: "transaction.completed",
  data: {
    id: `txn-sim-${Date.now()}`,
    customer_id: "ctm-sim",
    subscription_id: priceVar.endsWith("RECURRING") ? `sub-sim-${Date.now()}` : null,
    custom_data: { reference, ...(machineId ? { machineId } : {}) },
    items: [{ price: { id: priceId } }],
  },
});

const ts = Math.floor(Date.now() / 1000);
const h1 = createHmac("sha256", secret).update(`${ts}:${body}`).digest("hex");

const res = await fetch("http://127.0.0.1:8787/webhook/paddle", {
  method: "POST",
  headers: { "Content-Type": "application/json", "Paddle-Signature": `ts=${ts};h1=${h1}` },
  body,
});
console.log("webhook:", res.status, await res.text());

const byRef = await fetch(`http://127.0.0.1:8787/license/by-reference/${reference}`);
console.log("by-reference:", byRef.status, await byRef.text());
