import { Hono } from "hono";
import type { Bindings, Env } from "./types";
import auth from "./auth";
import { requireSession } from "./middleware";
import { getSupporterToken } from "./supporter";
import { activateDevice, deleteAccount, deleteDevice, listDevices } from "./account";
import { getSettings, putSettings } from "./sync";
import { lemonSqueezyWebhook, githubSponsorsWebhook } from "./payment";
import { listSupporters } from "./supporters";
import { market } from "./market";
import { wake } from "./wake";
import { push, pushCron } from "./push";
import { nowSec } from "./util";

const app = new Hono<Env>();

app.get("/", (c) => c.json({ name: "prosper-server", ok: true }));
app.get("/health", (c) => c.json({ ok: true, ts: nowSec() }));

// Public: passwordless auth (magic link + poll).
app.route("/auth", auth);

// Public: payment provider webhook (verified via HMAC inside the handler).
app.post("/payment/lemonsqueezy", lemonSqueezyWebhook);
app.post("/payment/github", githubSponsorsWebhook);

// Public: recent supporter display names for the app's About list.
app.get("/supporters", listSupporters);

// Authenticated API (opaque session bearer).
app.get("/supporter", requireSession, getSupporterToken);
app.post("/activate", requireSession, activateDevice);
app.get("/devices", requireSession, listDevices);
app.delete("/devices/:id", requireSession, deleteDevice);
app.post("/account/delete", requireSession, deleteAccount);
app.get("/sync", requireSession, getSettings);
app.put("/sync", requireSession, putSettings);

// Extension marketplace: public browse/download + authenticated publish/yank.
app.route("/market", market);

// Remote wake: public poll (the sleeping Mac) + authenticated set.
app.route("/wake", wake);

// Live session status on the phone: token registry + Mac session posts.
app.route("/push", push);

export default {
  fetch: app.fetch,

  // "* * * * *": live-status cron (lapse, idle end, re-push). Any other trigger
  // ("0 3 * * *") is the daily cleanup of expired sessions.
  async scheduled(event: ScheduledController, env: Bindings, ctx: ExecutionContext) {
    if (event.cron === "* * * * *") return pushCron(env, ctx);
    ctx.waitUntil(
      env.DB.prepare(
        `DELETE FROM sessions WHERE expires_at IS NOT NULL AND expires_at < ?1`,
      )
        .bind(nowSec())
        .run(),
    );
  },
};
