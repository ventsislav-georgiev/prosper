#!/usr/bin/env python3
"""Rapid inline-autocomplete prompt prototyping against the SAME weights Prosper
uses (mlx-community/gemma-4-E2B-it-qat-4bit), so we can find a prompt that stops
the model echoing hint-lists and produces clean continuations — without rebuilding
the Swift app each time. Winner gets ported to CoreBridge.swift.

Run: python3 bench/prompt_lab.py
"""
import glob, sys
from mlx_lm import load, generate
from mlx_lm.sample_utils import make_sampler

SNAP = glob.glob(
    "/Users/ventsislav.georgiev/.config/prosper/hf/hub/"
    "models--mlx-community--gemma-4-E2B-it-qat-4bit/snapshots/*/")
MODEL = SNAP[0] if SNAP else "mlx-community/gemma-4-E2B-it-qat-4bit"
print(f"loading {MODEL} ...", file=sys.stderr)
model, tok = load(MODEL)

# ---- prompt variants -------------------------------------------------------

SYS_CURRENT = (  # abbreviated stand-in for Prosper's current huge system prompt
 "You are the inline autocomplete engine inside Prosper. Predict the small next "
 "piece of text the person is about to type and output ONLY the raw continuation "
 "after the cursor. NEVER repeat typed words. Aim for the next three to five words. "
 "A 'Suggested words' list may be provided; treat it as strong guidance.\n"
 'Examples:\n"The quick brown fox jumps over the lazy →" → "dog lying by the fence."')

SYS_MIN = (
 "Continue the user's text with the few words they would most likely type next. "
 "Output only that continuation (no quotes, no explanation), in the same language as the text.")

def user_current(before, cands):
    ctx = ""
    if cands:
        ctx += f"Suggested words (likely to come next, best first): {', '.join(cands)}.\n\n"
    return f"{ctx}Continue this text. Output only the continuation:\n{before}"

def user_min(before, cands):
    return before  # bare text, no hint list

VARIANTS = {
    "V0_current": (SYS_CURRENT, user_current),
    "V2_minimal": (SYS_MIN,     user_min),
}

# Manual Gemma turn formats that BYPASS the reasoning-channel chat template.
def enc(s): return tok.encode(s, add_special_tokens=False)
BOS = [tok.bos_token_id] if tok.bos_token_id is not None else []
def toks_raw(before, cands):        # pure base-LM continuation
    return BOS + enc(before)
def toks_turn(before, cands):       # gemma instruct turn, no channel/thinking
    s = (f"<start_of_turn>user\n{SYS_MIN}\n\n{before}<end_of_turn>\n<start_of_turn>model\n")
    return BOS + enc(s)
def toks_turn_cont(before, cands):  # turn that primes the continuation by echoing text in model turn
    s = (f"<start_of_turn>user\nContinue the text.<end_of_turn>\n<start_of_turn>model\n{before}")
    return BOS + enc(s)
RAW_VARIANTS = {
    "V3_raw":       toks_raw,
    "V4_turn":      toks_turn,
    "V5_turn_cont": toks_turn_cont,
}

# ---- test cases (prefix, candidate-hints the engine would have injected) ----
CASES = [
    ("en", "The quick brown fox jumps over the lazy ", ["dog", "can", "are", "have", "to", "will"]),
    ("en", "Thanks for your email. I'll get back to you ", ["as", "soon", "the", "you", "with"]),
    ("en", "Please find attached the ", ["file", "document", "same", "first", "following"]),
    ("en", "Let me know if you have any ", ["questions", "way", "one", "issues", "concerns"]),
    ("en", "We should schedule a meeting to disc", ["discuss", "discussion", "discover"]),
    ("bg", "Благодаря за имейла. Ще се свържа с вас ", ["скоро", "възможно", "днес"]),
    ("bg", "Ако имате въпроси, не се ", ["колебайте", "притеснявайте"]),
    ("lat", "Blagodarq za imeila. Shte se svarja s vas ", ["skoro", "vednaga"]),
]

sampler = make_sampler(temp=0.2, top_p=0.9)

for name, (system, userfn) in VARIANTS.items():
    print(f"\n{'='*70}\n{name}\n{'='*70}")
    for lang, before, cands in CASES:
        msgs = [{"role": "system", "content": system},
                {"role": "user", "content": userfn(before, cands)}]
        prompt = tok.apply_chat_template(msgs, add_generation_prompt=True)
        out = generate(model, tok, prompt=prompt, max_tokens=24, sampler=sampler, verbose=False)
        out = out.replace("\n", "\\n")[:80]
        print(f"  [{lang}] …{before[-30:]!r} → {out!r}")

for name, tokfn in RAW_VARIANTS.items():
    print(f"\n{'='*70}\n{name}\n{'='*70}")
    for lang, before, cands in CASES:
        prompt = tokfn(before, cands)
        out = generate(model, tok, prompt=prompt, max_tokens=24, sampler=sampler, verbose=False)
        out = out.replace("\n", "\\n")[:80]
        print(f"  [{lang}] …{before[-30:]!r} → {out!r}")
