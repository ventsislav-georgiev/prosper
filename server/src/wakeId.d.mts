// Types for the pure JS wake-id module (kept .mjs so `node --test` runs it raw).
export const WAKE_ID_RE: RegExp;
export function acctTag(email: string): Promise<string>;
export function ownsWakeId(id: string, email: string): Promise<boolean>;
export const MIN_INTERVAL: number;
export const MAX_INTERVAL: number;
export function clampInterval(v: unknown): number | null;
export function clampPct(v: unknown): number | null;
