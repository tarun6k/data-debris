import { EntitlementPayload, signEntitlement } from "./entitlement";
import { handlePaddleEvent, sendLicenseEmail, verifyPaddleSignature } from "./paddle";
import { License, getLicense, putLicense } from "./store";

export interface Env {
  LICENSES: KVNamespace;
  PADDLE_ENV: string;
  PADDLE_API_KEY: string;
  PADDLE_WEBHOOK_SECRET: string;
  PADDLE_PRICE_1Y_RECURRING: string;
  PADDLE_PRICE_1Y_ONETIME: string;
  PADDLE_PRICE_3Y_RECURRING: string;
  PADDLE_PRICE_3Y_ONETIME: string;
  LICENSE_SIGNING_KEY: string; // Ed25519 private key, PKCS8 DER, base64
  RESEND_API_KEY: string;
  EMAIL_FROM: string;
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const path = new URL(req.url).pathname;

    if (path === "/healthz") return json({ ok: true });
    if (path === "/webhook/paddle" && req.method === "POST") return webhook(req, env);

    // Client API below: rate-limited, webhook is not (Paddle bursts, and the
    // signature already gates it).
    const ip = req.headers.get("cf-connecting-ip") ?? "local";
    if (await rateLimited(env.LICENSES, ip)) return json({ error: "rate_limited" }, 429);

    if (req.method === "GET" && path.startsWith("/license/by-reference/")) {
      return byReference(env, decodeURIComponent(path.slice("/license/by-reference/".length)));
    }
    if (req.method === "POST") {
      let body: any;
      try {
        body = await req.json();
      } catch {
        return json({ error: "bad_request" }, 400);
      }
      switch (path) {
        case "/activate": return activate(env, body);
        case "/validate": return validate(env, body);
        case "/deactivate": return deactivate(env, body);
        case "/recover": return recover(env, body);
        case "/pricing-preview": return pricingPreview(env, body, req);
      }
    }
    return json({ error: "not_found" }, 404);
  },
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// ponytail: KV read-modify-write counter is racy under a burst; good enough at
// 30/min, move to a Durable Object if abuse ever shows up.
async function rateLimited(kv: KVNamespace, ip: string): Promise<boolean> {
  const k = `rl:${ip}:${Math.floor(Date.now() / 60_000)}`;
  const n = Number((await kv.get(k)) ?? "0") + 1;
  await kv.put(k, String(n), { expirationTtl: 120 });
  return n > 30;
}

async function webhook(req: Request, env: Env): Promise<Response> {
  const raw = await req.text();
  const ok = await verifyPaddleSignature(
    req.headers.get("Paddle-Signature"), raw, env.PADDLE_WEBHOOK_SECRET,
  );
  if (!ok) return json({ error: "bad_signature" }, 400);

  const evt = JSON.parse(raw);
  if (await env.LICENSES.get(`evt:${evt.event_id}`)) return json({ ok: true }); // replay
  await handlePaddleEvent(env, evt);
  await env.LICENSES.put(`evt:${evt.event_id}`, "1", { expirationTtl: 60 * 60 * 24 * 30 });
  return json({ ok: true });
}

async function byReference(env: Env, ref: string): Promise<Response> {
  const key = ref ? await env.LICENSES.get(`ref:${ref}`) : null;
  return key ? json({ key }) : json({ error: "not_found" }, 404);
}

async function signedEntitlement(env: Env, lic: License, machineId: string): Promise<Response> {
  const payload: EntitlementPayload = {
    key: lic.key,
    plan: lic.plan,
    expiresAt: Math.floor(Date.parse(lic.expiresAt) / 1000),
    status: lic.status,
    autoRenew: lic.autoRenew,
    machines: lic.machines.map((m) => ({
      id: m.machineId,
      name: m.name,
      activatedAt: Math.floor(Date.parse(m.activatedAt) / 1000),
    })),
    issuedAt: Math.floor(Date.now() / 1000),
    machineId,
  };
  return json({ entitlement: await signEntitlement(payload, env.LICENSE_SIGNING_KEY) });
}

async function activate(env: Env, body: any): Promise<Response> {
  const { key, machineId, machineName } = body ?? {};
  if (typeof key !== "string" || typeof machineId !== "string" || !key || !machineId) {
    return json({ error: "bad_request" }, 400);
  }
  const lic = await getLicense(env.LICENSES, key);
  if (!lic) return json({ error: "unknown_key" }, 404);
  if (lic.status === "refunded" || Date.parse(lic.expiresAt) < Date.now()) {
    return json({ error: "inactive" }, 402);
  }
  const existing = lic.machines.find((m) => m.machineId === machineId);
  if (existing) {
    existing.name = typeof machineName === "string" ? machineName : existing.name;
  } else {
    if (lic.machines.length >= 2) return json({ error: "activation_limit" }, 409);
    lic.machines.push({
      machineId,
      name: typeof machineName === "string" ? machineName : "",
      activatedAt: new Date().toISOString(),
    });
  }
  await putLicense(env.LICENSES, lic);
  return signedEntitlement(env, lic, machineId);
}

async function validate(env: Env, body: any): Promise<Response> {
  const { key, machineId } = body ?? {};
  if (typeof key !== "string" || typeof machineId !== "string" || !key || !machineId) {
    return json({ error: "bad_request" }, 400);
  }
  const lic = await getLicense(env.LICENSES, key);
  if (!lic) return json({ error: "unknown_key" }, 404);
  if (lic.status === "refunded") return json({ error: "inactive" }, 402);
  // Canceled and past_due still get an entitlement; expiresAt/status in the
  // payload let the app decide (canceled runs to term, past_due locks).
  return signedEntitlement(env, lic, machineId);
}

async function deactivate(env: Env, body: any): Promise<Response> {
  const { key, machineId } = body ?? {};
  if (typeof key === "string" && typeof machineId === "string") {
    const lic = await getLicense(env.LICENSES, key);
    if (lic) {
      lic.machines = lic.machines.filter((m) => m.machineId !== machineId);
      await putLicense(env.LICENSES, lic);
    }
  }
  return json({ ok: true }); // idempotent; unknown key is still "done"
}

async function recover(env: Env, body: any): Promise<Response> {
  // Always 200 so the endpoint can't be used to probe which emails bought.
  const email = typeof body?.email === "string" ? body.email.trim().toLowerCase() : "";
  if (email) {
    const keys = await env.LICENSES.get<string[]>(`email:${email}`, "json");
    if (keys?.length) {
      try {
        await sendLicenseEmail(env, email, keys);
      } catch {}
    }
  }
  return json({ ok: true });
}

// The app shows localised plan prices on its plan cards but must only ever
// talk to this service, so Paddle's pricing preview is proxied here. Only
// our own price ids are accepted (this is not an open proxy) and the reply
// is trimmed to what the cards need. Paddle localises by IP; Cloudflare's
// view of the caller is passed on when it is a public address.
async function pricingPreview(env: Env, body: any, req: Request): Promise<Response> {
  const known = new Set([
    env.PADDLE_PRICE_1Y_RECURRING, env.PADDLE_PRICE_1Y_ONETIME,
    env.PADDLE_PRICE_3Y_RECURRING, env.PADDLE_PRICE_3Y_ONETIME,
  ]);
  const items: unknown[] = Array.isArray(body?.items) ? body.items : [];
  if (items.length === 0 || items.length > known.size) return json({ error: "bad_request" }, 400);
  const ids: string[] = [];
  for (const item of items) {
    const id = (item as { price_id?: unknown })?.price_id;
    if (typeof id !== "string" || !known.has(id)) return json({ error: "bad_request" }, 400);
    ids.push(id);
  }
  const payload: Record<string, unknown> = {
    items: ids.map((price_id) => ({ price_id, quantity: 1 })),
  };
  const ip = req.headers.get("cf-connecting-ip");
  if (ip && !isPrivateAddress(ip)) payload.customer_ip_address = ip;

  const base = env.PADDLE_ENV === "production"
    ? "https://api.paddle.com"
    : "https://sandbox-api.paddle.com";
  let upstream: any;
  try {
    const res = await fetch(`${base}/pricing-preview`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.PADDLE_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    });
    if (!res.ok) return json({ error: "upstream" }, 502);
    upstream = await res.json();
  } catch {
    return json({ error: "upstream" }, 502);
  }
  const lineItems: any[] = upstream?.data?.details?.line_items ?? [];
  return json({
    data: {
      currency_code: upstream?.data?.currency_code ?? "USD",
      details: {
        line_items: lineItems.map((li) => ({
          price: { id: li?.price?.id },
          formatted_totals: { total: li?.formatted_totals?.total },
        })),
      },
    },
  });
}

function isPrivateAddress(ip: string): boolean {
  return ip === "local" || ip.startsWith("127.") || ip.startsWith("10.") || ip.startsWith("192.168.")
    || /^172\.(1[6-9]|2\d|3[01])\./.test(ip) || ip === "::1" || ip.startsWith("fc") || ip.startsWith("fd");
}
