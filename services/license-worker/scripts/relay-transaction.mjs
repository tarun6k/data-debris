#!/usr/bin/env node
// Live-test helper for a REAL sandbox checkout: Paddle cannot deliver
// notifications to a wrangler-dev worker on 127.0.0.1, so this plays the
// courier. It polls the Paddle sandbox API (PADDLE_API_KEY from .dev.vars,
// read in-process, never printed) for the completed transaction whose
// custom_data.reference matches, wraps the real transaction in a
// transaction.completed event, signs it like Paddle does (HMAC of "ts:body"
// with PADDLE_WEBHOOK_SECRET) and POSTs it to the local worker.
//
//   node scripts/relay-transaction.mjs <reference> [--wait <seconds>]
//
// Prints the transaction id, customer id, which price variable matched, the
// worker's reply and the by-reference lookup with the key cut to its last 4.

import { createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
const reference = args[0];
const waitIndex = args.indexOf("--wait");
const waitSeconds = waitIndex >= 0 ? Number(args[waitIndex + 1]) : 0;
if (!reference || Number.isNaN(waitSeconds)) {
  console.error("usage: relay-transaction.mjs <reference> [--wait <seconds>]");
  process.exit(1);
}

const vars = Object.fromEntries(
  readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", ".dev.vars"), "utf8")
    .split("\n")
    .filter((l) => l.includes("=") && !l.startsWith("#"))
    .map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1).trim()]),
);
const apiKey = vars.PADDLE_API_KEY;
const secret = vars.PADDLE_WEBHOOK_SECRET;
if (!apiKey || !secret) {
  console.error("missing PADDLE_API_KEY or PADDLE_WEBHOOK_SECRET in .dev.vars");
  process.exit(1);
}
const priceVars = Object.entries(vars).filter(([k]) => k.startsWith("PADDLE_PRICE_"));

const stamp = () => new Date().toTimeString().slice(0, 8);

async function findTransaction() {
  const url = "https://sandbox-api.paddle.com/transactions?status=completed"
    + "&order_by=created_at[desc]&per_page=30";
  const res = await fetch(url, { headers: { Authorization: `Bearer ${apiKey}` } });
  if (!res.ok) throw new Error(`paddle list transactions: ${res.status} ${await res.text()}`);
  const { data } = await res.json();
  return data.find((t) => t.custom_data?.reference === reference);
}

const deadline = Date.now() + waitSeconds * 1000;
let txn;
try {
  txn = await findTransaction();
  while (!txn && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 10_000));
    txn = await findTransaction();
  }
} catch (err) {
  console.error(`${stamp()} ${err.message}`);
  process.exit(3);
}
if (!txn) {
  console.error(`${stamp()} no completed sandbox transaction carries reference ${reference}`);
  process.exit(2);
}

const priceId = txn.items?.[0]?.price?.id;
const priceVar = priceVars.find(([, v]) => v === priceId)?.[0] ?? "(not one of ours)";
console.log(`${stamp()} transaction ${txn.id} · status ${txn.status} · customer ${txn.customer_id}`
  + ` · subscription ${txn.subscription_id ?? "none"} · price ${priceVar}`
  + ` · custom_data ${JSON.stringify(txn.custom_data)}`);

const body = JSON.stringify({
  event_id: `evt_relay_${txn.id}`,
  event_type: "transaction.completed",
  occurred_at: new Date().toISOString(),
  notification_id: `ntf_relay_${txn.id}`,
  data: txn,
});
const ts = Math.floor(Date.now() / 1000);
const h1 = createHmac("sha256", secret).update(`${ts}:${body}`).digest("hex");

const res = await fetch("http://127.0.0.1:8787/webhook/paddle", {
  method: "POST",
  headers: { "Content-Type": "application/json", "Paddle-Signature": `ts=${ts};h1=${h1}` },
  body,
});
console.log(`${stamp()} webhook: ${res.status} ${await res.text()}`);

const byRef = await fetch(`http://127.0.0.1:8787/license/by-reference/${reference}`);
const text = await byRef.text();
let shown = text;
try {
  const { key } = JSON.parse(text);
  if (typeof key === "string") shown = JSON.stringify({ key: `…${key.slice(-4)}` });
} catch {}
console.log(`${stamp()} by-reference: ${byRef.status} ${shown}`);
