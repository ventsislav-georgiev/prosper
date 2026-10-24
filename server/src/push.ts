import { Hono } from "hono";
import type { Bindings, Ctx, Env } from "./types";
import { requireSession } from "./middleware";
import { apnsSender } from "./apns";
import { deleteTokens, postSessions, putToken, runCron, type PushDeps, type RouteResult } from "./pushStore.mjs";
import { cronBudget, readBody } from "./pushLogic.mjs";
import { nowSec } from "./util";

// Live session status on the phone (#521, contract v1). The phone registers APNs
// tokens; the Mac posts its Remote Terminal sessions; the Worker turns edges into
// quiet Live Activity pushes and a loud "needs you" alert. Logic: pushLogic.mjs
// (pure) and pushStore.mjs (D1), both unit-tested under node --test.

const deps = (env: Bindings, defer: PushDeps["defer"]): PushDeps => ({
  db: env.DB,
  send: apnsSender(env),
  now: nowSec,
  defer,
  budget: cronBudget(env.PUSH_CRON_BUDGET),
});

type Handler = (deps: PushDeps, email: string, body: unknown, tokenHash: string) => Promise<RouteResult>;

const route = (h: Handler) => async (c: Ctx) => {
  const b = await readBody(c.req.raw); // capped at 32 KB before the JSON parse
  if (b.tooLarge) return c.json({ error: "payload_too_large" }, 413);
  const r = await h(deps(c.env, (p) => c.executionCtx.waitUntil(p)), c.get("email"), b.value, c.get("tokenHash"));
  return r.status === 204 ? c.body(null, 204) : c.json({ error: r.error }, r.status);
};

export const push = new Hono<Env>();
push.post("/tokens", requireSession, route(putToken));
push.delete("/tokens", requireSession, route(deleteTokens));
push.post("/sessions", requireSession, route(postSessions));

/** The every-minute cron ("* * * * *" in wrangler.jsonc). */
export function pushCron(env: Bindings, ctx: ExecutionContext) {
  ctx.waitUntil(runCron(deps(env, (p) => ctx.waitUntil(p))));
}
