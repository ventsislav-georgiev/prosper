import { Hono } from "hono";
import type { Bindings, Env } from "./types";
import auth from "./auth";
import { requireSession } from "./middleware";
import { getSupporterToken } from "./supporter";
import { activateDevice, deleteAccount, deleteDevice, listDevices } from "./account";
import { getSettings, putSettings } from "./sync";
import { lemonSqueezyWebhook } from "./payment";
import { listSupporters } from "./supporters";
import { nowSec } from "./util";

const app = new Hono<Env>();

app.get("/", (c) => c.json({ name: "prosper-server", ok: true }));
app.get("/health", (c) => c.json({ ok: true, ts: nowSec() }));

// Public: passwordless auth (magic link + poll).
app.route("/auth", auth);

// Public: payment provider webhook (verified via HMAC inside the handler).
app.post("/payment/lemonsqueezy", lemonSqueezyWebhook);

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

export default {
  fetch: app.fetch,

  // Daily cleanup of expired sessions.
  async scheduled(_event: ScheduledController, env: Bindings, ctx: ExecutionContext) {
    ctx.waitUntil(
      env.DB.prepare(
        `DELETE FROM sessions WHERE expires_at IS NOT NULL AND expires_at < ?1`,
      )
        .bind(nowSec())
        .run(),
    );
  },
};
