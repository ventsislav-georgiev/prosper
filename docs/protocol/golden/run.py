#!/usr/bin/env python3
"""Run the remote-frames golden fixtures against a server at host:port.

Python 3 stdlib only. See ../remote-frames.md, "Golden frames", for the fixture format.

    python3 run.py HOST:PORT [--mutating] [--fixtures DIR] [--timeout SECONDS]

Exit 0 when every fixture that applies passes, 1 on any failure, 2 on bad usage or a host
that refuses the handshake. Without --mutating, fixtures marked "mutating" (07 kill, 08 rename,
12, 14 and 15 attach: each runs dch on the server) are skipped and reported as SKIP.
"""
import argparse
import glob
import json
import os
import re
import socket
import struct
import sys
import time

MAX_SEND = 8 << 20     # the server's send limit, the phone's maxFrame
MAJOR = 1              # this runner's proto major


class Fail(Exception):
    pass


class TimedOut(Fail):
    pass


def unhex(s):
    return bytes.fromhex("".join(s.split()))


def shape_ok(shape, v, path="$"):
    """None when `v` matches `shape`, else the first mismatch as text."""
    if isinstance(shape, str):
        kind, _, rx = shape.partition("~")
        ok = {
            "any": True,
            "string": isinstance(v, str),
            "bool": isinstance(v, bool),
            "int": isinstance(v, int) and not isinstance(v, bool),
            "number": isinstance(v, (int, float)) and not isinstance(v, bool),
            "object": isinstance(v, dict),
            "array": isinstance(v, list),
        }.get(kind)
        if ok is None:
            return f"{path}: unknown shape {shape!r}"
        if not ok:
            return f"{path}: want {kind}, got {json.dumps(v)[:80]}"
        if rx and not re.fullmatch(rx, v):
            return f"{path}: {v!r} does not match {rx!r}"
        return None
    if isinstance(shape, list):
        if not isinstance(v, list):
            return f"{path}: want array"
        for i, e in enumerate(v):
            for s in shape:
                why = shape_ok(s, e, f"{path}[{i}]")
                if why:
                    return why
        return None
    if isinstance(shape, dict):
        if not isinstance(v, dict):
            return f"{path}: want object"
        for k, s in shape.items():
            opt = k.startswith("?")
            key = k[1:] if opt else k
            if key not in v:
                if opt:
                    continue
                return f"{path}: missing key {key!r}"
            why = shape_ok(s, v[key], f"{path}.{key}")
            if why:
                return why
        return None
    return f"{path}: bad shape {shape!r}"


class Conn:
    """One connection. Every wait ends at `self.end`, one deadline per step (arm() sets it),
    so a server that keeps sending cannot stretch a step past its timeout (QA #625 INFO-R3-4)."""

    def __init__(self, addr, timeout):
        self.s = socket.create_connection(addr, timeout=timeout)
        self.timeout = timeout
        self.buf = b""
        self.arm()

    def arm(self, secs=None):
        self.end = time.monotonic() + (self.timeout if secs is None else secs)

    def _recv(self):
        left = self.end - time.monotonic()
        if left <= 0:
            raise socket.timeout
        self.s.settimeout(left)
        return self.s.recv(1 << 16)

    def send(self, data):
        self.s.settimeout(self.timeout)
        self.s.sendall(data)

    def _fill(self, n):
        while len(self.buf) < n:
            try:
                chunk = self._recv()
            except socket.timeout:
                raise TimedOut("timed out waiting for a frame")
            if not chunk:
                return False
            self.buf += chunk
        return True

    def frame(self):
        if not self._fill(5):
            raise Fail("connection closed before a frame")
        t, n = self.buf[0], struct.unpack(">I", self.buf[1:5])[0]
        if n > MAX_SEND:
            raise Fail(f"frame 0x{t:02x} of {n} bytes is over the 8 MiB send limit")
        if not self._fill(5 + n):
            raise Fail("connection closed mid-frame")
        payload, self.buf = self.buf[5:5 + n], self.buf[5 + n:]
        return t, payload

    def closed(self):
        """True once the server closes (EOF or reset); bytes before the close are ignored."""
        try:
            while self._recv():
                pass
            return True
        except socket.timeout:
            return False
        except (ConnectionResetError, BrokenPipeError):
            return True

    def quiet(self, secs):
        """Nothing but 0x10 output for `secs` seconds: any other frame is a reply that should not come."""
        self.arm(secs)
        try:
            while True:
                t, payload = self.frame()
                if t != 0x10:
                    raise Fail(f"want no reply, got 0x{t:02x} {payload[:80]!r}")
        except TimedOut:
            pass

    def close(self):
        self.s.close()


def check_frame(want, t, payload):
    if t != int(want["type"], 16):
        return f"want type 0x{want['type']}, got 0x{t:02x} {payload[:80]!r}"
    if "payload" in want and payload != unhex(want["payload"]):
        return f"want payload {want['payload']!r}, got {payload.hex()[:160]}"
    if want.get("nonempty") and not payload:
        return "want a non-empty payload"
    if "json" in want:
        try:
            v = json.loads(payload)
        except ValueError:
            return f"payload is not JSON: {payload[:80]!r}"
        return shape_ok(want["json"], v)
    return None


def run(fx, addr, timeout):
    c = Conn(addr, timeout)
    try:
        for step in fx["steps"]:
            c.arm()
            if "send" in step:
                c.send(unhex(step["send"]))
            elif "expect" in step:
                why = check_frame(step["expect"], *c.frame())
                if why:
                    raise Fail(why)
            elif "expect_quiet" in step:
                c.quiet(float(step["expect_quiet"]))
            elif step.get("expect_close"):
                if not c.closed():
                    raise Fail("the server did not close the connection")
    finally:
        c.close()


def handshake(addr, timeout):
    c = Conn(addr, timeout)
    try:
        c.send(unhex("08 00000000"))
        t, payload = c.frame()
    finally:
        c.close()
    if t != 0x18:
        raise Fail(f"0x08 answered 0x{t:02x}")
    info = json.loads(payload)
    major = int(str(info.get("proto", "1.0")).split(".")[0])
    if major > MAJOR:
        raise Fail(f"proto {info['proto']} is newer than {MAJOR}.x: refusing")
    return info


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("target", help="host:port")
    ap.add_argument("--mutating", action="store_true", help="also run fixtures that change server state")
    ap.add_argument("--fixtures", default=os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--timeout", type=float, default=5)
    a = ap.parse_args(argv)
    host, _, port = a.target.rpartition(":")
    if not host or not port.isdigit():
        ap.error("target must be host:port")
    addr = (host.strip("[]"), int(port))
    try:
        info = handshake(addr, a.timeout)
    except (Fail, OSError, ValueError) as e:
        print(f"FAIL handshake: {e}")
        return 2
    ops = set(info.get("ops") or [])
    print(f"server={info.get('server')} proto={info.get('proto')} os={info.get('os')} ops={sorted(ops)}")
    failed = 0
    for path in sorted(glob.glob(os.path.join(a.fixtures, "*.json"))):
        with open(path) as f:
            fx = json.load(f)
        op = fx.get("requires_op")
        if op and op not in ops:
            print(f"SKIP {fx['id']}: {op!r} not in ops")
            continue
        if fx.get("mutating") and not a.mutating:
            print(f"SKIP {fx['id']}: mutating (pass --mutating)")
            continue
        try:
            run(fx, addr, a.timeout)
            print(f"PASS {fx['id']}")
        except (Fail, OSError) as e:
            failed += 1
            print(f"FAIL {fx['id']}: {e}")
        finally:
            for hx in fx.get("cleanup", []):
                try:
                    c = Conn(addr, a.timeout)
                    c.send(unhex(hx))
                    c.frame()
                    c.close()
                except (Fail, OSError):
                    pass
    print("FAILED" if failed else "OK", f"({failed} failed)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
