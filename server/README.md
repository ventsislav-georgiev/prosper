# Prosper server

The Prosper backend on **Cloudflare Workers**: passwordless email login, a
signed status token (features are **not** gated — a paid order just makes you a
**supporter**), device activation, and **settings sync** — all on the free tier
(Workers + D1 + KV). Email is sent via **Resend**; support orders come in
through a **Lemon Squeezy** webhook and record a display name for the app's
About list.

> Design rationale and free-tier comparison: see `../LICENSING-HOSTING.md`,
> `../LICENSING-STRATEGY.md`, and `../LICENSING-IMPLEMENTATION.md`.

```
 macOS app ──HTTPS──▶ Worker (Hono)
                        ├─ D1   users · licenses · devices · whitelist · sessions · settings
                        ├─ KV   one-time magic-link tokens + pickup slots (TTL auto-expire)
                        ├─ Cron daily session cleanup
                        ├─ Resend  → magic-link emails
                        └─ Lemon Squeezy webhook → lifetime licenses
```

## Layout

| Path | What |
| --- | --- |
| `src/index.ts` | routes + scheduled (cron) handler |
| `src/auth.ts` | magic-link: `/auth/start`, `/auth/verify`, `/auth/poll` |
| `src/license.ts` | supporter-status resolution + signed-token minting (`/license`) |
| `src/supporters.ts` | public recent supporter names (`GET /supporters`) |
| `src/account.ts` | `/activate`, `/devices`, `/account/delete` |
| `src/sync.ts` | settings sync (`GET`/`PUT /sync`, optimistic concurrency) |
| `src/payment.ts` | Lemon Squeezy webhook (`/payment/lemonsqueezy`) |
| `src/jwt.ts` | Ed25519 (EdDSA) license-token signing via WebCrypto |
| `migrations/0001_init.sql` | D1 schema |
| `migrations/0002_supporter.sql` | supporter name column + index |
| `scripts/gen-keys.mjs` | generate the Ed25519 signing keypair |

## One-time setup

```sh
cd server
npm install
npx wrangler login                       # opens browser; you authorize

# 1) Create the D1 database, then paste its database_id into wrangler.jsonc
npx wrangler d1 create prosper

# 2) Create the KV namespace, then paste its id into wrangler.jsonc
npx wrangler kv namespace create KV

# 3) Apply the schema (remote)
npm run db:migrate

# 4) Generate the license signing key; set the private JWK as a secret,
#    embed the printed public key in the macOS app.
npm run gen:keys
#   …copy the SUPPORTER_SIGNING_JWK line, then:
#   echo '<the printed JWK>' | npx wrangler secret put SUPPORTER_SIGNING_JWK

# 5) Other secrets
npx wrangler secret put RESEND_API_KEY
npx wrangler secret put LEMONSQUEEZY_WEBHOOK_SECRET

# 6) Edit wrangler.jsonc vars: EMAIL_FROM (a Resend-verified sender) and
#    APP_BASE_URL (your workers.dev URL — known after the first deploy).

# 7) Deploy
npm run deploy
```

Then point the **Lemon Squeezy** webhook at `https://<your-worker>/payment/lemonsqueezy`
(events: `order_created`, `order_refunded`) using the same signing secret, and
verify your sending domain in **Resend**.

### Local dev

```sh
cp .dev.vars.example .dev.vars   # fill in secrets (gen:keys for the JWK)
npm run db:migrate:local
npm run dev
```

## API

All authenticated calls send `Authorization: Bearer <session>`.

| Method | Path | Auth | Purpose |
| --- | --- | --- | --- |
| `POST` | `/auth/start` | — | `{email}` → emails a one-time link, returns `{pickup}` |
| `GET` | `/auth/verify?token=` | — | clicked in browser; mints session + license |
| `POST` | `/auth/poll` | — | `{pickup}` → `{status}` then `{session, license, email}` |
| `GET` | `/supporters` | — | `{supporters}` — recent distinct supporter display names for the About list |
| `GET` | `/license` | session | mint a fresh signed status token `{license, tier, exp}` |
| `POST` | `/activate` | session | `{device_id, name}`; 409 `device_limit` when over cap |
| `GET` | `/devices` | session | list activated devices |
| `DELETE` | `/devices/:id` | session | deactivate a device |
| `GET` | `/sync` | session | `{version, blob, updated_at}` |
| `PUT` | `/sync` | session | `{base_version, blob}`; 409 `conflict` returns server state |
| `POST` | `/account/delete` | session | GDPR delete (keeps license/financial records) |
| `POST` | `/payment/lemonsqueezy` | HMAC | webhook → lifetime license |

### Client flow (macOS app)

1. User types email → `POST /auth/start` → keep the `pickup`.
2. Poll `POST /auth/poll` every ~2 s (until `ready` or `expired`) while the user
   clicks the emailed link in their browser.
3. On `ready`, store `session` + `license` in the **Keychain**.
4. Verify the `license` JWT **offline** with the embedded Ed25519 public key
   (EdDSA). Treat it as valid until `exp` → that is your **offline grace period**.
5. Refresh via `GET /license` only when online *and* near `exp`. On any network
   failure, **fail open to the free tier** — never block the core app.

### License token

Compact EdDSA JWT, claims: `sub` (email), `tier` (`free|supporter`), `iat`,
`exp`, `jti`, `iss="prosper-license"`. Signed with the server's Ed25519 private
key; verified app-side with the public key from `gen:keys`. The token reflects
**status only** — the app never gates features on it.

### Settings sync & privacy

The server stores the settings `blob` **opaquely** and never inspects it. The
app should **encrypt sensitive fields client-side** before upload so sync stays
consistent with Prosper's "nothing leaves your machine" posture (the only
plaintext the server holds is the email + license state). Concurrency is
optimistic: send the last-seen `version` as `base_version`; on `409` merge the
returned state and retry.
