// Ed25519-signed entitlement: base64url(payload JSON) + "." + base64url(signature).
// The app verifies with CryptoKit (Curve25519.Signing.PublicKey, raw 32 bytes).
// Dates are Unix epoch seconds so neither side has to parse ISO strings.

export interface EntitlementPayload {
  key: string;
  plan: "oneYear" | "threeYears";
  expiresAt: number;
  status: "active" | "canceled" | "past_due" | "refunded";
  autoRenew: boolean;
  machines: string[];
  issuedAt: number;
  machineId: string;
}

const te = new TextEncoder();

export function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export function b64decode(s: string): Uint8Array {
  const bin = atob(s.replaceAll("-", "+").replaceAll("_", "/"));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export async function signEntitlement(
  payload: EntitlementPayload,
  privateKeyPkcs8B64: string,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "pkcs8",
    b64decode(privateKeyPkcs8B64),
    { name: "Ed25519" },
    false,
    ["sign"],
  );
  const body = te.encode(JSON.stringify(payload));
  const sig = new Uint8Array(await crypto.subtle.sign("Ed25519", key, body));
  return `${b64url(body)}.${b64url(sig)}`;
}
