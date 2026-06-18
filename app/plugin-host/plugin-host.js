#!/usr/bin/env bun
// Prosper plugin host — bridges codex's Claude-Code-shaped lifecycle hooks to the
// opencode plugin contract, so opencode JS/TS plugins run unmodified inside Prosper.
//
// codex (the agent app-server) fires a hook by running a `command` with the event JSON
// on stdin and reading a decision from stdout. Our generated hook command is a thin
// `nc -U <socket>` client (no Bun cold-start per call). This host owns the socket:
// it loads the plugins ONCE at app launch, then for each request normalizes the codex
// event into opencode's (input, output) pair, runs the matching plugin hooks, and
// serializes the decision back into codex's hook-output JSON.
//
// Protocol: one request per connection. Client writes one JSON object (the codex event),
// host replies with one JSON line, then closes. A parse/dispatch failure replies `{}`
// (fail-open — codex proceeds), matching codex's own hook-error behavior.
//
// ponytail: only the three controllable events are bridged (PreToolUse arg-rewrite/deny,
// PostToolUse block, PermissionRequest allow/deny). codex rejects PostToolUse result
// rewrite (`updatedMCPToolOutput` is unsupported), and lifecycle events (Stop, etc.) are
// observe-only in opencode — use a plain shell hook for loop control instead.

import { existsSync, readdirSync, writeFileSync, renameSync, watch } from "node:fs";
import { join } from "node:path";

const HOOK_TIMEOUT_MS = 15_000;   // a wedged plugin hook can't stall a tool call forever
const MAX_FRAME_BYTES = 8 * 1024 * 1024;   // cap the per-connection request buffer
// structuredClone is native on Bun 1.3.14; fall back if an older bun is on PATH.
const clone = typeof structuredClone === "function"
  ? structuredClone
  : (v) => JSON.parse(JSON.stringify(v));

const PLUGINS_DIR = process.env.PROSPER_PLUGINS_DIR
  || join(process.env.HOME || ".", ".config/prosper/plugins");
const SOCKET = process.env.PROSPER_PLUGIN_SOCKET || join(PLUGINS_DIR, ".host.sock");
const EVENTS_FILE = join(PLUGINS_DIR, ".events.json");

// opencode hook name -> codex event it maps to. Drives both dispatch and the event
// set we advertise to Swift (so codex only wires hooks a plugin actually handles).
const HOOK_TO_EVENT = {
  "tool.execute.before": "PreToolUse",
  "tool.execute.after": "PostToolUse",
  "permission.ask": "PermissionRequest",
};

// ---- plugin loading -------------------------------------------------------

/** Call every exported plugin factory in a module and collect the hooks it returns. */
async function loadModule(path, ctx) {
  const mod = await import(path);
  const collected = [];
  for (const value of Object.values(mod)) {
    if (typeof value !== "function") continue;
    try {
      const hooks = await value(ctx);
      if (hooks && typeof hooks === "object") collected.push(hooks);
    } catch (err) {
      console.error(`prosper-plugin-host: factory in ${path} threw:`, err);
    }
  }
  return collected;
}

async function loadPlugins() {
  if (!existsSync(PLUGINS_DIR)) return [];
  // opencode plugin context. `client` (HTTP to an opencode server) is absent here —
  // almost no community plugin uses it; the ones that do degrade gracefully.
  const ctx = {
    project: { id: "prosper" },
    directory: process.cwd(),
    worktree: process.cwd(),
    client: undefined,
    $: Bun.$,
  };
  const hooks = [];
  for (const name of readdirSync(PLUGINS_DIR)) {
    if (name.startsWith(".") || !/\.(m?[jt]s)$/.test(name)) continue;
    try {
      hooks.push(...(await loadModule(join(PLUGINS_DIR, name), ctx)));
    } catch (err) {
      console.error(`prosper-plugin-host: failed to load ${name}:`, err);
    }
  }
  return hooks;
}

// ---- event dispatch -------------------------------------------------------

/** Run a single opencode hook across all plugins that define it, in order. A hook that
 *  hangs (never-resolving await) would stall the connection — and the tool call behind
 *  it — indefinitely, so each is bounded by a timeout that rejects (caller fails open). */
async function runHooks(plugins, hookName, input, output) {
  for (const p of plugins) {
    const fn = p[hookName];
    if (typeof fn !== "function") continue;
    let timer;
    const timeout = new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`${hookName} timed out`)), HOOK_TIMEOUT_MS);
    });
    try { await Promise.race([fn(input, output), timeout]); }
    finally { clearTimeout(timer); }
  }
}

/** codex event JSON -> codex decision JSON. Throws bubble up to the caller (fail-open). */
async function dispatch(plugins, evt) {
  const event = evt.hook_event_name;
  const base = { session_id: evt.session_id, tool: evt.tool_name };

  if (event === "PreToolUse") {
    const input = { tool: evt.tool_name, sessionID: evt.session_id, callID: evt.tool_use_id };
    const original = JSON.stringify(evt.tool_input ?? {});
    // Clone so plugin mutation doesn't alias the baseline we diff against.
    const output = { args: clone(evt.tool_input ?? {}) };
    try {
      await runHooks(plugins, "tool.execute.before", input, output);
    } catch (err) {
      return { hookSpecificOutput: { hookEventName: "PreToolUse",
        permissionDecision: "deny", permissionDecisionReason: String(err?.message ?? err) } };
    }
    // Only emit updatedInput when a plugin actually changed the args.
    if (JSON.stringify(output.args) !== original) {
      return { hookSpecificOutput: { hookEventName: "PreToolUse",
        permissionDecision: "allow", updatedInput: output.args } };
    }
    return {};
  }

  if (event === "PostToolUse") {
    const input = { tool: evt.tool_name, sessionID: evt.session_id, callID: evt.tool_use_id };
    // codex rejects result rewrite, so `output.output` mutations are observed but dropped.
    const output = { title: "", output: stringifyResult(evt.tool_response ?? evt.tool_output), metadata: {} };
    try {
      await runHooks(plugins, "tool.execute.after", input, output);
    } catch (err) {
      return { decision: "block", reason: String(err?.message ?? err) };
    }
    return {};
  }

  if (event === "PermissionRequest") {
    const input = { tool: evt.tool_name, sessionID: evt.session_id, callID: evt.tool_use_id };
    const output = { status: "ask" };
    try {
      await runHooks(plugins, "permission.ask", input, output);
    } catch (err) {
      return { hookSpecificOutput: { hookEventName: "PermissionRequest",
        decision: { behavior: "deny", message: String(err?.message ?? err) } } };
    }
    if (output.status === "deny" || output.status === "allow") {
      return { hookSpecificOutput: { hookEventName: "PermissionRequest",
        decision: { behavior: output.status } } };
    }
    return {};  // "ask" -> let codex's normal flow decide
  }

  return {};
}

function stringifyResult(r) {
  if (r == null) return "";
  if (typeof r === "string") return r;
  try { return JSON.stringify(r) ?? ""; } catch { return ""; }   // circular/non-serializable
}

// ---- plugin reload + event advertisement ----------------------------------

// Live plugin set, swapped wholesale on reload so an in-flight dispatch keeps using
// the snapshot it started with (the `plugins` const it captured) — no half-loaded state.
let plugins = [];

/** Reload all plugins and rewrite `.events.json` so Swift wires exactly the codex events
 *  a plugin handles. Atomic write (temp + rename) so a watcher never reads a half file. */
async function loadAndAdvertise() {
  plugins = await loadPlugins();
  // Advertise which codex events to wire. Swift reads this in writeConfig; an empty set
  // means no bridge hooks are emitted (zero per-tool overhead when no plugin handles them).
  const events = [...new Set(
    plugins.flatMap((p) => Object.keys(p))
      .map((h) => HOOK_TO_EVENT[h]).filter(Boolean),
  )];
  const tmp = EVENTS_FILE + ".tmp";
  writeFileSync(tmp, JSON.stringify(events));
  renameSync(tmp, EVENTS_FILE);   // atomic on the same fs; reader never sees a partial
  console.error(`prosper-plugin-host: ${plugins.length} plugin(s), events: ${events.join(",") || "none"}`);
}

await loadAndAdvertise();

// Reload when the plugins dir changes (file added/removed/edited at runtime). Debounced —
// an editor save can fire several events in a burst, and a reload is comparatively heavy.
let reloadTimer;
try {
  watch(PLUGINS_DIR, (_evt, name) => {
    if (name && name.startsWith(".")) return;   // ignore our own .events.json/.host.sock
    clearTimeout(reloadTimer);
    reloadTimer = setTimeout(() => {
      loadAndAdvertise().catch((err) => console.error("prosper-plugin-host: reload failed:", err));
    }, 300);
  });
} catch (err) {
  console.error("prosper-plugin-host: cannot watch plugins dir (no hot reload):", err);
}

// ---- socket server --------------------------------------------------------

// Stale socket from a previous run blocks bind; remove it.
try { await Bun.file(SOCKET).delete(); } catch {}

try {
  Bun.listen({
    unix: SOCKET,
    socket: {
      open(socket) { socket.data = ""; },
      async data(socket, chunk) {
        socket.data += chunk.toString();
        if (socket.data.length > MAX_FRAME_BYTES) {   // runaway/garbage client — drop it
          socket.data = "";
          try { socket.write("{}\n"); socket.end(); } catch {}
          return;
        }
        let evt;
        try { evt = JSON.parse(socket.data); } catch { return; }  // wait for the rest
        // Capture the current plugin snapshot so a mid-dispatch reload can't swap it.
        const snapshot = plugins;
        let decision = {};
        try { decision = await dispatch(snapshot, evt); }
        catch (err) { console.error("prosper-plugin-host: dispatch error:", err); }
        try { socket.write(JSON.stringify(decision) + "\n"); socket.end(); }
        catch (err) { console.error("prosper-plugin-host: write failed:", err); }
      },
      error(_socket, err) { console.error("prosper-plugin-host: socket error:", err); },
    },
  });
} catch (err) {
  // Bind failure (perms, path too long, races) is fatal — without the socket codex's
  // hook command hangs on every tool call. Exit non-zero so the supervisor sees it.
  console.error("prosper-plugin-host: failed to listen on", SOCKET, err);
  process.exit(1);
}
console.error(`prosper-plugin-host: listening on ${SOCKET}`);
