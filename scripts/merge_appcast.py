#!/usr/bin/env python3
"""Merge a freshly generated single-item Sparkle appcast into the canonical feed.

Prosper hosts ONE appcast (the file attached to the GitHub release that GitHub
serves as "latest" — see scripts/Info.plist `SUFeedURL`). It must list both the
newest stable build *and* the newest beta build so that:

  - stable users (default channel only) update to the highest stable item, while
  - beta users (allowed the `beta` channel) update to the highest item overall.

`generate_appcast` only ever sees the one freshly built .zip in dist/, so it
emits an appcast with a single <item>. This script folds that item into the
previously published feed: union the items, dedupe by <sparkle:version> (the
new item wins on a tie), sort newest-first, and keep the most recent KEEP items.

Usage:
    merge_appcast.py CANONICAL_XML NEW_XML OUTPUT_XML [KEEP]

CANONICAL_XML may be missing/empty (first ever release) — treated as no items.
NEW_XML and OUTPUT_XML may be the same path (NEW is fully parsed before writing).
"""
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def load_items(path):
    """Return list of <item> Elements from an appcast file (empty on any failure)."""
    if not path:
        return []
    try:
        with open(path, "rb") as fh:
            data = fh.read().strip()
        if not data:
            return []
        root = ET.fromstring(data)
    except (OSError, ET.ParseError):
        return []
    channel = root.find("channel")
    if channel is None:
        return []
    return list(channel.findall("item"))


def version_key(item):
    """Sort key: the integer CFBundleVersion from <sparkle:version>.

    Falls back to the version attribute on the <enclosure>, then 0, so a
    malformed item sorts last rather than crashing the merge.
    """
    el = item.find(f"{{{SPARKLE}}}version")
    text = el.text if el is not None and el.text else None
    if text is None:
        enc = item.find("enclosure")
        if enc is not None:
            text = enc.get(f"{{{SPARKLE}}}version")
    try:
        return int((text or "0").strip())
    except ValueError:
        return 0


def main():
    if len(sys.argv) < 4:
        sys.exit("usage: merge_appcast.py CANONICAL NEW OUTPUT [KEEP]")
    canonical, new_path, out_path = sys.argv[1:4]
    keep = int(sys.argv[4]) if len(sys.argv) > 4 else 10

    # Parse BOTH inputs before writing — OUTPUT may alias NEW.
    new_items = load_items(new_path)
    old_items = load_items(canonical)

    # New items take precedence on a version collision.
    by_version = {}
    for item in old_items:
        by_version[version_key(item)] = item
    for item in new_items:
        by_version[version_key(item)] = item

    ordered = sorted(by_version.values(), key=version_key, reverse=True)[:keep]

    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Prosper"
    for item in ordered:
        channel.append(item)

    ET.ElementTree(rss).write(out_path, encoding="utf-8", xml_declaration=True)
    kept = ", ".join(str(version_key(i)) for i in ordered) or "(none)"
    print(f"merged appcast → {out_path}: {len(ordered)} item(s) [versions: {kept}]")


if __name__ == "__main__":
    main()
