#!/usr/bin/env python3
"""Converts a supervisor work folder's mutants into lists/<id>.json (#1578). Stdlib only.

  import_wave.py WORKDIR ID [--filter F] [--out PATH]

Reads WORKDIR/mutate.py with ast only (never imported or run): a module-level dict
M = {name: (file under app/, old, new)} or {name: (old, new)} with the file in a
module-level `f = root + "/Sources/..."`. The filter is --filter, else the first
line of WORKDIR/mutants.txt that is a single-quoted string (optionally F='...').
A name on a DESCRIBED ONLY line of mutants.txt is left out, and so is any mutant
run.py refuses (a clipboard, event, defaults, delete or sandbox guard).
Every imported mutant expects "killed".
"""
import argparse
import ast
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True  # no __pycache__ beside the scripts
_spec = importlib.util.spec_from_file_location("mutants_run", os.path.join(HERE, "run.py"))
run = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(run)


def strings(tree):
    """Module-level string assignments; a name bound at runtime (root = sys.argv[1]) reads as ""."""
    env = {}

    def ev(n):
        if isinstance(n, ast.Constant) and isinstance(n.value, str):
            return n.value
        if isinstance(n, ast.Name):
            return env.get(n.id, "")
        if isinstance(n, ast.BinOp) and isinstance(n.op, ast.Add):
            return ev(n.left) + ev(n.right)
        if isinstance(n, ast.Tuple):
            return tuple(ev(e) for e in n.elts)
        raise ValueError(f"line {n.lineno}: not a plain string expression")

    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            name = node.targets[0].id
            if name == "M" and isinstance(node.value, ast.Dict):
                env["M"] = {ev(k): ev(v) for k, v in zip(node.value.keys, node.value.values)}
            else:
                try:
                    env[name] = ev(node.value)
                except ValueError:
                    pass
    return env


def convert(workdir, entry, flt=None):
    with open(os.path.join(workdir, "mutate.py"), encoding="utf-8") as fh:
        env = strings(ast.parse(fh.read()))
    with open(os.path.join(workdir, "mutants.txt"), encoding="utf-8") as fh:
        txt = fh.read()
    if "M" not in env:
        raise SystemExit("mutate.py has no module-level dict M")
    if flt is None:
        hit = re.search(r"^\s*(?:F=)?'([^'\n]+)'\s*$", txt, re.M)
        if not hit:
            raise SystemExit("no filter line in mutants.txt; pass --filter")
        flt = hit.group(1)
    described = " ".join(l for l in txt.splitlines() if re.search("described only", l, re.I))
    mutants, skipped = [], []
    for name, v in env["M"].items():
        if re.search(r"(?<![\w-])" + re.escape(name) + r"(?![\w-])", described):
            skipped.append((name, "described only"))
            continue
        if len(v) == 2:
            v = (env.get("f", ""),) + v
        if len(v) != 3 or not v[0]:
            raise SystemExit(f"{name}: no file (want (file, old, new) or a module-level f)")
        path = v[0].lstrip("/")
        path = path if path.startswith("app/") else "app/" + path
        m = {"name": name, "file": path, "old": v[1], "new": v[2], "expect": "killed"}
        errs = run.problems({"entry": entry, "filter": flt, "mutants": [m]})
        if errs:
            skipped.append((name, "; ".join(errs)))
            continue
        mutants.append(m)
    return {"entry": entry, "filter": flt, "mutants": mutants}, skipped


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("workdir")
    ap.add_argument("id")
    ap.add_argument("--filter")
    ap.add_argument("--out")
    a = ap.parse_args(argv)
    entry = int(a.id) if a.id.isdigit() else a.id
    lst, skipped = convert(a.workdir, entry, a.filter)
    for name, why in skipped:
        print(f"skipped {name}: {why}", file=sys.stderr)
    if not lst["mutants"]:
        raise SystemExit("no mutant left to write")
    out = a.out or os.path.join(HERE, "lists", f"{a.id}.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(lst, fh, indent=1, ensure_ascii=False)
        fh.write("\n")
    print(f"{out}: {len(lst['mutants'])} mutants, {len(skipped)} skipped")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
