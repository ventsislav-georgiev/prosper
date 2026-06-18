import type { Ctx } from "./types";

/**
 * Public, unauthenticated: the most-recent distinct supporter display names
 * (capped at 100), newest first. Re-supporting bumps a name back to the top
 * because we order by the latest order's timestamp. Names are deduped so a
 * repeat supporter appears once, at their most recent position.
 */
export async function listSupporters(c: Ctx) {
  const rows = await c.env.DB.prepare(
    `SELECT name, MAX(issued_at) AS t
     FROM supporter_tokens
     WHERE type = 'supporter' AND status = 'active'
       AND name IS NOT NULL AND name != ''
     GROUP BY name
     ORDER BY t DESC
     LIMIT 100`,
  ).all<{ name: string; t: number }>();

  const supporters = (rows.results ?? []).map((r) => r.name);
  return c.json({ supporters });
}
