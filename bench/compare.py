#!/usr/bin/env python3
"""Score + compare inline-autocomplete benchmark runs.

Usage: python3 bench/compare.py bench/results-cotypist.json bench/results-prosper.json
Prints coverage/quality/latency per language and a side-by-side per-case table.
"""
import json, sys, re, unicodedata

def norm(s):
    s = unicodedata.normalize("NFKC", s or "").lower().strip()
    return re.sub(r"[^\w]+", " ", s, flags=re.UNICODE).strip()

def toks(s):
    return [t for t in norm(s).split() if t]

def quality(comp, expect):
    """Loose 0..1: how well the completion matches the reference continuation.
    Reference is only a plausible continuation, so we reward token overlap and
    prefix agreement, not exact equality."""
    c, e = toks(comp), toks(expect)
    if not c: return 0.0
    if not e: return 1.0 if c else 0.0
    # word-completion cases (expect is a suffix like "ersation"): check the raw join.
    if norm(comp).replace(" ", "").startswith(norm(expect).replace(" ", "")[:4]) and len(e) == 1:
        return 1.0
    cset, eset = set(c), set(e)
    inter = len(cset & eset)
    return inter / max(1, len(eset))

def script_of(s):
    """Dominant script bucket of the letters in s: latin|cyrillic|other|none."""
    lat = cyr = 0
    for ch in s:
        o = ord(ch)
        if (0x41 <= o <= 0x24F): lat += 1
        elif (0x400 <= o <= 0x52F): cyr += 1
    if lat == 0 and cyr == 0: return "none"
    return "cyrillic" if cyr > lat else "latin"

def categorize(comp, prefix, lang):
    """Honest bucket: empty | echo | drift | ok. Less misleading than token-overlap."""
    c = comp.strip()
    if not c: return "empty"
    # echo: repeats the tail word(s) of the prefix
    ptoks, ctoks = toks(prefix), toks(comp)
    if ctoks and ptoks and ctoks[0] == ptoks[-1]: return "echo"
    # language drift: expected script vs produced script
    want = "cyrillic" if lang == "bg" else "latin"  # lat(latinica)+en both latin-script
    sc = script_of(c)
    if sc != "none" and sc != want: return "drift"
    return "ok"

def load(p):
    with open(p) as f: return json.load(f)

def summarize(run, label):
    rs = run["results"]
    by = {}
    for r in rs:
        by.setdefault(r["lang"], []).append(r)
    print(f"\n=== {label}  (tool={run['tool']}, accept={run['accept']}) ===")
    for lang in ("en", "bg", "lat"):
        g = by.get(lang, [])
        if not g: continue
        cov = sum(1 for r in g if r["completion"].strip())
        q = sum(quality(r["completion"], r["expect"]) for r in g) / len(g)
        lat = sorted(r["latencyMs"] for r in g)
        med = lat[len(lat)//2] if lat else 0
        cats = {}
        for r in g:
            k = categorize(r["completion"], r["prefix"], r["lang"]); cats[k] = cats.get(k, 0) + 1
        catstr = " ".join(f"{k}={cats[k]}" for k in ("ok","echo","drift","empty") if cats.get(k))
        print(f"  {lang}: coverage {cov}/{len(g)} ({100*cov//len(g)}%)  [{catstr}]  avg-quality {q:.2f}  median-latency {med}ms")
    cov = sum(1 for r in rs if r["completion"].strip())
    q = sum(quality(r["completion"], r["expect"]) for r in rs) / len(rs)
    print(f"  ALL: coverage {cov}/{len(rs)} ({100*cov//len(rs)}%)  avg-quality {q:.2f}")
    return {r["id"]: r for r in rs}

def main():
    runs = [(load(p), p) for p in sys.argv[1:]]
    maps = [summarize(r, p.split("/")[-1]) for r, p in runs]
    if len(maps) == 2:
        a, b = maps
        print(f"\n=== side-by-side (A={runs[0][1].split('/')[-1]}  B={runs[1][1].split('/')[-1]}) ===")
        ids = list(a.keys())
        for i in ids:
            ra, rb = a.get(i), b.get(i)
            if not ra or not rb: continue
            pa = (ra["prefix"][-32:]).replace("\n", "\\n")
            ca = ra["completion"].replace("\n", "\\n")
            cb = rb["completion"].replace("\n", "\\n")
            qa, qb = quality(ra["completion"], ra["expect"]), quality(rb["completion"], rb["expect"])
            flag = "  <<" if qb + 0.01 < qa else ("  >>" if qa + 0.01 < qb else "")
            print(f"  {i:6} …{pa!r:36} | A:{ca!r:32} ({qa:.1f}) | B:{cb!r:32} ({qb:.1f}){flag}")

if __name__ == "__main__":
    main()
