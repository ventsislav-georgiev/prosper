// Runs plugin-host.js in a child bun against fake plugins in a temp dir and checks the
// opencode hook inputs it builds from codex events (#183, #949). Run: bun test app/plugin-host
import { afterAll, beforeAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { connect } from "node:net";

const startedBefore = Date.now() - 1;
const root = mkdtempSync(join(tmpdir(), "pph-"));
const pluginsDir = join(root, "plugins");
const outDir = join(root, "out");
const sock = join(root, "s.sock");
const logFile = join(root, "host.log");
let host;

// Each recording hook writes what it received to out/<plugin>-<hook>-<session>.json.
const record = (name) => `(hook) => async (input, output) => {
  writeFileSync(${JSON.stringify(outDir)} + "/${name}-" + hook + "-" + (input.sessionID || "none") + ".json",
    JSON.stringify(input));
}`;
// A counting hook appends one line per call to out/<name>-<session>.count.
const count = (name) => `async (input) => {
  appendFileSync(${JSON.stringify(outDir)} + "/${name}-" + input.sessionID + ".count", "x\\n");
}`;
// Bad default exports beside a working named factory; "zok" sorts after "default" in the
// module namespace, so it proves a skipped default does not stop the loop.
const badDefault = (file, def) => `import { writeFileSync } from "node:fs";
const rec = ${record(file)};
export default ${def};
export const zok = async () => ({ "tool.execute.after": rec("after") });`;

const plugins = {
  // Uses PluginInput.experimental_workspace like the published example-workspace plugin does.
  "recorder.js": `import { writeFileSync } from "node:fs";
const rec = ${record("recorder")};
export const Recorder = async (ctx) => {
  ctx.experimental_workspace.register("folder", { name: "Folder" });
  return { "tool.execute.after": rec("after"), "permission.ask": rec("ask") };
};`,
  // Written against the old host input: reads only input.tool / sessionID / callID.
  "old.js": `export const Old = async () => ({
  "permission.ask": async (input, output) => {
    if (input.tool === "Bash" && input.sessionID === "s-old") output.status = "deny";
  },
  "tool.execute.after": async (input) => {
    if (input.tool === "Danger") throw new Error("blocked by test");
  },
});`,
  // A throwing factory must not take its sibling factory in the same module down.
  "two.js": `import { writeFileSync } from "node:fs";
const rec = ${record("two")};
export const AThrows = async () => { throw new Error("factory boom"); };
export const BWorks = async () => ({ "tool.execute.after": rec("after") });`,
  // A module that fails to import must not take the host down.
  "bad.js": "export const = ;",
  // opencode's PluginModule form; its server reads serverUrl and project like a plugin may.
  "objdefault.js": `import { writeFileSync } from "node:fs";
const rec = ${record("objdefault")};
export default {
  id: "objdefault",
  server: async (ctx) => {
    const { serverUrl, project, worktree } = ctx;
    writeFileSync(${JSON.stringify(outDir)} + "/ctx.json", JSON.stringify({ hasServerUrlKey: "serverUrl" in ctx,
      serverUrl: serverUrl === undefined ? "undefined" : String(serverUrl),
      projectWorktreeIsWorktree: project?.worktree === worktree, project }));
    return { "tool.execute.after": rec("after") };
  },
};`,
  // The same factory exported twice runs once; a second, different factory still runs.
  "twice.js": `import { appendFileSync } from "node:fs";
const P = async () => ({ "tool.execute.after": ${count("twiceP")} });
export const Named = P;
export default P;
export const Other = async () => ({ "tool.execute.after": ${count("twiceOther")} });`,
  // The same factory as a named export and as the default's server runs once.
  "twice2.js": `import { appendFileSync } from "node:fs";
export const Q = async () => ({ "tool.execute.after": ${count("twiceQ")} });
export default { server: Q };`,
  "def-str.js": badDefault("defstr", '"not a plugin"'),
  "def-null.js": badDefault("defnull", "null"),
  "def-arr.js": badDefault("defarr", "[async () => ({})]"),
  "def-obj.js": badDefault("defobj", '{ id: "x", server: "nope" }'),
  "def-getter.js": badDefault("defgetter", '{ get server() { throw new Error("getter boom"); } }'),
};

function ask(payload) {
  return new Promise((resolve, reject) => {
    let buf = "";
    const c = connect(sock);
    const timer = setTimeout(() => { c.destroy(); reject(new Error("no reply")); }, 5000);
    c.on("connect", () => c.write(typeof payload === "string" ? payload : JSON.stringify(payload)));
    c.on("data", (d) => { buf += d.toString(); });
    c.on("error", (e) => { clearTimeout(timer); reject(e); });
    c.on("close", () => {
      clearTimeout(timer);
      try { resolve(JSON.parse(buf)); } catch { reject(new Error(`bad reply: ${buf}`)); }
    });
  });
}

const seen = (name) => {
  const p = join(outDir, `${name}.json`);
  return existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : undefined;
};

beforeAll(async () => {
  mkdirSync(pluginsDir);
  mkdirSync(outDir);
  for (const [name, src] of Object.entries(plugins)) writeFileSync(join(pluginsDir, name), src);
  host = Bun.spawn([process.execPath, join(import.meta.dir, "plugin-host.js")], {
    env: { PATH: process.env.PATH ?? "/usr/bin:/bin", PROSPER_PLUGINS_DIR: pluginsDir, PROSPER_PLUGIN_SOCKET: sock },
    stdout: "ignore", stderr: Bun.file(logFile),
  });
  for (let i = 0; i < 200 && !existsSync(sock); i++) await Bun.sleep(50);
  if (!existsSync(sock)) throw new Error("plugin host did not start");
}, 15000);

afterAll(async () => {
  if (host) { host.kill(); await host.exited; }
  rmSync(root, { recursive: true, force: true });
});

test("advertises the events the loaded plugins handle", () => {
  const events = JSON.parse(readFileSync(join(pluginsDir, ".events.json"), "utf8"));
  expect(events.sort()).toEqual(["PermissionRequest", "PostToolUse"]);
});

test("tool.execute.after gets tool, sessionID, callID and args", async () => {
  const reply = await ask({ hook_event_name: "PostToolUse", session_id: "s-after", tool_name: "Bash",
    tool_use_id: "call-1", tool_input: { command: "ls /Users/example" }, tool_response: "ok", turn_id: "t-1" });
  expect(reply).toEqual({});
  const want = { tool: "Bash", sessionID: "s-after", callID: "call-1", args: { command: "ls /Users/example" } };
  expect(seen("recorder-after-s-after")).toEqual(want);
  expect(seen("two-after-s-after")).toEqual(want);   // sibling of a throwing factory still loaded
});

test("tool.execute.after without tool_input gets empty args", async () => {
  await ask({ hook_event_name: "PostToolUse", session_id: "s-noargs", tool_name: "Read", tool_use_id: "call-2" });
  expect(seen("recorder-after-s-noargs")?.args).toEqual({});
});

test("a throwing tool.execute.after hook blocks, as before", async () => {
  const reply = await ask({ hook_event_name: "PostToolUse", session_id: "s-danger", tool_name: "Danger",
    tool_use_id: "call-3", tool_input: {} });
  expect(reply).toEqual({ decision: "block", reason: "blocked by test" });
});

test("permission.ask gets a Permission-shaped input", async () => {
  const before = Date.now();
  const reply = await ask({ hook_event_name: "PermissionRequest", session_id: "s-perm", tool_name: "Bash",
    tool_input: { command: "rm -rf /Users/example/tmp" }, turn_id: "turn-9" });
  expect(reply).toEqual({});
  const got = seen("recorder-ask-s-perm");
  expect(typeof got?.id).toBe("string");
  expect(got?.id.length).toBeGreaterThan(0);
  expect(got?.time?.created).toBeGreaterThanOrEqual(before);
  expect(got?.time?.created).toBeLessThanOrEqual(Date.now());
  const { id, time, ...rest } = got ?? {};
  // callID is undefined (codex sends no tool_use_id here) and drops out of the JSON.
  expect(rest).toEqual({ type: "bash", sessionID: "s-perm", messageID: "turn-9", title: "Bash",
    metadata: { command: "rm -rf /Users/example/tmp" }, tool: "Bash" });
});

test("permission.ask tolerates missing and non-object fields", async () => {
  await ask({ hook_event_name: "PermissionRequest", session_id: "s-odd", tool_input: ["x"] });
  const got = seen("recorder-ask-s-odd");
  expect(got?.metadata).toEqual({});
  expect(got?.type).toBe("");
  expect(got?.title).toBe("");
  expect(got?.messageID).toBe("");
  await ask({ hook_event_name: "PermissionRequest", session_id: "s-str", tool_name: "Bash", tool_input: "ls" });
  expect(seen("recorder-ask-s-str")?.metadata).toEqual({});
});

test("an old-shape permission.ask plugin still decides", async () => {
  const reply = await ask({ hook_event_name: "PermissionRequest", session_id: "s-old", tool_name: "Bash",
    tool_input: { command: "ls" }, turn_id: "t" });
  expect(reply).toEqual({ hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "deny" } } });
});

test("a non-object event fails open", async () => {
  expect(await ask("null")).toEqual({});
});

// ---- #949 ----

const lines = (name) => {
  const p = join(outDir, `${name}.count`);
  return existsSync(p) ? readFileSync(p, "utf8").split("\n").filter(Boolean).length : 0;
};

test("a default-export object (PluginModule) has its server loaded", async () => {
  await ask({ hook_event_name: "PostToolUse", session_id: "s-obj", tool_name: "Read", tool_use_id: "c" });
  expect(seen("objdefault-after-s-obj")?.tool).toBe("Read");
});

test("a factory exported twice runs once; a second factory in the module runs too", async () => {
  await ask({ hook_event_name: "PostToolUse", session_id: "s-twice", tool_name: "Read", tool_use_id: "c" });
  expect(lines("twiceP-s-twice")).toBe(1);
  expect(lines("twiceOther-s-twice")).toBe(1);
  expect(lines("twiceQ-s-twice")).toBe(1);
});

test("a default export that is not a plugin is skipped with one log line, siblings load", async () => {
  await ask({ hook_event_name: "PostToolUse", session_id: "s-bad", tool_name: "Read", tool_use_id: "c" });
  for (const f of ["defstr", "defnull", "defarr", "defobj", "defgetter"]) {
    expect(seen(`${f}-after-s-bad`)?.tool).toBe("Read");
  }
  const log = readFileSync(logFile, "utf8");
  for (const f of ["def-str.js", "def-null.js", "def-arr.js", "def-obj.js"]) {
    expect(log.split(`default export of ${join(pluginsDir, f)} is not a plugin, skipped`).length).toBe(2);
  }
  expect(log).toContain(`factory default in ${join(pluginsDir, "def-getter.js")} threw`);
});

test("permission.ask type is opencode's kind; codex's name stays in tool", async () => {
  const cases = [
    ["Bash", "bash"],
    ["apply_patch", "edit"],
    ["mcp__fs__read_file", "mcp__fs__read_file"],
    ["constructor", "constructor"],
  ];
  for (const [i, [name, kind]] of cases.entries()) {
    await ask({ hook_event_name: "PermissionRequest", session_id: `s-kind${i}`, tool_name: name, tool_input: {} });
    const got = seen(`recorder-ask-s-kind${i}`);
    expect({ type: got?.type, tool: got?.tool, title: got?.title }).toEqual({ type: kind, tool: name, title: name });
  }
  await ask({ hook_event_name: "PermissionRequest", session_id: "s-kindnum", tool_name: 5, tool_input: {} });
  const got = seen("recorder-ask-s-kindnum");
  expect({ type: got?.type, tool: got?.tool, title: got?.title }).toEqual({ type: "", tool: 5, title: "" });
});

test("PluginInput: serverUrl is undefined, project has worktree and time.created", () => {
  const ctx = JSON.parse(readFileSync(join(outDir, "ctx.json"), "utf8"));
  expect(ctx.serverUrl).toBe("undefined");
  expect(ctx.hasServerUrlKey).toBe(true);   // declared, not forgotten
  expect(ctx.projectWorktreeIsWorktree).toBe(true);
  expect(ctx.project.id).toBe("prosper");
  expect(typeof ctx.project.worktree).toBe("string");
  expect(ctx.project.worktree.length).toBeGreaterThan(0);
  expect(ctx.project.time.created).toBeGreaterThan(startedBefore);
  expect(ctx.project.time.created).toBeLessThanOrEqual(Date.now());
});
