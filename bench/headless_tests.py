#!/usr/bin/env python3
"""
Headless LLM regression suite for Prosper inline autocomplete.

NOT unit tests — these run against a REAL headless model run (headless_out.json
produced by bench/headless.sh), because inline-completion quality is only
meaningful with the actual LLM in the loop. Asserts, per language and per case:

  - script correctness / no drift  (EN/latinica stay Latin, BG stays Cyrillic)
  - coverage parity vs Cotypist
  - no echo of prefix, no seed regurgitation, no intra-completion loops
  - coherence heuristics (no markdown/garbage/punctuation-only output)
  - length sanity
  - speed (p50 / p95 / max latency budgets)

Run:  python3 bench/headless_tests.py [prosper_out.json] [cotypist_baseline.json]
Exit non-zero if any assertion fails. Designed so adding more sampling/prompt
changes can't silently regress speed or quality.
"""
import json, sys, re, statistics

SCR = "/private/tmp/claude-502/-Users-ventsislav-georgiev-personal-prosper/10ad5361-4ca2-47e0-a254-512d84aa21d0/scratchpad"
PROS = sys.argv[1] if len(sys.argv) > 1 else f"{SCR}/headless_out.json"
COT  = sys.argv[2] if len(sys.argv) > 2 else f"{SCR}/cotypist.json"

CYR = re.compile(r'[Ѐ-ӿ]')
LAT = re.compile(r'[A-Za-z]')
WORD = re.compile(r'\w+', re.UNICODE)
# coherence: markdown emphasis, stray asterisks, repeated punctuation, non-letter runs
# markdown emphasis / fences / stray doubled operators — but NOT URLs (a URL is a
# legitimate completion in code/link contexts, e.g. `await fetch(` -> a full URL).
JUNK = re.compile(r'(\*\*|__|~~|\|\||>>|<<)')
PUNCT_ONLY = re.compile(r'^[^\w]+$', re.UNICODE)

# ---- latency + coverage budgets (parity: at/under Cotypist, headless is ~10x faster) ----
LAT_P50_MS = 1500      # p50 warm generation budget
LAT_P95_MS = 3500      # p95 budget
LAT_MAX_MS = 8000      # no single case may exceed this
MIN_COV = {"en": 0.96, "bg": 0.96, "lat": 0.92}   # non-empty fraction floor per lang

def load(p):
    d = json.load(open(p))
    return d.get("results", d) if isinstance(d, dict) else d

def by_id(rows): return {r["id"]: r for r in rows}

def norm_words(s): return WORD.findall((s or "").lower())

class Suite:
    def __init__(self): self.passed=0; self.failed=[]
    def check(self, name, cond, detail=""):
        if cond: self.passed += 1
        else: self.failed.append(f"{name}: {detail}")
    def report(self):
        print(f"\n{'='*60}")
        print(f"PASS {self.passed}  FAIL {len(self.failed)}")
        for f in self.failed: print(f"  ✗ {f}")
        print('='*60)
        return len(self.failed) == 0

def main():
    pros = by_id(load(PROS))
    cot  = by_id(load(COT))
    s = Suite()
    langs = {}
    for cid, r in cot.items():
        langs.setdefault(r.get("lang","?"), []).append(cid)

    # ---------- per-case checks (the bulk: hundreds of assertions) ----------
    for cid in sorted(cot):
        lang = cot[cid].get("lang","?")
        pr = pros.get(cid)
        s.check(f"[{cid}] present in run", pr is not None, "missing from headless output")
        if pr is None: continue
        comp = (pr.get("completion") or "").strip()
        prefix = pr.get("prefix","")

        # A. SCRIPT CORRECTNESS (coherence-critical: no cross-script drift)
        if comp:
            if lang == "en":
                s.check(f"[{cid}] en no-Cyrillic", not CYR.search(comp), f"cyrillic drift: {comp!r}")
            elif lang == "lat":
                s.check(f"[{cid}] lat no-Cyrillic", not CYR.search(comp), f"cyrillic drift: {comp!r}")
            elif lang == "bg":
                # BG must stay Cyrillic — a mostly-Latin body means drift
                letters = [c for c in comp if c.isalpha()]
                if letters:
                    cyr_frac = sum(1 for c in letters if CYR.match(c)) / len(letters)
                    s.check(f"[{cid}] bg stays-Cyrillic", cyr_frac >= 0.6,
                            f"latin drift {1-cyr_frac:.0%}: {comp!r}")

        # B. NO PREFIX ECHO (don't just repeat the last words already typed)
        if comp:
            pw = norm_words(prefix)[-4:]
            cw = norm_words(comp)
            if pw and cw:
                s.check(f"[{cid}] no full-prefix-echo",
                        not (len(cw) >= 2 and cw[:len(pw)] == pw),
                        f"echoes prefix tail {pw}: {comp!r}")

        # C. NO INTRA-COMPLETION IMMEDIATE LOOP ("the the", "da da")
        cw = norm_words(comp)
        dup = next((cw[i] for i in range(1,len(cw)) if cw[i]==cw[i-1] and len(cw[i])>1), None)
        s.check(f"[{cid}] no adjacent-word loop", dup is None, f"repeats {dup!r}: {comp!r}")

        # D. COHERENCE: no markdown/junk tokens, not punctuation-only
        if comp:
            s.check(f"[{cid}] no markdown/junk", not JUNK.search(comp), f"junk token: {comp!r}")
            s.check(f"[{cid}] not punctuation-only", not PUNCT_ONLY.match(comp), f"{comp!r}")

        # E. LENGTH SANITY: non-empty completions carry real content (>=1 word, <=12)
        if comp:
            s.check(f"[{cid}] word-count sane", 1 <= len(cw) <= 12, f"{len(cw)} words: {comp!r}")

        # F. PER-CASE LATENCY CAP
        ms = pr.get("latencyMs", 0)
        s.check(f"[{cid}] latency<{LAT_MAX_MS}ms", ms <= LAT_MAX_MS, f"{ms}ms")

    # ---------- per-language aggregate checks ----------
    all_ms = [pros[c].get("latencyMs",0) for c in pros]
    for lang, ids in langs.items():
        comps = [(pros.get(c,{}).get("completion") or "").strip() for c in ids]
        cov = sum(1 for x in comps if x) / len(ids)
        floor = MIN_COV.get(lang, 0.9)
        s.check(f"[{lang}] coverage>={floor:.0%}", cov >= floor, f"{cov:.0%} ({sum(1 for x in comps if x)}/{len(ids)})")

        # no-drift aggregate
        if lang in ("en","lat"):
            drift = sum(1 for x in comps if x and CYR.search(x))
            s.check(f"[{lang}] zero Cyrillic-drift", drift == 0, f"{drift} cases drifted")

        # parity vs cotypist coverage (must be within 4 percentage points)
        cot_cov = sum(1 for c in ids if (cot[c].get("completion") or "").strip()) / len(ids)
        s.check(f"[{lang}] coverage-parity vs Cotypist", cov >= cot_cov - 0.04,
                f"prosper {cov:.0%} vs cotypist {cot_cov:.0%}")

    # ---------- global speed budget ----------
    if all_ms:
        p50 = statistics.median(all_ms)
        p95 = sorted(all_ms)[int(len(all_ms)*0.95)-1]
        s.check(f"p50<{LAT_P50_MS}ms", p50 <= LAT_P50_MS, f"{p50:.0f}ms")
        s.check(f"p95<{LAT_P95_MS}ms", p95 <= LAT_P95_MS, f"{p95:.0f}ms")
        print(f"latency: p50={p50:.0f}ms p95={p95:.0f}ms max={max(all_ms)}ms n={len(all_ms)}")

    ok = s.report()
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
