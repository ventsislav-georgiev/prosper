import type { Bindings } from "./types";
import { importP8, sendApns, signApnsJwt, type ApnsPush, type ApnsResult, type FetchFn } from "./pushLogic.mjs";
import { nowSec } from "./util";

// APNs sender (#521). Deployed Workers reach APNs over HTTP/2 through plain fetch()
// (Cloudflare's edge speaks HTTP/2 to Apple); local workerd cannot, so the request
// logic lives in pushLogic.sendApns and is tested against an injected fetch.
//
// Provider token: ES256 over the .p8 (secret APNS_KEY_P8) with APNS_KEY_ID and
// APNS_TEAM_ID, cached 50 min (Apple accepts 20..60 min). Module scope = per isolate.
const JWT_TTL_S = 50 * 60;
let cached: { kid: string; iat: number; jwt: string } | null = null;

async function providerJwt(env: Bindings): Promise<string | null> {
  if (!env.APNS_KEY_P8 || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) return null;
  const now = nowSec();
  if (cached && cached.kid === env.APNS_KEY_ID && now - cached.iat < JWT_TTL_S) return cached.jwt;
  const key = await importP8(env.APNS_KEY_P8);
  cached = { kid: env.APNS_KEY_ID, iat: now, jwt: await signApnsJwt(key, env.APNS_KEY_ID, env.APNS_TEAM_ID, now) };
  return cached.jwt;
}

/** A send(push) for pushStore: signs (cached), posts, classifies. Never throws. */
export function apnsSender(env: Bindings, fetchFn: FetchFn = (url, init) => fetch(url, init)) {
  const topic = env.APNS_TOPIC || "eu.illegible.prosperios";
  return async (p: ApnsPush): Promise<ApnsResult> => {
    let jwt: string | null;
    try {
      jwt = await providerJwt(env);
    } catch {
      console.error("apns: APNS_KEY_P8 did not import as a P-256 PKCS#8 key");
      return "error";
    }
    if (!jwt) {
      console.warn("apns: APNS_KEY_P8, APNS_KEY_ID or APNS_TEAM_ID unset; push skipped");
      return "error";
    }
    const r = await sendApns(fetchFn, { jwt, topic }, p);
    if (r === "auth") cached = null; // the next push signs a fresh token
    if (r === "error") console.warn(`apns: ${p.pushType} push failed`);
    return r;
  };
}
