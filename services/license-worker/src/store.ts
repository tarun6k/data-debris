// KV layout:
//   lic:<key>          -> License (JSON)
//   email:<email>      -> string[] of license keys
//   ref:<reference>    -> license key (checkout pickup, see /license/by-reference)
//   evt:<event_id>     -> "1" (webhook idempotency)
//   sub:<subscription> -> license key (subscription.* event lookup)
//   txn:<transaction>  -> license key (refund/adjustment lookup)
//   rl:<ip>:<minute>   -> request counter (rate limit)

export interface Machine {
  machineId: string;
  name: string;
  activatedAt: string;
}

export interface License {
  key: string;
  email: string;
  plan: "oneYear" | "threeYears";
  purchasedAt: string;
  expiresAt: string;
  status: "active" | "canceled" | "past_due" | "refunded";
  paddleCustomerId: string;
  paddleTransactionId: string;
  paddleSubscriptionId?: string;
  autoRenew: boolean;
  machines: Machine[];
}

export async function getLicense(kv: KVNamespace, key: string): Promise<License | null> {
  return kv.get<License>(`lic:${key}`, "json");
}

export async function putLicense(kv: KVNamespace, lic: License): Promise<void> {
  await kv.put(`lic:${lic.key}`, JSON.stringify(lic));
}

export async function addEmailIndex(kv: KVNamespace, email: string, key: string): Promise<void> {
  const k = `email:${email}`;
  const keys = (await kv.get<string[]>(k, "json")) ?? [];
  if (!keys.includes(key)) {
    keys.push(key);
    await kv.put(k, JSON.stringify(keys));
  }
}

// 100 bits from an unambiguous alphabet (no 0/O/1/I); 32 divides 256 so % is unbiased.
export function newLicenseKey(): string {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(20));
  let s = "DD";
  for (let i = 0; i < 20; i++) {
    if (i % 5 === 0) s += "-";
    s += alphabet[bytes[i] % 32];
  }
  return s;
}
