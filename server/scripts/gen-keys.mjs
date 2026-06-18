#!/usr/bin/env node
// Generate an Ed25519 keypair for signing supporter tokens.
//   - The PRIVATE JWK goes to the Worker as the SUPPORTER_SIGNING_JWK secret.
//   - The PUBLIC key is embedded in the macOS app to verify supporter tokens offline.
//
// Usage:  node scripts/gen-keys.mjs
// Nothing is written to disk; copy the values from the output.

import { webcrypto as crypto } from "node:crypto";

const { publicKey, privateKey } = await crypto.subtle.generateKey(
  { name: "Ed25519" },
  true,
  ["sign", "verify"],
);

const privJwk = await crypto.subtle.exportKey("jwk", privateKey);
const pubJwk = await crypto.subtle.exportKey("jwk", publicKey);

// 32-byte raw public key (JWK `x` is base64url of it) — handy for Swift CryptoKit:
//   Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: ...)!)
const rawPubB64 = Buffer.from(pubJwk.x, "base64url").toString("base64");

console.log("\n=== SUPPORTER_SIGNING_JWK (server secret — keep private) ===\n");
console.log(JSON.stringify(privJwk));
console.log("\nSet it with:\n");
console.log(`  echo '${JSON.stringify(privJwk)}' | npx wrangler secret put SUPPORTER_SIGNING_JWK\n`);

console.log("=== Public key (embed in the macOS app to verify tokens) ===\n");
console.log("JWK:", JSON.stringify(pubJwk));
console.log("base64url (JWK x):", pubJwk.x);
console.log("base64 (32-byte raw, for CryptoKit):", rawPubB64);
console.log("");
