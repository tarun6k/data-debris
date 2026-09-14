import { SELF, env, fetchMock } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { b64decode } from "../src/entitlement";

const te = new TextEncoder();
const SECRET = "fixture-webhook-secret";

beforeAll(() => {
  fetchMock.activate();
  fetchMock.disableNetConnect();
});

beforeEach(() => {
  fetchMock
    .get("https://sandbox-api.paddle.com")
    .intercept({ path: /\/customers\/.+/ })
    .reply(200, { data: { email: "Buyer@Example.com" } })
    .persist();
  fetchMock
    .get("https://api.resend.com")
    .intercept({ method: "POST", path: "/emails" })
    .reply(200, { id: "email-fixture" })
    .persist();
});

async function hmacHex(secret: string, msg: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", te.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, te.encode(msg)));
  return [...mac].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function postWebhook(evt: unknown, opts: { ts?: number; badSig?: boolean } = {}) {
  const raw = JSON.stringify(evt);
  const ts = opts.ts ?? Math.floor(Date.now() / 1000);
  let h1 = await hmacHex(SECRET, `${ts}:${raw}`);
  if (opts.badSig) h1 = (h1[0] === "0" ? "1" : "0") + h1.slice(1);
  return SELF.fetch("https://license.test/webhook/paddle", {
    method: "POST",
    headers: { "Paddle-Signature": `ts=${ts};h1=${h1}` },
    body: raw,
  });
}

let seq = 0;
function txnCompleted(over: Record<string, any> = {}) {
  seq += 1;
  return {
    event_id: over.event_id ?? `evt-${seq}-${crypto.randomUUID()}`,
    event_type: "transaction.completed",
    data: {
      id: over.txnId ?? `txn-${seq}`,
      customer_id: "ctm-1",
      subscription_id: over.subscriptionId ?? null,
      custom_data: {
        reference: over.reference ?? `ref-${seq}`,
        ...(over.machineId ? { machineId: over.machineId } : {}),
      },
      items: [{ price: { id: over.priceId ?? "price-1y-onetime" } }],
    },
  };
}

async function buy(over: Record<string, any> = {}): Promise<{ key: string; reference: string }> {
  const evt = txnCompleted(over);
  const res = await postWebhook(evt);
  expect(res.status).toBe(200);
  const reference = evt.data.custom_data.reference;
  const r = await SELF.fetch(`https://license.test/license/by-reference/${reference}`);
  expect(r.status).toBe(200);
  const { key } = (await r.json()) as { key: string };
  return { key, reference };
}

function post(path: string, body: unknown) {
  return SELF.fetch(`https://license.test${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function verifiedPayload(res: Response) {
  expect(res.status).toBe(200);
  const { entitlement } = (await res.json()) as { entitlement: string };
  const [p, s] = entitlement.split(".");
  const pub = await crypto.subtle.importKey(
    "raw", b64decode(env.TEST_PUBLIC_KEY), { name: "Ed25519" }, false, ["verify"],
  );
  const payloadBytes = b64decode(p);
  expect(await crypto.subtle.verify("Ed25519", pub, b64decode(s), payloadBytes)).toBe(true);
  return JSON.parse(new TextDecoder().decode(payloadBytes));
}

function epochInYears(years: number): number {
  const d = new Date();
  d.setFullYear(d.getFullYear() + years);
  return Math.floor(d.getTime() / 1000);
}

describe("webhook signature", () => {
  it("accepts a valid signature", async () => {
    const res = await postWebhook(txnCompleted());
    expect(res.status).toBe(200);
  });

  it("rejects a wrong signature", async () => {
    const res = await postWebhook(txnCompleted(), { badSig: true });
    expect(res.status).toBe(400);
  });

  it("rejects a timestamp older than 5 minutes", async () => {
    const res = await postWebhook(txnCompleted(), { ts: Math.floor(Date.now() / 1000) - 400 });
    expect(res.status).toBe(400);
  });
});

describe("webhook idempotency", () => {
  it("replaying the same event_id does not mint a second license", async () => {
    const evt = txnCompleted({ reference: "ref-replay" });
    await postWebhook(evt);
    const first = await SELF.fetch("https://license.test/license/by-reference/ref-replay");
    const { key } = (await first.json()) as { key: string };

    const replay = await postWebhook(evt);
    expect(replay.status).toBe(200);
    const second = await SELF.fetch("https://license.test/license/by-reference/ref-replay");
    expect(((await second.json()) as { key: string }).key).toBe(key);
  });
});

describe("plan mapping", () => {
  it.each([
    ["price-1y-recurring", "oneYear", true, 1],
    ["price-1y-onetime", "oneYear", false, 1],
    ["price-3y-recurring", "threeYears", true, 3],
    ["price-3y-onetime", "threeYears", false, 3],
  ])("%s -> %s autoRenew=%s %sy", async (priceId, plan, autoRenew, years) => {
    const { key } = await buy({ priceId });
    const payload = await verifiedPayload(await post("/validate", { key, machineId: "m1" }));
    expect(payload.plan).toBe(plan);
    expect(payload.autoRenew).toBe(autoRenew);
    expect(payload.status).toBe("active");
    expect(Math.abs(payload.expiresAt - epochInYears(years as number))).toBeLessThan(120);
  });

  it("ignores a transaction for a price that is not ours", async () => {
    const res = await postWebhook(txnCompleted({ priceId: "price-unrelated", reference: "ref-alien" }));
    expect(res.status).toBe(200);
    const r = await SELF.fetch("https://license.test/license/by-reference/ref-alien");
    expect(r.status).toBe(404);
  });
});

describe("activation", () => {
  it("enforces the 2-machine limit and deactivate frees a slot", async () => {
    const { key } = await buy();
    expect((await post("/activate", { key, machineId: "m1", machineName: "Studio" })).status).toBe(200);
    expect((await post("/activate", { key, machineId: "m2", machineName: "Laptop" })).status).toBe(200);

    const third = await post("/activate", { key, machineId: "m3", machineName: "Spare" });
    expect(third.status).toBe(409);
    expect(((await third.json()) as any).error).toBe("activation_limit");

    expect((await post("/deactivate", { key, machineId: "m2" })).status).toBe(200);
    const payload = await verifiedPayload(await post("/activate", { key, machineId: "m3", machineName: "Spare" }));
    expect(payload.machines.sort()).toEqual(["m1", "m3"]);
  });

  it("re-activating the same machine is idempotent", async () => {
    const { key } = await buy();
    await post("/activate", { key, machineId: "m1", machineName: "Studio" });
    const payload = await verifiedPayload(await post("/activate", { key, machineId: "m1", machineName: "Studio" }));
    expect(payload.machines).toEqual(["m1"]);
  });

  it("a machineId passed at checkout is pre-activated", async () => {
    const { key } = await buy({ machineId: "m-checkout" });
    const payload = await verifiedPayload(await post("/validate", { key, machineId: "m-checkout" }));
    expect(payload.machines).toEqual(["m-checkout"]);
  });

  it("unknown key is 404 on activate and validate", async () => {
    const a = await post("/activate", { key: "DD-XXXXX", machineId: "m1" });
    expect(a.status).toBe(404);
    expect(((await a.json()) as any).error).toBe("unknown_key");
    expect((await post("/validate", { key: "DD-XXXXX", machineId: "m1" })).status).toBe(404);
  });
});

describe("status flow", () => {
  it("a refund flips validate to 402", async () => {
    const txnId = "txn-refund-me";
    const { key } = await buy({ txnId });
    expect((await post("/validate", { key, machineId: "m1" })).status).toBe(200);

    await postWebhook({ event_id: `evt-${crypto.randomUUID()}`, event_type: "transaction.refunded", data: { id: txnId } });
    const res = await post("/validate", { key, machineId: "m1" });
    expect(res.status).toBe(402);
    expect(((await res.json()) as any).error).toBe("inactive");
    expect((await post("/activate", { key, machineId: "m1" })).status).toBe(402);
  });

  it("an adjustment refund also flips the license", async () => {
    const txnId = "txn-adjusted";
    const { key } = await buy({ txnId });
    await postWebhook({
      event_id: `evt-${crypto.randomUUID()}`,
      event_type: "adjustment.updated",
      data: { action: "refund", transaction_id: txnId },
    });
    expect((await post("/validate", { key, machineId: "m1" })).status).toBe(402);
  });

  it("cancellation keeps access until expiresAt", async () => {
    const { key } = await buy({ priceId: "price-1y-recurring", subscriptionId: "sub-cancel" });
    await postWebhook({ event_id: `evt-${crypto.randomUUID()}`, event_type: "subscription.canceled", data: { id: "sub-cancel" } });

    const payload = await verifiedPayload(await post("/validate", { key, machineId: "m1" }));
    expect(payload.status).toBe("canceled");
    expect(payload.autoRenew).toBe(false);
    expect(Math.abs(payload.expiresAt - epochInYears(1))).toBeLessThan(120); // term untouched
  });

  it("past_due is reported, then a renewed period extends expiresAt", async () => {
    const { key } = await buy({ priceId: "price-1y-recurring", subscriptionId: "sub-late" });
    await postWebhook({ event_id: `evt-${crypto.randomUUID()}`, event_type: "subscription.past_due", data: { id: "sub-late" } });
    let payload = await verifiedPayload(await post("/validate", { key, machineId: "m1" }));
    expect(payload.status).toBe("past_due");

    const ends = new Date();
    ends.setFullYear(ends.getFullYear() + 2);
    await postWebhook({
      event_id: `evt-${crypto.randomUUID()}`,
      event_type: "subscription.updated",
      data: { id: "sub-late", status: "active", current_billing_period: { ends_at: ends.toISOString() } },
    });
    payload = await verifiedPayload(await post("/validate", { key, machineId: "m1" }));
    expect(payload.status).toBe("active");
    expect(Math.abs(payload.expiresAt - epochInYears(2))).toBeLessThan(120);
  });
});

describe("entitlement signature", () => {
  it("verifies with the public key and binds the requesting machine", async () => {
    const { key } = await buy();
    const payload = await verifiedPayload(await post("/validate", { key, machineId: "m-mine" }));
    expect(payload.key).toBe(key);
    expect(payload.machineId).toBe("m-mine");
    expect(typeof payload.issuedAt).toBe("number");
  });

  it("a tampered payload fails verification", async () => {
    const { key } = await buy();
    const res = await post("/validate", { key, machineId: "m1" });
    const { entitlement } = (await res.json()) as { entitlement: string };
    const [p, s] = entitlement.split(".");
    const bytes = b64decode(p);
    bytes[0] ^= 0xff;
    const pub = await crypto.subtle.importKey(
      "raw", b64decode(env.TEST_PUBLIC_KEY), { name: "Ed25519" }, false, ["verify"],
    );
    expect(await crypto.subtle.verify("Ed25519", pub, b64decode(s), bytes)).toBe(false);
  });
});

describe("misc endpoints", () => {
  it("healthz answers ok", async () => {
    const res = await SELF.fetch("https://license.test/healthz");
    expect(res.status).toBe(200);
  });

  it("by-reference is 404 until the webhook lands", async () => {
    const res = await SELF.fetch("https://license.test/license/by-reference/never-bought");
    expect(res.status).toBe(404);
  });

  it("recover always answers 200 and never reveals whether the email exists", async () => {
    await buy();
    const known = await post("/recover", { email: "buyer@example.com" });
    const unknown = await post("/recover", { email: "nobody@example.com" });
    expect(known.status).toBe(200);
    expect(unknown.status).toBe(200);
    expect(await known.json()).toEqual(await unknown.json());
  });

  it("the customer email is stored lowercased for recovery", async () => {
    const { key } = await buy();
    const keys = await env.LICENSES.get<string[]>("email:buyer@example.com", "json");
    expect(keys).toContain(key);
  });

  it("rate limits the client API at 30/min per IP", async () => {
    let last = 0;
    for (let i = 0; i < 31; i++) {
      const res = await SELF.fetch("https://license.test/license/by-reference/none");
      last = res.status;
      if (i < 30) expect(res.status).toBe(404);
    }
    expect(last).toBe(429);
  });
});
