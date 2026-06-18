import { b64urlFromBytes, b64urlFromString } from "./util";

export type SupporterClaims = {
  sub: string; // email
  status: "free" | "supporter";
  iat: number;
  exp: number;
  jti: string;
  iss: "prosper-supporter";
};

let cachedKey: CryptoKey | null = null;

async function importSigningKey(jwkStr: string): Promise<CryptoKey> {
  if (cachedKey) return cachedKey;
  const jwk = JSON.parse(jwkStr) as JsonWebKey;
  // Some generators stamp `alg:"Ed25519"` (the curve), but WebCrypto's importKey
  // expects the JWA signature name `"EdDSA"` (or none) and rejects the mismatch.
  if (jwk.alg && jwk.alg !== "EdDSA") delete jwk.alg;
  cachedKey = await crypto.subtle.importKey(
    "jwk",
    jwk,
    { name: "Ed25519" },
    false,
    ["sign"],
  );
  return cachedKey;
}

/** Sign a compact EdDSA (Ed25519) JWT the macOS app can verify offline. */
export async function signSupporterToken(jwkStr: string, claims: SupporterClaims): Promise<string> {
  const key = await importSigningKey(jwkStr);
  const header = b64urlFromString(JSON.stringify({ alg: "EdDSA", typ: "JWT" }));
  const payload = b64urlFromString(JSON.stringify(claims));
  const signingInput = `${header}.${payload}`;
  const sig = await crypto.subtle.sign(
    "Ed25519",
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${b64urlFromBytes(new Uint8Array(sig))}`;
}
