// Types for the D1 side of live session status (kept .mjs so `node --test` runs it raw).
import type { ApnsPush, ApnsResult, TokenRow } from "./pushLogic.mjs";

export type PushDeps = {
  db: D1Database;
  send: (p: ApnsPush) => Promise<ApnsResult>;
  now: () => number;
  defer: (p: Promise<unknown>) => void;
  budget?: number; // subrequests per cron run (APNs + D1), default 44
};
export type RouteResult = { status: 204 } | { status: 400 | 403 | 429 | 503; error: string };

export function deliver(deps: PushDeps, pushes: ApnsPush[], alsoDrop?: TokenRow[]): Promise<ApnsResult[]>;
export function putToken(deps: PushDeps, email: string, body: unknown, tokenHash: string): Promise<RouteResult>;
export function deleteTokens(deps: PushDeps, email: string, body: unknown): Promise<RouteResult>;
export function postSessions(deps: PushDeps, email: string, body: unknown): Promise<RouteResult>;
export function runCron(deps: PushDeps): Promise<void>;
export function purgeMacStatements(db: D1Database, email: string, macId: string): D1PreparedStatement[];
export function purgeAccountStatements(db: D1Database, email: string): D1PreparedStatement[];
export function logoutStatements(db: D1Database, tokenHash: string): D1PreparedStatement[];
export function sessionCleanupStatements(db: D1Database, now: number): D1PreparedStatement[];
