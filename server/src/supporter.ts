import type { Bindings, Ctx, Status } from "./types";
import { signSupporterToken } from "./jwt";
import { intEnv, nowSec, randomToken } from "./util";

/**
 * Resolve a user's status. Features are not gated — this only decides whether
 * the user shows as a "supporter" (any active support order, or a whitelist
 * entry) versus "free".
 */
export async function resolveEntitlement(
  env: Bindings,
  email: string,
): Promise<{ status: Status }> {
  const now = nowSec();

  const supported = await env.DB.prepare(
    `SELECT 1 FROM supporter_tokens
     WHERE email = ?1 AND status = 'active'
       AND (expires_at IS NULL OR expires_at > ?2)
     LIMIT 1`,
  )
    .bind(email, now)
    .first<{ 1: number }>();

  const wl = await env.DB.prepare(`SELECT 1 FROM whitelist WHERE email = ?1`)
    .bind(email)
    .first<{ 1: number }>();

  const status: Status = supported || wl ? "supporter" : "free";
  return { status };
}

/** Mint a fresh signed supporter token reflecting the user's current status. */
export async function mintSupporterToken(env: Bindings, email: string) {
  const { status } = await resolveEntitlement(env, email);
  const iat = nowSec();
  const exp = iat + intEnv(env.SUPPORTER_TOKEN_TTL_DAYS, 30) * 86400;
  const token = await signSupporterToken(env.SUPPORTER_SIGNING_JWK, {
    sub: email,
    status,
    iat,
    exp,
    jti: randomToken(8),
    iss: "prosper-supporter",
  });
  return { token, status, exp };
}

export async function getSupporterToken(c: Ctx) {
  const email = c.get("email");
  return c.json(await mintSupporterToken(c.env, email));
}
