// Types for the D1 side of live session status (kept .mjs so `node --test` runs it raw).
import type { ApnsPush, ApnsResult } from "./pushLogic.mjs";

export type PushDeps = {
  db: D1Database;
  send: (p: ApnsPush) => Promise<ApnsResult>;
  now: () => number;
  defer: (p: Promise<unknown>) => void;
};
export type RouteResult = { status: 204 } | { status: 400 | 403 | 429; error: string };

export function deliver(deps: PushDeps, pushes: ApnsPush[]): Promise<ApnsResult[]>;
export function putToken(deps: PushDeps, email: string, body: unknown): Promise<RouteResult>;
export function deleteTokens(deps: PushDeps, email: string, body: unknown): Promise<RouteResult>;
export function postSessions(deps: PushDeps, email: string, body: unknown): Promise<RouteResult>;
export function runCron(deps: PushDeps): Promise<void>;
export function purgeMacStatements(db: D1Database, email: string, macId: string): D1PreparedStatement[];
export function purgeAccountStatements(db: D1Database, email: string): D1PreparedStatement[];
