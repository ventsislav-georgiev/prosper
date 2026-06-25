import type { Context, MiddlewareHandler } from "hono";

export type Bindings = {
  DB: D1Database;
  KV: KVNamespace;

  // Secrets (set via `wrangler secret put …`)
  RESEND_API_KEY: string;
  SUPPORTER_SIGNING_JWK: string; // Ed25519 private key as a JWK JSON string
  LEMONSQUEEZY_WEBHOOK_SECRET: string;
  GITHUB_WEBHOOK_SECRET: string;

  // Vars (wrangler.jsonc)
  EMAIL_FROM: string;
  APP_BASE_URL: string;
  MAGIC_LINK_TTL_SECONDS?: string;
  SUPPORTER_TOKEN_TTL_DAYS?: string;
  SESSION_TTL_DAYS?: string;
  DEVICE_LIMIT?: string;
  SYNC_MAX_BYTES?: string;
  MARKET_MAX_BYTES?: string;
};

export type Variables = {
  email: string;
};

export type Env = { Bindings: Bindings; Variables: Variables };
export type Ctx = Context<Env>;
export type Middleware = MiddlewareHandler<Env>;

// Status only — features are no longer gated. "supporter" is a cosmetic badge
// (and a name in the About list) granted to anyone who's chipped in.
export type Status = "free" | "supporter";
