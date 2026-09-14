import type { Env } from "./index";
import { License, addEmailIndex, getLicense, newLicenseKey, putLicense } from "./store";

const te = new TextEncoder();

// Paddle-Signature: "ts=<unix>;h1=<hex hmac of `${ts}:${rawBody}`>". Multiple h1
// entries are possible during secret rotation. Reject clock skew over 5 minutes.
export async function verifyPaddleSignature(
  header: string | null,
  rawBody: string,
  secret: string,
  nowMs = Date.now(),
): Promise<boolean> {
  if (!header) return false;
  const parts = header.split(";").map((p) => p.trim());
  const ts = parts.find((p) => p.startsWith("ts="))?.slice(3);
  const h1s = parts.filter((p) => p.startsWith("h1=")).map((p) => p.slice(3).toLowerCase());
  if (!ts || h1s.length === 0) return false;
  if (Math.abs(nowMs / 1000 - Number(ts)) > 300) return false;

  const key = await crypto.subtle.importKey(
    "raw", te.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, te.encode(`${ts}:${rawBody}`)));
  const expected = [...mac].map((b) => b.toString(16).padStart(2, "0")).join("");
  for (const h1 of h1s) {
    if (h1.length === expected.length &&
        crypto.subtle.timingSafeEqual(te.encode(expected), te.encode(h1))) {
      return true;
    }
  }
  return false;
}

interface PaddleEvent {
  event_id: string;
  event_type: string;
  // Paddle's event payloads are large and versioned; we read a handful of fields.
  data: any;
}

export async function handlePaddleEvent(env: Env, evt: PaddleEvent): Promise<void> {
  const kv = env.LICENSES;
  switch (evt.event_type) {
    case "transaction.completed":
      return onTransactionCompleted(env, evt.data);
    case "subscription.canceled":
      // Term keeps running to expiresAt; the app locks only once it passes.
      return update(kv, `sub:${evt.data.id}`, (l) => {
        l.status = "canceled";
        l.autoRenew = false;
      });
    case "subscription.past_due":
      return update(kv, `sub:${evt.data.id}`, (l) => {
        l.status = "past_due";
      });
    case "subscription.updated": {
      const ends = evt.data.current_billing_period?.ends_at as string | undefined;
      return update(kv, `sub:${evt.data.id}`, (l) => {
        if (ends && Date.parse(ends) > Date.parse(l.expiresAt)) l.expiresAt = ends;
        if (evt.data.status === "active" && l.status === "past_due") l.status = "active";
      });
    }
    case "transaction.refunded":
      return update(kv, `txn:${evt.data.id}`, refund);
    default:
      if (evt.event_type.startsWith("adjustment.") && evt.data.action === "refund") {
        return update(kv, `txn:${evt.data.transaction_id}`, refund);
      }
  }
}

function refund(l: License): void {
  l.status = "refunded";
  l.autoRenew = false;
}

async function update(kv: KVNamespace, indexKey: string, mutate: (l: License) => void): Promise<void> {
  const key = await kv.get(indexKey);
  if (!key) return;
  const lic = await getLicense(kv, key);
  if (!lic) return;
  mutate(lic);
  await putLicense(kv, lic);
}

function planForPrice(env: Env, priceId: string | undefined):
  { plan: License["plan"]; years: number; autoRenew: boolean } | undefined {
  switch (priceId) {
    case env.PADDLE_PRICE_1Y_RECURRING: return { plan: "oneYear", years: 1, autoRenew: true };
    case env.PADDLE_PRICE_1Y_ONETIME: return { plan: "oneYear", years: 1, autoRenew: false };
    case env.PADDLE_PRICE_3Y_RECURRING: return { plan: "threeYears", years: 3, autoRenew: true };
    case env.PADDLE_PRICE_3Y_ONETIME: return { plan: "threeYears", years: 3, autoRenew: false };
    default: return undefined;
  }
}

async function onTransactionCompleted(env: Env, data: any): Promise<void> {
  const mapped = planForPrice(env, data.items?.[0]?.price?.id);
  if (!mapped) return; // not one of our prices; acknowledge and ignore

  const now = new Date();
  const expires = new Date(now);
  expires.setFullYear(expires.getFullYear() + mapped.years);
  const custom = data.custom_data ?? {};
  const email = ((await customerEmail(env, data.customer_id)) ?? "").toLowerCase();

  const lic: License = {
    key: newLicenseKey(),
    email,
    plan: mapped.plan,
    purchasedAt: now.toISOString(),
    expiresAt: expires.toISOString(),
    status: "active",
    paddleCustomerId: data.customer_id ?? "",
    paddleTransactionId: data.id,
    paddleSubscriptionId: data.subscription_id ?? undefined,
    autoRenew: mapped.autoRenew,
    machines: custom.machineId
      ? [{ machineId: custom.machineId, name: "", activatedAt: now.toISOString() }]
      : [],
  };

  const kv = env.LICENSES;
  await putLicense(kv, lic);
  await kv.put(`txn:${data.id}`, lic.key);
  if (lic.paddleSubscriptionId) await kv.put(`sub:${lic.paddleSubscriptionId}`, lic.key);
  if (custom.reference) await kv.put(`ref:${custom.reference}`, lic.key);
  if (email) {
    await addEmailIndex(kv, email, lic.key);
    // The key is also retrievable via /license/by-reference, so a failed email
    // must not fail the webhook.
    try {
      await sendLicenseEmail(env, email, [lic.key]);
    } catch {}
  }
}

async function customerEmail(env: Env, customerId: string | undefined): Promise<string | undefined> {
  if (!customerId) return undefined;
  const base = env.PADDLE_ENV === "production"
    ? "https://api.paddle.com"
    : "https://sandbox-api.paddle.com";
  try {
    const res = await fetch(`${base}/customers/${customerId}`, {
      headers: { Authorization: `Bearer ${env.PADDLE_API_KEY}` },
    });
    if (!res.ok) return undefined;
    const body = (await res.json()) as { data?: { email?: string } };
    return body.data?.email;
  } catch {
    return undefined;
  }
}

export async function sendLicenseEmail(env: Env, to: string, keys: string[]): Promise<void> {
  const lines = [
    "Thanks for buying Data Debris.",
    "",
    keys.length === 1 ? "Your license key:" : "Your license keys:",
    ...keys.map((k) => `  ${k}`),
    "",
    "Open Data Debris, choose Enter License, and paste the key.",
    "Each key covers 2 Macs. Reply to this email if anything is off.",
  ];
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: env.EMAIL_FROM,
      to: [to],
      subject: "Your Data Debris license",
      text: lines.join("\n"),
    }),
  });
  if (!res.ok) throw new Error(`resend ${res.status}`);
}
