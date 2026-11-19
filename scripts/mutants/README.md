# Mutation checks

A mutant is a one-line change to app code that a test must catch. The lists here
run in `.github/workflows/mutants.yml`: Monday to Saturday 03:30 UTC only the lists
whose files changed in the last 25 h (2 shards, max 2 macOS jobs); Sunday 03:30 UTC
every list (5 shards, max 4 jobs); by hand with a `ref` and a `lists` glob, always in
full (max 4 jobs). A red run is fixed later, by a test or by updating the list.

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
  refuses text that names one (`GUARD` in run.py).

## What run.py does

Per list: builds, runs the filter unmutated (it must pass and run at least one
test, or every mutant would read as killed). Per mutant: applies it, `swift build
--build-tests`, `swift test --skip-build --filter <filter>` with
`PROSPER_HEAVY_TESTS=1`, then restores the file byte for byte (also on Ctrl-C or
SIGTERM). Results: KILLED, SURVIVED, BROKEN (anchor missing or repeated, build
error, red baseline), HANG (`--timeout`), NOT RUN (`--budget` spent). The exit code
is 1 when a `killed` mutant SURVIVED or any row is BROKEN, HANG or NOT RUN; the
table goes to stdout and `$GITHUB_STEP_SUMMARY`.

```sh
python3 -I scripts/mutants/run.py --dry-run scripts/mutants/lists/*.json  # anchors only, no swift
python3 -I scripts/mutants/run.py scripts/mutants/lists/1572.json         # the real run
```

## Changed lists only (`--plan --since`)

```sh
python3 -I scripts/mutants/run.py --plan --shards 2 --since <rev> [--root DIR] [--lists GLOB]
```

Keeps a list when `<rev>..HEAD` changed its JSON, a file named in its mutants, or a test
file under `app/Tests` that declares a class (or extension or struct) named in its
`filter` (regex-only filter parts are not matched). An unknown `<rev>` (shallow clone,
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
