"""Self-check of run.py --plan --since over a scratch git repo: /usr/bin/python3 -I scripts/mutants/test_plan.py"""
import json
import os
import subprocess
import sys
import tempfile
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


if __name__ == "__main__":
    unittest.main()
