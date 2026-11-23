# Mutation checks

A mutant is a one-line change to app code that a test must catch. The lists here
run in `.github/workflows/mutants.yml`: every night at 03:30 UTC the lists whose files
changed in the last 25 h plus that day's rotation slice, in one wave of at most 3 shards
(max 3 macOS jobs); by hand with a `ref` and a `lists` glob, every list it matches as far as one wave of at most 4
shards (max 4 jobs) holds; the rest is deferred and listed. `--plan --budget S` makes only as many shards as the lists need at S
seconds each, estimated from `EST_LIST` and `EST_MUTANT` in run.py (`EST_MUTANT_OF` holds the per-list times observed slower than that).

Rotation slice: a list belongs to the UTC weekday `entry % 7` of its file name
(`1788.json`: 1788 % 7 = 3), with 0 = Monday, 1 = Tuesday, 2 = Wednesday, 3 = Thursday,
4 = Friday, 5 = Saturday, 6 = Sunday, so every list runs at least once a week. A broken
anchor or a changed list JSON comes first. The plan never schedules more than shards x budget by estimate; in order
of priority it takes lists with a broken anchor (an `old` no longer exactly once), then
lists whose JSON changed, then the slice (so every slice fits on its own and its tail is never
deferred by a busy night), then other changed lists by their newest commit.
The overflow is deferred: never planned and never a NOT RUN row, listed with its estimate
in the plan log and the plan job's step summary. A deferred list runs again on its own
rotation day within a week (only a broken anchor or changed JSON can crowd it out). A red run is fixed later, by a test or by updating the list.

## List format

One file per ledger entry, `lists/<entry>.json`:

```json
{
 "entry": 1572,
 "filter": "CCPoolThrottleRetryTests/testPooledDrop|CCPoolUsageRecordTests",
 "mutants": [
  {
   "name": "bad-path-row-dropped",
   "file": "app/Sources/ProsperApp/CCPool/CCPoolConnection.swift",
   "old": "            recordAnswer(400, acct: accountID)\n",
   "new": "",
   "expect": "killed"
  }
 ]
}
```

- `filter`: the `swift test --filter` regex for every mutant of the list.
- `file`: repo-relative. `old` must occur exactly once in it; `new` replaces it.
- `expect`: `killed` (a test must fail) or `survives` (a known survivor, kept on
  record; it does not fail the run). An optional `note` says why (the reason a survivor is accepted).
- Never a mutant of a clipboard, event, defaults, delete or sandbox guard: `run.py`
  refuses text that names one (`GUARD` in run.py). A mutant it refuses is kept on record under a list-level
  `refused` array (never run), with a `note` naming the row that pins the same check.
  A mutant may be rewritten past `GUARD` only when the rewrite reduces side effects (a read, less deletion, an
  in-model id); the harmful direction goes to `refused` with its covering row. Each rewrite carries a `note` saying which.
- A mutant whose code was removed (or became equivalent) moves to a list-level `retired` array, `{name, note}`, the
  note naming the entry that removed it (never run). A list left with no mutants is deleted, its retired names in the
  commit message (`run.py` refuses an empty `mutants` array).

## What run.py does

Per list: builds, runs the filter unmutated (it must pass and run at least one
test, or every mutant would read as killed). Per mutant: applies it, `swift build
--build-tests`, `swift test --skip-build --filter <filter>` with
`PROSPER_HEAVY_TESTS=1`, then restores the file byte for byte (also on Ctrl-C or
SIGTERM). Results: KILLED, SURVIVED, BROKEN (anchor missing or repeated, build
error, red baseline), HANG (`--timeout`), NOT RUN (`--budget` spent: no list baseline or
mutant starts after it). The exit code
is 1 when a `killed` mutant SURVIVED or any row is BROKEN, HANG or NOT RUN; the
table goes to stdout and `$GITHUB_STEP_SUMMARY`.

```sh
python3 -I scripts/mutants/run.py --dry-run scripts/mutants/lists/*.json  # anchors only, no swift
python3 -I scripts/mutants/run.py scripts/mutants/lists/1572.json         # the real run
```

## Changed lists only (`--plan --since`)

```sh
python3 -I scripts/mutants/run.py --plan --shards 3 --budget 15000 --since <rev> [--weekday D] [--root DIR] [--lists GLOB]
```

Keeps a list when `<rev>..HEAD` changed its JSON, a file named in its mutants where a
`git diff -U0` hunk lies within 3 lines of one of its `old` texts (or an `old` no longer
occurs exactly once: a broken anchor, always kept), or a test
file under `app/Tests` that declares a class (or extension or struct) named in its
`filter` (regex-only filter parts are not matched). A class named by more than `COMMON`
(10) lists, such as the whole-tree guard rows most filters carry, is common: a change to
its test file keeps no list. With `--weekday D` (default today, UTC) the day's rotation
slice is added. An unknown `<rev>` (shallow clone,
force-push, no commit that old) keeps every list; zero kept lists give an empty matrix,
and the mutants job is skipped. Self-check: `python3 -I scripts/mutants/test_plan.py`.

## Adding a list

Write `lists/<entry>.json` by hand, or convert a work folder's `mutate.py` (a dict
`M = {name: (file under app/, old, new)}`, read with `ast`, never run) and the
quoted filter line of its `mutants.txt`:

```sh
python3 -I scripts/mutants/import_wave.py <workdir> <entry>   # writes lists/<entry>.json
```

Names on a DESCRIBED ONLY line of `mutants.txt` are left out. Then check the
anchors with `--dry-run` before committing.
