#!/usr/bin/env python3
"""Mutation-check runner (#1578). Stdlib only; run with python3 -I.

  run.py [--dry-run] [--root DIR] [--logs DIR] [--timeout S] LIST.json...
  run.py --plan --shards N [--budget S] [--lists GLOB] [--since REV [--weekday D]] [--root DIR]   (prints a GitHub matrix)

--since REV keeps only the lists touched in REV..HEAD (see changed_lists; an unknown REV keeps all) plus the
weekday's rotation slice (entry % 7 == D, 0 = Monday, default today UTC) as far as --shards x --budget allows.

Each list is {"entry", "filter", "mutants": [{"name", "file", "old", "new", "expect"}]}
(see README.md). Per list the filter runs once unmutated (it must pass and run tests,
or every mutant would read as killed); then per mutant: apply, build, test, restore.
Results: KILLED (tests red), SURVIVED (tests green), BROKEN (apply failed, build error
or red baseline), HANG (timeout). Exit 1 if a "killed" mutant SURVIVED or any is
BROKEN, HANG or NOT RUN (--budget spent). --dry-run applies and restores the text only and runs no swift.
"""
import argparse
import datetime
import glob
import json
import os
import re
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
LISTS = os.path.join(HERE, "lists")
# Never mutate a clipboard, event, defaults, delete or sandbox guard (the operator's rule).
GUARD = re.compile(r"pasteboard|cgevent|userdefaults|\bdefaults\b|remove(item|file)|trashitem|unlink|rmdir|delet|sandbox", re.I)
SWIFT = ["swift"]
FLAGS = ["--disable-keychain", "--build-system", "native"]


def problems(lst):
    """Schema and safety errors of one parsed list; [] when it is fine."""
    errs = []
    if not isinstance(lst, dict) or not isinstance(lst.get("filter"), str) or not lst["filter"].strip():
        return ["needs a non-empty string 'filter'"]
    if "entry" not in lst:
        errs.append("needs 'entry'")
    ms = lst.get("mutants")
    if not isinstance(ms, list) or not ms:
        return errs + ["needs a non-empty 'mutants' array"]
    seen = set()
    for i, m in enumerate(ms):
        if not isinstance(m, dict):
            errs.append(f"mutant {i}: not an object")
            continue
        n = m.get("name")
        if not isinstance(n, str) or not n or n in seen:
            errs.append(f"mutant {i}: missing or duplicate name")
        seen.add(n)
        f = m.get("file")
        if not isinstance(f, str) or not f or os.path.isabs(f) or ".." in f.split("/"):
            errs.append(f"{n}: 'file' must be repo-relative")
        if not isinstance(m.get("old"), str) or not m["old"] or not isinstance(m.get("new"), str) or m["old"] == m["new"]:
            errs.append(f"{n}: 'old' (non-empty) and 'new' must be strings that differ")
        elif GUARD.search(m["old"] + "\n" + m["new"] + "\n" + f):
            errs.append(f"{n}: touches a clipboard, event, defaults, delete or sandbox guard")
        if m.get("expect") not in ("killed", "survives"):
            errs.append(f"{n}: 'expect' must be killed or survives")
    return errs


class Mutant:
    """Applies one mutant; restores the file byte for byte on exit, also on an exception."""

    def __init__(self, root, m):
        self.path = os.path.join(root, m["file"])
        self.m = m
        self.orig = None

    def __enter__(self):
        with open(self.path, "rb") as fh:
            self.orig = fh.read()
        text = self.orig.decode("utf-8")
        n = text.count(self.m["old"])
        if n != 1:
            raise ValueError(f"'old' occurs {n} times in {self.m['file']}")
        want = text.replace(self.m["old"], self.m["new"]).encode("utf-8")
        try:
            with open(self.path, "wb") as fh:
                fh.write(want)
            with open(self.path, "rb") as fh:
                if fh.read() != want or want == self.orig:
                    raise ValueError("the change did not land")
        except BaseException:  # __exit__ does not run when __enter__ raises
            self.__exit__()
            raise
        return self

    def __exit__(self, *exc):
        if self.orig is not None:
            with open(self.path, "wb") as fh:
                fh.write(self.orig)
            with open(self.path, "rb") as fh:
                assert fh.read() == self.orig, f"restore of {self.path} failed"
        return False


def swift(args, app, log, timeout):
    """Runs swift in its own process group; returns (exit code or None on timeout, output)."""
    env = dict(os.environ, PROSPER_HEAVY_TESTS="1", NSUnbufferedIO="YES")
    # Same SDK as test.yml; the python3 shim would otherwise hand down the CLT SDK.
    env["SDKROOT"] = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                                    capture_output=True, text=True, check=True).stdout.strip()
    with open(log, "ab") as out:
        out.write(("$ swift " + " ".join(args) + "\n").encode())
        out.flush()
        p = subprocess.Popen(SWIFT + args, cwd=app, env=env, stdout=out, stderr=subprocess.STDOUT,
                             start_new_session=True)
        try:
            rc = p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            rc = None
        finally:
            if p.poll() is None:  # timeout or interrupt: end the run and its xctest child
                os.killpg(p.pid, signal.SIGKILL)
                p.wait()
    with open(log, "rb") as fh:
        return rc, fh.read().decode("utf-8", "replace")


_TEST_FILES = {}


def test_files(root):
    """Per app/Tests file: (classes declared, classes declared or extended, funcs); read once per root."""
    if root not in _TEST_FILES:
        out = []
        for d, _, fs in os.walk(os.path.join(root, "app", "Tests")):
            for f in fs:
                if f.endswith(".swift"):
                    with open(os.path.join(d, f), encoding="utf-8", errors="replace") as fh:
                        t = fh.read()
                    own = set(re.findall(r"\bclass\s+(\w+)", t))  # also matches `final class`
                    out.append((own, own | set(re.findall(r"\bextension\s+(\w+)", t)), re.findall(r"\bfunc\s+(\w+)", t)))
        _TEST_FILES[root] = out
    return _TEST_FILES[root]


def filter_problems(flt, root):
    """--dry-run: every plain Class or Class/test in the filter must select a test in app/Tests.
    A Class must be declared as a class (an extension adds rows, its file name is not a class);
    a Class/test needs `func test` in a file that declares or extends the class."""
    files = test_files(root)
    errs = []
    try:
        re.compile(flt)
    except re.error as e:
        errs.append(f"filter is not a valid regex: {e}")
    alts = []
    for alt in re.split(r"\|(?![^()]*\))", flt):  # split on | outside parentheses
        g = re.fullmatch(r"(\w+)/\((.*)\)", alt)
        alts += [g.group(1) + "/" + t for t in g.group(2).split("|")] if g else [alt]
    for alt in alts:
        cls, _, fn = alt.partition("/")
        if not re.fullmatch(r"\w+", cls) or (fn and not re.fullmatch(r"\w+", fn)):
            continue  # a regex: shortcut, not checked
        # shortcut: names match as prefixes (the filter is a regex), like the xctest filter.
        if not any(n.startswith(cls) for own, _, _ in files for n in own):
            errs.append(f"filter class {cls} not found")
        elif fn and not any(f.startswith(fn) for _, ext, fs in files if any(n.startswith(cls) for n in ext) for f in fs):
            errs.append(f"filter test {alt} not found")
    return errs


def tail(text, n=40):
    """The last n lines, led by the compile errors and failed test cases above them (#1884: a 40-line
    tail showed only warnings for a build error and only passing rows for a red baseline)."""
    lines = text.splitlines()
    hits = [l for l in lines[:-n] if ": error:" in l or "' failed (" in l][:20]
    return "\n".join(hits + (["..."] if hits else []) + lines[-n:])


def run_list(path, root, logs, timeout, dry, stop_at):
    with open(path, encoding="utf-8") as fh:
        lst = json.load(fh)
    rows = []
    errs = problems(lst)
    name = os.path.basename(path)
    if errs:
        return [(name, "-", "-", "BROKEN", "; ".join(errs))]
    app = os.path.join(root, "app")
    stem = os.path.join(logs, os.path.splitext(name)[0])
    test = ["test", "--skip-build"] + FLAGS + ["--filter", lst["filter"]]
    if time.time() > stop_at:
        # #1884: no baseline either once the budget is spent; 35+ late baselines (~65 s each) ran shards into the step limit.
        return [(name, m["name"], m["expect"], "NOT RUN", "--budget spent; move lists to another shard") for m in lst["mutants"]]
    base = None
    if dry:
        base = "; ".join(filter_problems(lst["filter"], root)) or None
    else:
        log = stem + ".baseline.log"
        rc, out = swift(["build", "--build-tests"] + FLAGS, app, log, timeout)
        if rc == 0:
            rc, out = swift(test, app, log, timeout)
        if rc != 0 or not re.search(r"Executed [1-9][0-9]* tests?", out):
            base = "baseline red or ran no test, see " + os.path.basename(log)
            print("::group::" + name + " baseline log tail\n" + tail(out) + "\n::endgroup::")
    for m in lst["mutants"]:
        row = [name, m["name"], m["expect"]]
        if base:
            rows.append(tuple(row + ["BROKEN", base]))
            continue
        if time.time() > stop_at:
            rows.append(tuple(row + ["NOT RUN", "--budget spent; move lists to another shard"]))
            continue
        log = f"{stem}.{re.sub(r'[^A-Za-z0-9_.-]', '_', m['name'])}.log"
        try:
            with Mutant(root, m):
                if dry:
                    res, note = "APPLIED", "applied and restored, no swift run"
                else:
                    rc, _ = swift(["build", "--build-tests"] + FLAGS, app, log, timeout)
                    if rc != 0:
                        res, note = ("HANG", "build timed out") if rc is None else ("BROKEN", "build error")
                    else:
                        rc, _ = swift(test, app, log, timeout)
                        res = "HANG" if rc is None else "SURVIVED" if rc == 0 else "KILLED"
                        note = os.path.basename(log)
        except (OSError, ValueError, UnicodeDecodeError) as e:
            res, note = "BROKEN", str(e)
        rows.append(tuple(row + [res, note]))
        print(" | ".join(rows[-1]), flush=True)
        if failed(rows[-1]) and not dry and os.path.exists(log):
            with open(log, "rb") as fh:
                text = fh.read().decode("utf-8", "replace")
            print("::group::" + m["name"] + " log tail\n" + tail(text) + "\n::endgroup::", flush=True)
    return rows


def failed(row):
    res, expect = row[3], row[2]
    return res in ("BROKEN", "HANG", "NOT RUN") or (res == "SURVIVED" and expect == "killed")


def filter_classes(flt):
    """Plain class names of a --filter regex (same split as filter_problems; regex alternatives are skipped)."""
    out = set()
    for alt in re.split(r"\|(?![^()]*\))", flt):
        g = re.fullmatch(r"(\w+)/\(.*\)", alt)
        cls = g.group(1) if g else alt.partition("/")[0]
        if re.fullmatch(r"\w+", cls):
            out.add(cls)
    return out


# A filter class named by more than this many lists is a common row (the whole-tree guard rows most filters
# carry); a change to its test file keeps no list (#1884: on 2026-11-21 they kept 205 of 218 lists).
COMMON = 10


def anchor_near(path, olds, hunks, slack=3):
    """True when an `old` no longer occurs exactly once in `path` (a broken anchor, returned as None) or a hunk
    (new-side line range) lies within `slack` lines of one; else False. #1884: a far hunk keeps nothing."""
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return None
    near = False
    for old in olds:
        if text.count(old) != 1:
            return None
        first = text[:text.index(old)].count("\n") + 1
        last = first + old.rstrip("\n").count("\n")
        near = near or any(lo <= last + slack and hi >= first - slack for lo, hi in hunks)
    return near


def hunks_of(diff):
    """New-side (first, last) line ranges of `git diff -U0` output; a pure deletion is the line it follows."""
    out = []
    for m in re.finditer(r"^@@ -\S+ \+(\d+)(?:,(\d+))? @@", diff, re.M):
        start, n = int(m.group(1)), int(m.group(2) or 1)
        out.append((start, start + max(n, 1) - 1))
    return out


def changed_lists(files, root, since):
    """Lists to run with their priority (lower first): {file: rank}. All (rank 3) when `since` is unknown to
    git. Else: 0 a broken anchor in a changed mutated file; 1 the list JSON changed; (3, -newest commit time)
    a diff hunk within 3 lines of a mutant's `old`, or a changed test file of a list-specific (not COMMON)
    filter class."""
    def git(*a):
        return subprocess.run(["git", "-C", root] + list(a), capture_output=True, text=True)
    if git("rev-parse", "--verify", "-q", since + "^{commit}").returncode != 0:
        return {f: (3, 0) for f in files}
    d = git("diff", "--name-only", since + "..HEAD")
    if d.returncode != 0:
        return {f: (3, 0) for f in files}
    changed = set(d.stdout.split())
    tests = {}  # test file -> source text, only those under app/Tests
    for dp, _, fs in os.walk(os.path.join(root, "app", "Tests")):
        for f in fs:
            if f.endswith(".swift"):
                with open(os.path.join(dp, f), encoding="utf-8", errors="replace") as fh:
                    tests[os.path.relpath(os.path.join(dp, f), root)] = fh.read()
    lists = {}
    for f in files:
        with open(f, encoding="utf-8") as fh:
            lists[f] = json.load(fh)
    named = {}
    for lst in lists.values():
        for c in filter_classes(str(lst.get("filter", ""))):
            named[c] = named.get(c, 0) + 1
    hunks, newest = {}, {}

    def when(paths):
        key = tuple(sorted(paths))
        if key not in newest:
            out = git("log", "-1", "--format=%ct", since + "..HEAD", "--", *key).stdout.strip()
            newest[key] = int(out) if out.isdigit() else 0
        return newest[key]
    keep = {}
    for f, lst in lists.items():
        if os.path.relpath(f, root) in changed:
            keep[f] = (1, 0)
            continue
        ms = [m for m in lst.get("mutants", []) if isinstance(m, dict) and m.get("file") in changed]
        why = set()
        for src in {m["file"] for m in ms}:
            if src not in hunks:
                hunks[src] = hunks_of(git("diff", "-U0", since + "..HEAD", "--", src).stdout)
            near = anchor_near(os.path.join(root, src), [m["old"] for m in ms if m["file"] == src and isinstance(m.get("old"), str)], hunks[src])
            if near is None:
                keep[f] = (0, 0)
                break
            if near:
                why.add(src)
        if f in keep:
            continue
        own = [c for c in filter_classes(str(lst.get("filter", ""))) if named[c] <= COMMON]
        # shortcut: a class is matched by `class|extension|struct Name` prefix anywhere in a test file, like the filter.
        for c in own:
            rx = re.compile(r"\b(class|extension|struct)\s+" + c)
            why |= {t for t, src in tests.items() if t in changed and rx.search(src)}
        if why:
            keep[f] = (3, -when(why))
    return keep


# Seconds per list (build + unmutated run) and per mutant, from the 2026-11-20..22 nightly logs (#1884).
EST_LIST, EST_MUTANT = 100, 85


def plan(pattern, shards, root=REPO, since=None, budget=0, weekday=None):
    """Matrix of at most `shards` jobs. Without a `budget`: every list, greedy by estimated time. With one:
    lists in priority order (with `since`: changed_lists' rank 0 and 1, then the rotation slice of `weekday` (rank 2), then its other changed lists; 0 =
    Monday: entry number % 7 == weekday) each go to the least loaded job that stays within `budget`, else
    to a new job, else they are deferred: never planned, printed to stderr and $GITHUB_STEP_SUMMARY."""
    files = sorted(glob.glob(os.path.join(root, "scripts", "mutants", "lists", pattern)))
    files = [f for f in files if f.endswith(".json")]

    def cost(f):
        with open(f, encoding="utf-8") as fh:
            return EST_LIST + EST_MUTANT * len(json.load(fh).get("mutants", []))
    if since:
        rank = changed_lists(files, root, since)
        if weekday is not None:
            for f in files:
                if f not in rank and int(os.path.basename(f).split(".")[0]) % 7 == weekday:
                    rank[f] = (2, 0)  # ahead of changed lists: an overflowed changed list still leaves the slice day
        files = sorted(rank, key=lambda f: (rank[f], f))
    sizes = {f: cost(f) for f in files}
    jobs, deferred = [], []
    if budget > 0:
        for f in files:
            j = min(jobs, key=lambda j: j[0], default=None)
            if j is None or j[0] + sizes[f] > budget:
                if len(jobs) >= shards or sizes[f] > budget:
                    deferred.append(f)
                    continue
                j = [0, []]
                jobs.append(j)
            j[0] += sizes[f]
            j[1].append(os.path.relpath(f, root))
    else:
        jobs = [[0, []] for _ in range(min(shards, len(sizes)))]
        for f in sorted(sizes, key=lambda f: (-sizes[f], f)):
            j = min(jobs, key=lambda j: j[0])
            j[0] += sizes[f]
            j[1].append(os.path.relpath(f, root))
    if deferred:
        text = (f"Deferred {len(deferred)} lists (~{sum(sizes[f] for f in deferred)} s est, over {shards} x {budget} s); "
                "each runs again by its rotation day within a week:\n"
                + "\n".join(f"- {os.path.basename(f)} ~{sizes[f]} s" for f in deferred) + "\n")
        print(text, file=sys.stderr)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as fh:
                fh.write(text)
    return {"include": [{"shard": i, "lists": " ".join(j[1])} for i, j in enumerate(jobs)]}


def interrupted(*_):
    raise KeyboardInterrupt


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("lists", nargs="*")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--root", default=REPO, help="repo root to mutate (default: this checkout)")
    ap.add_argument("--logs", default=os.path.join(REPO, "app", "mutants-logs"))
    ap.add_argument("--timeout", type=int, default=1800, help="seconds per swift build or test run")
    ap.add_argument("--budget", type=int, default=0,
                    help="seconds after which no new list or mutant starts (0: none); --plan: seconds per job")
    ap.add_argument("--plan", action="store_true")
    ap.add_argument("--shards", type=int, default=5)
    ap.add_argument("--lists", dest="pattern", default="*.json")
    ap.add_argument("--since", help="--plan: keep only lists whose files changed in REV..HEAD (unknown REV: all)"
                                     " plus today's rotation slice")
    ap.add_argument("--weekday", type=int, help="--plan --since: rotation slice day, 0 = Monday (default: today, UTC)")
    a = ap.parse_args(argv)
    if a.plan:
        day = a.weekday if a.weekday is not None else datetime.datetime.now(datetime.timezone.utc).weekday()
        print(json.dumps(plan(a.pattern, max(1, a.shards), os.path.abspath(a.root), a.since or None, a.budget, day % 7)))
        return 0
    if not a.lists:
        ap.error("no list given")
    os.makedirs(a.logs, exist_ok=True)
    # GitHub cancels with SIGINT then SIGTERM: both unwind through Mutant.__exit__.
    signal.signal(signal.SIGTERM, interrupted)
    t0, rows = time.time(), []
    for p in a.lists:
        rows += run_list(p, os.path.abspath(a.root), a.logs, a.timeout, a.dry_run,
                         t0 + a.budget if a.budget > 0 else float("inf"))
    bad = [r for r in rows if failed(r)]
    md = ["| list | mutant | expect | result | note |", "|---|---|---|---|---|"]
    md += ["| " + " | ".join(c.replace("|", "\\|") for c in r) + " |" for r in rows]
    md.append(f"\n{len(rows)} rows, {len(bad)} failing, {int(time.time() - t0)} s")
    text = "\n".join(md) + "\n"
    print(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as fh:
            fh.write(text)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
