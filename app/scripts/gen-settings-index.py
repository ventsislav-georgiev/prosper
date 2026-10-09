#!/usr/bin/env python3
"""Generate Sources/ProsperApp/SettingsIndex.generated.swift from the settings source.

The settings search index has one entry per pane (section: "") plus one per titled
`NeonSection` inside that pane. Literal `NeonRow("...")` titles ride along as that
entry's keywords, so a row is findable and lands on its section. Nobody hand-maintains it: this script scrapes it out
of the panes themselves, and `SettingsSearchTests.testGeneratedIndexIsCurrent` runs
`--check` so a stale table fails the build rather than silently under-indexing.

What it reads:
  * `SettingsWindow.swift` `content` switch  -> pane id -> pane view struct
  * `SettingsWindow.swift` `SettingsTab(id:title:)` literals -> pane id -> pane title
  * every `struct X: View` in Sources/ProsperApp -> its literal `NeonSection("...")`
    titles, in source order, plus references to other view structs (a pane that
    factors a section out into a helper view still gets that section indexed).

What it skips, by design:
  * untitled `NeonSection`s (nothing to search for, nothing to label a result with)
  * non-literal titles, e.g. `NeonSection(sec.title, ...)` in the extension pane —
    those are manifest-driven and come from `extensionSettingsIndex(registry:)` at
    runtime instead.
Both counts are printed so they stay visible.

Usage:
  gen-settings-index.py            # rewrite the generated file
  gen-settings-index.py --check    # exit 1 (with a diff) when it is stale
"""

import difflib
import os
import re
import sys

APP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(APP, "Sources", "ProsperApp")
WINDOW = os.path.join(SOURCES, "SettingsWindow.swift")
OUT = os.path.join(SOURCES, "SettingsIndex.generated.swift")

DECL_RE = re.compile(
    r"^(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:public |private |internal |fileprivate |final |@MainActor )*"
    r"(?:struct|class|enum|extension|protocol|actor|func|let|var)\b"
)
STRUCT_RE = re.compile(r"\bstruct (\w+)\s*(?:<[^>]*>)?\s*:\s*[^{]*\bView\b")
CASE_RE = re.compile(r'\bcase "([\w:-]+)":')
TAB_RE = re.compile(r'SettingsTab\(\s*id: "([^"]+)",\s*title: "([^"]+)"')
SECTION_RE = re.compile(r"\bNeon(Section|Row)\(")
LITERAL_RE = re.compile(r'^"((?:[^"\\]|\\.)*)"')


def swift_files():
    for base, _, names in os.walk(SOURCES):
        for name in sorted(names):
            if name.endswith(".swift") and name != os.path.basename(OUT):
                yield os.path.join(base, name)


def scan_structs():
    """struct name -> {'file', 'scroll', 'events'}.

    A view struct runs from its declaration to the next top-level declaration —
    brace counting would be fooled by braces inside string literals. `events` is the
    ordered mix of ('sec', title) and ('ref', struct name) found inside it.
    """
    structs = {}
    skipped = {"untitled": 0, "non_literal": 0}
    for path in swift_files():
        text = open(path, encoding="utf-8").read()
        if "NeonSection(" not in text:
            continue
        current = None
        for line in text.split("\n"):
            if DECL_RE.match(line):
                match = STRUCT_RE.search(line)
                current = match.group(1) if match else None
                if current:
                    structs.setdefault(
                        current, {"file": path, "scroll": False, "events": []})
            if current is None:
                continue
            entry = structs[current]
            if "NeonScroll" in line:
                entry["scroll"] = True
            for hit in SECTION_RE.finditer(line):
                rest = line[hit.end():]
                literal = LITERAL_RE.match(rest)
                if hit.group(1) == "Row":
                    if literal:
                        entry["events"].append(("row", literal.group(1)))
                elif literal:
                    entry["events"].append(("sec", literal.group(1)))
                elif rest.startswith("nil") or re.match(r"\w+:", rest):
                    skipped["untitled"] += 1
                    entry["events"].append(("sec", ""))
                else:
                    skipped["non_literal"] += 1
                    entry["events"].append(("sec", ""))
            for name in re.findall(r"\b([A-Z]\w+)\(", line):
                if name != current:
                    entry["events"].append(("ref", name))
    return structs, skipped


def read_window():
    text = open(WINDOW, encoding="utf-8").read()
    body = text.split("private var content: some View", 1)[1].split("\n    }", 1)[0]
    panes = {}
    parts = CASE_RE.split(body)
    for pane_id, tail in zip(parts[1::2], parts[2::2]):
        view = re.search(r"\b([A-Z]\w+)\(", tail)
        if view:
            panes.setdefault(pane_id, view.group(1))
    titles = {}
    order = []
    for pane_id, title in TAB_RE.findall(text):
        if pane_id not in titles:
            titles[pane_id] = title
            order.append(pane_id)
    return panes, titles, order


def sections_for(struct, structs, panes, seen):
    """A pane's ("sec", title) / ("row", title) events, inlining the helper views it renders.

    A reference is followed only when it names a view struct in the same file that
    is not itself a pane — that is what a factored-out section looks like (e.g.
    `AIModelSection` inside `CompletionsPane`). Anything else is a SwiftUI type or
    a sibling pane, and following it would splice in a foreign pane's sections.
    """
    if struct in seen or struct not in structs:
        return []
    seen.add(struct)
    out = []
    events = structs[struct]["events"]
    # Rows count only in a view that has sections of its own: a section-less helper
    # is usually a sheet editor (e.g. `MCPServerEditor`), whose form rows would
    # otherwise be pinned to whatever section happened to precede the reference.
    own_rows = any(kind == "sec" for kind, _ in events)
    for kind, value in events:
        if kind == "sec" or (kind == "row" and own_rows):
            out.append((kind, value))
        elif (value in structs and value not in panes
              and not structs[value]["scroll"]
              and structs[value]["file"] == structs[struct]["file"]):
            out.extend(sections_for(value, structs, panes, seen))
    return out


def build():
    structs, skipped = scan_structs()
    panes, titles, order = read_window()
    pane_structs = set(panes.values())
    rows = []
    missing = []
    for pane_id in order + [p for p in panes if p not in order]:
        struct = panes.get(pane_id)
        if struct is None:
            missing.append(pane_id)
            continue
        title = titles.get(pane_id, struct)
        # section title -> row keywords; "" is the pane row, which also collects rows
        # sitting outside any titled section (untitled or non-literal NeonSection).
        sections = {"": []}
        current = ""
        for kind, value in sections_for(struct, structs, pane_structs, set()):
            if kind == "sec":
                current = value
                sections.setdefault(current, [])
            elif value not in sections[current]:
                sections[current].append(value)
        for section, keywords in sections.items():
            rows.append((pane_id, title, section, keywords))
    lines = [
        "// Generated by app/scripts/gen-settings-index.py — do not edit by hand.",
        "// Re-run the script after adding a settings pane or a titled NeonSection;",
        "// SettingsSearchTests.testGeneratedIndexIsCurrent fails while this is stale.",
        "",
        "/// Every native settings pane, plus one row per titled section inside it.",
        "/// Extension panes are indexed separately at runtime — see"
        " `extensionSettingsIndex(registry:)`.",
        "let nativeSettingsIndex: [SettingsIndexEntry] = [",
    ]
    for pane_id, title, section, keywords in rows:
        extra = ""
        if keywords:
            extra = ",\n                       keywords: [%s]" % ", ".join(
                '"%s"' % esc(k) for k in keywords)
        lines.append(
            '    SettingsIndexEntry(paneID: "%s", paneTitle: "%s", section: "%s"%s),'
            % (esc(pane_id), esc(title), esc(section), extra)
        )
    lines += ["]", ""]
    return "\n".join(lines), skipped, missing, len(rows)


def esc(value):
    return value.replace("\\", "\\\\").replace('"', '\\"')


def main():
    text, skipped, missing, count = build()
    check = "--check" in sys.argv
    old = open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
    if check:
        if old == text:
            print("SettingsIndex.generated.swift is current (%d entries)." % count)
            return 0
        sys.stdout.writelines(
            difflib.unified_diff(
                old.splitlines(True), text.splitlines(True),
                fromfile="SettingsIndex.generated.swift (on disk)",
                tofile="SettingsIndex.generated.swift (regenerated)",
            )
        )
        print("\nStale. Run app/scripts/gen-settings-index.py.")
        return 1
    with open(OUT, "w", encoding="utf-8") as handle:
        handle.write(text)
    print("Wrote %s: %d entries." % (os.path.relpath(OUT, APP), count))
    print("Skipped NeonSections: %d untitled, %d non-literal title."
          % (skipped["untitled"], skipped["non_literal"]))
    if missing:
        print("Panes with no view struct in the content switch: %s" % ", ".join(missing))
    return 0


if __name__ == "__main__":
    sys.exit(main())
