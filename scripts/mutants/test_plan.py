"""Self-check of run.py --plan --since over a scratch git repo: /usr/bin/python3 -I scripts/mutants/test_plan.py"""
import glob
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run


class SincePlan(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ.get("MUT_SCRATCH"))
        self.r = self.tmp.name
        for rel, body in {
            "app/Sources/A.swift": "a", "app/Sources/B.swift": "b", "app/Sources/C.swift": "c",
            "app/Tests/FooTests.swift": "final class FooTests {}", "app/Tests/BarTests.swift": "class BarTests {}",
            "app/Tests/CTests.swift": "class CTests {}",
        }.items():
            self.w(rel, body)
        for n, f, flt in ((1, "A", "FooTests"), (2, "B", "BarTests/testX"), (3, "C", "CTests")):
            self.w(f"scripts/mutants/lists/{n}.json", json.dumps({"entry": n, "filter": flt, "mutants": [
                {"name": "m", "file": f"app/Sources/{f}.swift", "old": "x", "new": "y", "expect": "killed"}]}))
        self.git("init", "-q")
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "base")
        self.base = self.git("rev-parse", "HEAD").stdout.strip()

    def tearDown(self):
        self.tmp.cleanup()

    def w(self, rel, body):
        p = os.path.join(self.r, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write(body)

    def git(self, *a):
        return subprocess.run(["git", "-C", self.r] + list(a), capture_output=True, text=True, check=True)

    def commit(self, rel, body):
        self.w(rel, body)
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "c")

    def kept(self, since):
        m = run.plan("*.json", 2, self.r, since)
        return sorted(os.path.basename(p) for j in m["include"] for p in j["lists"].split())

    def test_mutant_file_keeps_its_list(self):
        self.commit("app/Sources/A.swift", "a2")
        self.assertEqual(self.kept(self.base), ["1.json"])

    def test_filter_class_test_file_keeps_its_list(self):
        self.commit("app/Tests/BarTests.swift", "class BarTests { }")
        self.assertEqual(self.kept(self.base), ["2.json"])

    def test_list_json_keeps_itself(self):
        p = os.path.join(self.r, "scripts/mutants/lists/3.json")
        self.commit("scripts/mutants/lists/3.json", open(p).read() + "\n")
        self.assertEqual(self.kept(self.base), ["3.json"])

    def test_untouched_dropped_and_none_means_zero(self):
        self.commit("README.md", "x")
        m = run.plan("*.json", 2, self.r, self.base)
        self.assertEqual(m, {"include": []})

    def test_unknown_rev_keeps_all(self):
        self.assertEqual(self.kept("0" * 40), ["1.json", "2.json", "3.json"])

    def test_no_since_keeps_all(self):
        self.assertEqual(self.kept(None), ["1.json", "2.json", "3.json"])

    def test_common_guard_class_change_keeps_no_list(self):
        for n in range(4, 4 + run.COMMON):  # GuardTests named by COMMON + 1 lists with 2.json's BarTests
            self.w(f"scripts/mutants/lists/{n}.json", json.dumps({"entry": n, "filter": "GuardTests", "mutants": [
                {"name": "m", "file": "app/Sources/A.swift", "old": "x", "new": "y", "expect": "killed"}]}))
        self.w("scripts/mutants/lists/2.json", json.dumps({"entry": 2, "filter": "BarTests/testX|GuardTests", "mutants": [
            {"name": "m", "file": "app/Sources/B.swift", "old": "x", "new": "y", "expect": "killed"}]}))
        self.w("app/Tests/GuardTests.swift", "final class GuardTests {}")
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "lists")
        base = self.git("rev-parse", "HEAD").stdout.strip()
        self.commit("app/Tests/GuardTests.swift", "final class GuardTests { }")
        self.assertEqual(self.kept(base), [])  # common row: no list
        self.commit("app/Tests/BarTests.swift", "class BarTests { }")
        self.assertEqual(self.kept(base), ["2.json"])  # its own class still keeps it

    def test_slice_by_weekday_and_changed_first(self):
        for n, size in ((8, 1), (15, 1), (22, 100)):  # 8 % 7 = 15 % 7 = 22 % 7 = 1
            self.w(f"scripts/mutants/lists/{n}.json", json.dumps({"entry": n, "filter": "FooTests", "mutants": [
                {"name": f"m{i}", "file": "app/Sources/C.swift", "old": "x", "new": "y", "expect": "killed"}
                for i in range(size)]}))
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "slice")
        base = self.git("rev-parse", "HEAD").stdout.strip()
        self.commit("app/Sources/A.swift", "a2")  # 1.json changed (185 s est); 1 % 7 = 1 too
        names = lambda m: sorted(os.path.basename(p) for j in m["include"] for p in j["lists"].split())
        self.assertEqual(names(run.plan("*.json", 2, self.r, base, 0, 0)), ["1.json"])  # Monday: no list % 7 == 0
        self.assertEqual(names(run.plan("*.json", 2, self.r, base, 0, 1)), ["1.json", "15.json", "22.json", "8.json"])
        # 2 jobs x 300 s: 1.json (changed, 185) first, 15.json (185) opens job 2, 22.json (8600) and 8.json are deferred.
        self.assertEqual(names(run.plan("*.json", 2, self.r, base, 300, 1)), ["1.json", "15.json"])
        self.assertEqual(names(run.plan("*.json", 1, self.r, base, 300, 1)), ["1.json"])  # changed first, slice deferred


    def commit_at(self, rel, body, when):
        self.w(rel, body)
        self.git("add", "-A")
        env = dict(os.environ, GIT_COMMITTER_DATE=f"{when} +0000", GIT_AUTHOR_DATE=f"{when} +0000")
        subprocess.run(["git", "-C", self.r, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "c"],
                       env=env, check=True, capture_output=True)

    def add_list(self, n, src, old):
        self.w(f"scripts/mutants/lists/{n}.json", json.dumps({"entry": n, "filter": "NoTests", "mutants": [
            {"name": "m", "file": src, "old": old, "new": "y", "expect": "killed"}]}))

    def test_hunk_must_reach_an_anchor(self):
        lines = [f"l{i}" for i in range(1, 31)]
        self.w("app/Sources/H.swift", "\n".join(lines) + "\n")
        self.add_list(40, "app/Sources/H.swift", "l15\n")
        self.commit_at("README.md", "x", 1700000000)
        base = self.git("rev-parse", "HEAD").stdout.strip()
        self.commit_at("app/Sources/H.swift", "\n".join(["m1"] + lines[1:]) + "\n", 1700000100)
        self.assertEqual(self.kept(base), [])  # line 1, far from line 15: nothing
        self.commit_at("app/Sources/H.swift", "\n".join(["m1"] + lines[1:13] + ["m14"] + lines[14:]) + "\n", 1700000200)
        self.assertEqual(self.kept(base), ["40.json"])  # line 14, next to the anchor
        b2 = self.git("rev-parse", "HEAD").stdout.strip()
        self.commit_at("app/Sources/H.swift", "\n".join(["m1"] + lines[1:13] + ["m14", "gone"] + lines[15:]) + "\n", 1700000300)
        self.assertEqual(run.changed_lists(sorted(glob.glob(os.path.join(self.r, "scripts/mutants/lists/*.json"))),
                                           self.r, b2), {os.path.join(self.r, "scripts/mutants/lists/40.json"): (0, 0)})

    def test_capacity_cap_keeps_the_priority_order(self):
        for n, src in ((50, "Q"), (52, "R"), (53, "S")):
            self.w(f"app/Sources/{src}.swift", "a\nq\nb\n")
            self.add_list(n, f"app/Sources/{src}.swift", "q\n")
        self.add_list(51, "app/Sources/A.swift", "a")
        self.add_list(57, "app/Sources/A.swift", "a")  # 57 % 7 = 1: Tuesday's slice
        self.commit_at("README.md", "x", 1700000000)
        base = self.git("rev-parse", "HEAD").stdout.strip()
        self.commit_at("app/Sources/R.swift", "a\nq\nb2\n", 1700000100)  # near the anchor, older
        self.commit_at("app/Sources/S.swift", "a\nq\nb2\n", 1700000200)  # near the anchor, newer
        self.commit_at("app/Sources/Q.swift", "a\nz\nb\n", 1700000300)  # anchor gone
        self.add_list(51, "app/Sources/A.swift", "a ")  # the list JSON changed
        self.commit_at("app/Sources/A.swift", "a", 1700000400)
        order = lambda m: [os.path.basename(p) for j in m["include"] for p in j["lists"].split()]
        # #1886: broken anchor, changed JSON, Tuesday's slice in file order (1.json, 57.json), then hunks newest first
        self.assertEqual(order(run.plan("*.json", 1, self.r, base, 185 * 6, 1)),
                         ["50.json", "51.json", "1.json", "57.json", "53.json", "52.json"])
        self.assertEqual(order(run.plan("*.json", 1, self.r, base, 185 * 3, 1)), ["50.json", "51.json", "1.json"])

    def test_changed_lists_that_fill_capacity_leave_the_whole_slice_planned(self):
        for n, src in ((52, "R"), (53, "S"), (54, "T")):
            self.w(f"app/Sources/{src}.swift", "a\nq\nb\n")
            self.add_list(n, f"app/Sources/{src}.swift", "q\n")
        self.add_list(57, "app/Sources/Z.swift", "z")  # 57 % 7 = 64 % 7 = 1 % 7 = 1: Tuesday's slice (with 1.json)
        self.add_list(64, "app/Sources/Z.swift", "z")
        self.commit_at("README.md", "x", 1700000000)
        base = self.git("rev-parse", "HEAD").stdout.strip()
        for i, src in enumerate("RST"):  # three changed lists (rank 3), 185 s each, alone over the capacity
            self.commit_at(f"app/Sources/{src}.swift", "a\nq\nb2\n", 1700000100 + i)
        order = lambda m: [os.path.basename(p) for j in m["include"] for p in j["lists"].split()]
        self.assertEqual(order(run.plan("*.json", 1, self.r, base, 185 * 3, 1)), ["1.json", "57.json", "64.json"])  # all 3 changed lists deferred


class FilterRegex(unittest.TestCase):
    def problems(self, flt):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "app", "Tests"))
            with open(os.path.join(d, "app", "Tests", "A.swift"), "w") as fh:
                fh.write("final class FooTests {}\n")
            return run.filter_problems(flt, d)

    def test_unbalanced_filter_is_a_problem(self):
        p = self.problems("FooTests|(FooTests|FooTests)|FooTests)")
        self.assertEqual(len([e for e in p if e.startswith("filter is not a valid regex: ")]), 1)

    def test_file_name_removed_row_and_live_extension_row(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "app", "Tests"))
            with open(os.path.join(d, "app", "Tests", "AgentFocusTests.swift"), "w") as fh:
                fh.write("extension FooTests {\n    func testLive() {}\n}\n")
            with open(os.path.join(d, "app", "Tests", "A.swift"), "w") as fh:
                fh.write("final class FooTests {\n    func testOther() {}\n}\n")
            self.assertEqual(run.filter_problems("FooTests/testLive", d), [])  # live extension row
            self.assertEqual(run.filter_problems("AgentFocusTests", d), ["filter class AgentFocusTests not found"])  # file name
            self.assertEqual(run.filter_problems("FooTests/testGone", d), ["filter test FooTests/testGone not found"])  # removed row

    def test_valid_filter_has_no_problem(self):
        self.assertEqual(self.problems("FooTests|(FooTests)"), [])


class Budget(unittest.TestCase):
    """#1884: a spent --budget starts no baseline; plan sizes the matrix by estimated time."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ.get("MUT_SCRATCH"))
        self.calls = []
        self.real = run.swift
        run.swift = lambda args, *_: self.calls.append(args) or (0, "Executed 1 test")

    def tearDown(self):
        run.swift = self.real
        self.tmp.cleanup()

    def write_list(self, name, n):
        p = os.path.join(self.tmp.name, "scripts", "mutants", "lists", name)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as fh:
            json.dump({"entry": 1, "filter": "FooTests", "mutants": [
                {"name": f"m{i}", "file": "app/A.swift", "old": "x", "new": "y", "expect": "killed"} for i in range(n)]}, fh)
        return p

    def test_spent_budget_runs_no_baseline(self):
        rows = run.run_list(self.write_list("1.json", 3), self.tmp.name, self.tmp.name, 900, False, time.time() - 1)
        self.assertEqual(self.calls, [])
        self.assertEqual([r[3] for r in rows], ["NOT RUN"] * 3)

    def test_plan_shard_count_follows_the_estimate(self):
        for i in range(4):
            self.write_list(f"{i}.json", 10)  # 4 x (100 + 10 x 85) = 3800 s
        self.assertEqual(len(run.plan("*.json", 8, self.tmp.name, None, 2000)["include"]), 2)
        self.assertEqual(len(run.plan("*.json", 8, self.tmp.name, None, 0)["include"]), 4)
        self.assertEqual(run.plan("*.json", 1, self.tmp.name, None, 100), {"include": []})  # all deferred, none planned

    def test_tail_keeps_the_error_above_the_last_lines(self):
        out = run.tail("a.swift:1:2: error: no\n" + "\n".join(["warning"] * 50), 40)
        self.assertTrue(out.startswith("a.swift:1:2: error: no\n...\n"))
        self.assertEqual(out.count("warning"), 40)


if __name__ == "__main__":
    unittest.main()
