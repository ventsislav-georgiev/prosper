#!/usr/bin/env python3
"""Record the codex app-server wire for the pinned codex, for CodexWireSchemaTests.

Usage: scripts/record-codex-wire.py <codex binary>

Writes app/Tests/Fixtures/codex/<version>/: the binary's generated JSON schema
(`codex app-server generate-json-schema`) and one JSONL transcript per scenario, each line
{"dir": "out"|"in", "frame": {...}} ("out" = client→codex, in the frame shapes
CodexHarness sends). Inference is a local fake Responses endpoint; CODEX_HOME is a
throwaway dir. Paths, host name, installation id and user agent are scrubbed.
Run on every pin bump (AgentController.codexVersion); the tests fail until the fixture
directory for the pinned version exists.
"""
import json, os, queue, re, shutil, socket, subprocess, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIN = sys.argv[1]
VERSION = subprocess.run([BIN, "--version"], capture_output=True, text=True, check=True).stdout.split()[-1]
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "app", "Tests", "Fixtures", "codex", VERSION)
FIXTURE_ROOT = "/tmp/codex-wire"   # what the scratch dir becomes in the fixtures


def sse(kind, body):
    body["type"] = kind
    return ("event: %s\ndata: %s\n\n" % (kind, json.dumps(body))).encode()


def message(text):
    return {"type": "message", "id": "msg_1", "role": "assistant", "status": "completed",
            "content": [{"type": "output_text", "text": text, "annotations": []}]}


def call(name, args):
    return {"type": "function_call", "id": "fc_1", "call_id": "call_1", "name": name,
            "arguments": json.dumps(args), "status": "completed"}


class Responses(BaseHTTPRequestHandler):
    """First model call per prompt keyword; the follow-up (after a tool output) says "done"."""
    def log_message(self, *a):
        pass

    def do_GET(self):
        out = json.dumps({"object": "list", "data": [], "models": []}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
        items = req.get("input", [])
        prompt = json.dumps([i for i in items if i.get("role") == "user"][-1:])
        if any(i.get("type") == "function_call_output" for i in items):
            item = message("done")
        elif "FAIL" in prompt:
            body = json.dumps({"error": {"message": "fake endpoint: bad request", "type": "invalid_request_error"}}).encode()
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        elif "APPROVE" in prompt:
            item = call("exec_command", {"cmd": "touch approved.txt"})
        elif "HANG" in prompt:
            item = call("exec_command", {"cmd": "sleep 30", "yield_time_ms": 30000})
        else:
            item = message("Hello")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        self.wfile.write(sse("response.created", {"response": {"id": "resp_1", "status": "in_progress", "output": []}}))
        self.wfile.write(sse("response.output_item.added", {"output_index": 0, "item": item}))
        if item["type"] == "message":   # streamed like ProsperLLMServer: codex emits item/agentMessage/delta
            self.wfile.write(sse("response.output_text.delta", {"item_id": item["id"], "output_index": 0,
                                                                "content_index": 0, "delta": item["content"][0]["text"]}))
        self.wfile.write(sse("response.output_item.done", {"output_index": 0, "item": item}))
        self.wfile.write(sse("response.completed", {"response": {"id": "resp_1", "status": "completed", "output": [item],
                         "usage": {"input_tokens": 10, "output_tokens": 5, "total_tokens": 15}}}))
        self.wfile.flush()
        self.close_connection = True


class Codex:
    """One app-server process; every frame either way is appended to `frames`."""
    def __init__(self, scratch, port):
        self.scratch, self.frames, self.inbox, self.next_id = scratch, [], queue.Queue(), 1
        home = os.path.join(scratch, "home")
        os.makedirs(home, exist_ok=True)
        with open(os.path.join(home, "config.toml"), "w") as f:   # the provider table CodexHarness writes
            f.write('model = "test-model"\nmodel_provider = "prosper"\n\n[model_providers.prosper]\n'
                    'name = "Prosper local MLX"\nbase_url = "http://127.0.0.1:%d/v1"\nwire_api = "responses"\n'
                    'env_key = "PROSPER_LLM_TOKEN"\nstream_max_retries = 0\nrequest_max_retries = 1\n'
                    'stream_idle_timeout_ms = 120000\n' % port)
        env = dict(os.environ, CODEX_HOME=home, PROSPER_LLM_TOKEN="test-token")
        self.proc = subprocess.Popen([BIN, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, env=env, text=True, cwd=scratch)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            frame = json.loads(line)
            self.frames.append({"dir": "in", "frame": frame})
            self.inbox.put(frame)

    def send(self, frame):
        self.frames.append({"dir": "out", "frame": frame})
        self.proc.stdin.write(json.dumps(frame) + "\n")
        self.proc.stdin.flush()

    def request(self, method, params):
        rid, self.next_id = self.next_id, self.next_id + 1
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        return self.wait(lambda f: f.get("id") == rid and "method" not in f)

    def wait(self, pred, timeout=30):
        end = time.time() + timeout
        while time.time() < end:
            try:
                f = self.inbox.get(timeout=end - time.time())
            except queue.Empty:
                break
            if pred(f):
                return f
        raise SystemExit("timed out waiting in %s; last frames: %s" % (self.scratch, self.frames[-3:]))

    def handshake(self):
        self.request("initialize", {"clientInfo": {"name": "prosper", "title": "Prosper", "version": "dev"}})
        self.send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

    def thread(self, approval, sandbox):
        r = self.request("thread/start", {"cwd": self.work, "model": "test-model", "approvalPolicy": approval,
                                          "sandbox": sandbox, "config": {"bypass_hook_trust": True}})
        return r["result"]["thread"]["id"]

    @property
    def work(self):
        return os.path.join(self.scratch, "work")

    def turn(self, thread, inputs, policy):
        r = self.request("turn/start", {"threadId": thread, "input": inputs, "sandboxPolicy": policy})
        return r["result"]["turn"]["id"]

    def turn_completed(self, thread):
        return self.wait(lambda f: f.get("method") == "turn/completed" and f["params"]["threadId"] == thread)

    def close(self):
        time.sleep(0.5)   # trailing notifications (thread/status/changed …)
        self.proc.terminate()
        self.proc.wait()


def text(t):
    return {"type": "text", "text": t}


def plain(c):
    """A text+localImage turn under workspace-write, then fork and resume the thread."""
    tid = c.thread("on-request", "workspace-write")
    shutil.copy(os.path.join(c.scratch, "..", "red.png"), os.path.join(c.work, "red.png"))
    c.turn(tid, [text("say hello"), {"type": "localImage", "path": os.path.join(c.work, "red.png")}],
           {"type": "workspaceWrite", "writableRoots": [c.work], "networkAccess": False})
    c.turn_completed(tid)
    c.request("thread/fork", {"threadId": tid, "config": {"bypass_hook_trust": True}})
    c.request("thread/resume", {"threadId": tid, "approvalPolicy": "never", "sandbox": "workspace-write",
                                "config": {"bypass_hook_trust": True}})


def approval(c):
    """A command approval answered "accept"; the command runs and the turn completes."""
    tid = c.thread("untrusted", "workspace-write")
    c.turn(tid, [text("APPROVE a touch")],
           {"type": "workspaceWrite", "writableRoots": [c.work], "networkAccess": False})
    req = c.wait(lambda f: f.get("method") == "item/commandExecution/requestApproval")
    c.send({"jsonrpc": "2.0", "id": req["id"], "result": {"decision": "accept"}})
    c.turn_completed(tid)


def interrupt(c):
    """A read-only thread running `sleep 30`: steer it, then interrupt it."""
    tid = c.thread("never", "read-only")
    turn = c.turn(tid, [text("HANG on a long command")], {"type": "readOnly"})
    c.wait(lambda f: f.get("method") == "item/started" and f["params"]["item"]["type"] == "commandExecution")
    c.request("turn/steer", {"threadId": tid, "expectedTurnId": turn, "input": [text("also list hidden files")]})
    c.request("turn/interrupt", {"threadId": tid, "turnId": turn})
    c.turn_completed(tid)


def failed(c):
    """The model endpoint answers 400: the turn completes `failed` with the error."""
    tid = c.thread("never", "danger-full-access")
    c.turn(tid, [text("FAIL please")], {"type": "dangerFullAccess"})
    c.turn_completed(tid)


def png(path):
    import struct, zlib
    raw = b"".join(b"\x00" + b"\xff\x00\x00" * 4 for _ in range(4))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 4, 4, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def scrub(line, scratch):
    for real in sorted({scratch, os.path.realpath(scratch)}, key=len, reverse=True):
        line = line.replace(real, FIXTURE_ROOT)
    line = line.replace(os.path.expanduser("~"), "/Users/user")
    line = line.replace(socket.gethostname(), "host").replace(socket.gethostname().split(".")[0], "host")
    line = re.sub(r'"installationId": ?"[^"]*"', '"installationId":"00000000-0000-0000-0000-000000000000"', line)
    return re.sub(r'"userAgent": ?"prosper/([^ "]+)[^"]*"', r'"userAgent":"prosper/\1 (Mac OS; arm64) (prosper; dev)"', line)


def main():
    os.makedirs(OUT, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="codex-wire-")
    try:
        subprocess.run([BIN, "app-server", "generate-json-schema", "--out", os.path.join(tmp, "schema")], check=True)
        shutil.copy(os.path.join(tmp, "schema", "codex_app_server_protocol.schemas.json"), OUT)
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), Responses)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        png(os.path.join(tmp, "red.png"))
        for name, scenario in [("plain-turn", plain), ("approval", approval), ("interrupt", interrupt),
                               ("failed-turn", failed)]:
            scratch = os.path.join(tmp, name)
            os.makedirs(os.path.join(scratch, "work"))
            c = Codex(scratch, httpd.server_address[1])
            c.handshake()
            scenario(c)
            c.close()
            with open(os.path.join(OUT, name + ".jsonl"), "w") as f:
                for entry in c.frames:
                    f.write(scrub(json.dumps(entry, separators=(",", ":")), scratch) + "\n")
            print("recorded %s: %d frames" % (name, len(c.frames)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


main()
