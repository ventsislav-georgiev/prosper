// Types for the pure live-status module (kept .mjs so `node --test` runs it raw).
export type SessionState = "blocked" | "working" | "done" | "idle";
export type Session = { name: string; alias?: string; state: SessionState; agents?: number };
export type TokenKind = "alert" | "la_start" | "la_update";
export type ApnsEnv = "production" | "sandbox";
export type Parsed<T> = { value: T; error?: undefined } | { error: string; value?: undefined };
export type TokenBody = {
  device_id: string;
  kind: TokenKind;
  token: string;
  env: ApnsEnv;
  activity_id: string;
  mac_id: string | null;
};
export type DeleteBody = { device_id: string; kind: TokenKind | null; activity_id: string | null };
export type SessionsBody = { mac_id: string; seq: number; offline: boolean; sessions: Session[] | null };
export type MacState = {
  seq: number;
  last_seen: number;
  online: boolean;
  sessions: Session[];
  last_push_at: number | null;
  last_alert: Record<string, number>;
  idle_since: number | null;
  started_at: number | null;
  blocked: string[]; // blocked in the last sessions post; kept across a lapse/offline
};
export type PushIntents = {
  start: boolean;
  update: boolean;
  priority: 5 | 10;
  end: { dismissal: number } | null;
  alerts: { name: string; label: string }[];
};
export type ContentState = {
  v: 1;
  online: boolean;
  counts: Record<SessionState, number>;
  sessions: Session[];
  more: number;
};
export type TokenRow = { email: string; device_id: string; kind: TokenKind; activity_id: string; token: string; env: ApnsEnv };
export type ApnsPush = {
  row: TokenRow;
  pushType: "alert" | "liveactivity";
  priority: 5 | 10;
  payload: unknown;
  collapseId?: string;
};
export type ApnsResult = "ok" | "drop" | "auth" | "error";
export type FetchFn = (url: string, init: RequestInit) => Promise<Response>;

export const MAX_SESSIONS: number;
export const CARD_SESSIONS: number;
export const CUT: number;
export const ALERT_LIMIT_S: number;
export const LAPSE_S: number;
export const IDLE_END_S: number;
export const REPUSH_S: number;
export const STALE_S: number;
export const OFFLINE_DISMISS_S: number;
export const START_GAP_S: number;
export const RATE_PER_MIN: number;
export const LA_MAX_AGE_S: number;
export const ROTATE_LEAD_S: number;
export const ATTRIBUTES_TYPE: string;
export const MAX_PHONES: number;
export const CRON_BUDGET: number;
export const STEP_D1: number;
export const SEQ_AHEAD_MS: number;
export const MAX_BODY: number;

export function parseTokenBody(b: unknown): Parsed<TokenBody>;
export function parseDeleteBody(b: unknown): Parsed<DeleteBody>;
export function parseSessionsBody(b: unknown, nowS: number): Parsed<SessionsBody>;
export function cleanMacName(raw: unknown): string;
export function readBody(req: {
  headers: { get(name: string): string | null };
  body: ReadableStream<Uint8Array> | null;
}): Promise<{ tooLarge: true; value?: undefined } | { value: unknown; tooLarge?: undefined }>;
export function cronBudget(raw: string | undefined): number;
export function cut(s: string, n?: number): string;
export function isActive(sessions: Session[]): boolean;
export function contentState(sessions: Session[], online?: boolean): ContentState;
export function emptyMac(): MacState;
export function reduceSessions(
  prev: MacState | null,
  input: SessionsBody,
  now: number,
): { mac: MacState; push: PushIntents } | null;
export function cronStep(
  mac: MacState,
  hasCard: boolean,
  now: number,
): { kind: "lapse" | "end" | "repush"; mac: MacState; push: PushIntents } | null;
export type LiveMac = Pick<MacState, "online" | "last_seen" | "sessions" | "started_at">;
export function wantsCard(mac: Pick<MacState, "online" | "last_seen" | "sessions">, now: number): boolean;
export type ExpiredCard = { mac: LiveMac | null; start_token: string | null; has_card: number | boolean; created_at: number };
export function restartStep(p: ExpiredCard, now: number): "start" | "drop" | "wait";
export function planCron<R extends { mac: MacState; cards: number }, E extends ExpiredCard = ExpiredCard>(
  rows: R[],
  now: number,
  budget?: number,
  expired?: E[],
): (
  | { kind: "lapse" | "end" | "repush"; mac: MacState; push: PushIntents; row: R }
  | { kind: "restart"; start: boolean; row: E }
)[];
export function laPayload(event: string, cs: ContentState, now: number, extra?: Record<string, unknown>): unknown;
export function startPayload(cs: ContentState, now: number, macId: string, macName: string): unknown;
export function alertPayload(macId: string, macName: string, alerts: { name: string; label: string }[]): unknown;
export function collapseId(macId: string, name?: string): Promise<string>;
export function classifyApns(status: number, reason: string): ApnsResult;
export function apnsHost(env: ApnsEnv): string;
export function sendApns(fetchFn: FetchFn, auth: { jwt: string; topic: string }, p: ApnsPush): Promise<ApnsResult>;
export function importP8(pem: string): Promise<CryptoKey>;
export function signApnsJwt(key: CryptoKey, keyId: string, teamId: string, iat: number): Promise<string>;
