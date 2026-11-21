import Foundation

/// #1858: snippets over the control channel: snippets.list/get/set/remove, through SnippetStore (the palette's own
/// store). Text from an agent is outside text: a control or hidden character (other than LF and tab) refuses it whole,
/// and so does any placeholder but {cursor}, {date}, {time}, {datetime}, {uuid} and {argument} ({clipboard} would paste
/// the person's clipboard history, {snippet:…} embeds another snippet with the same context, custom ones run extensions).
/// A snippet an agent writes never auto-expands and carries the stored agentMade marker: set and remove touch only
/// such snippets, and set refuses a name or keyword that a person's snippet, a phone snippet or a Text Replacement
/// already answers to, so an agent snippet never takes over their embeds, hotkeys or keywords. set and remove are
/// changes with undo; an undo does nothing once the snippet changed after the agent. On demand only.
@MainActor
enum ControlSnippets {
    /// Seams: the store's own calls; rows swap in memory (SnippetStore writes ~/.config/prosper/snippets.json, even under XCTest).
    static var storeAll: () -> [SnippetHit] = { SnippetStore.all() }
    static var storeSave: (SnippetHit) -> Void = { SnippetStore.save($0) }
    static var storeRemove: (String) -> Void = { SnippetStore.remove(name: $0) }
    static var storeCollections: () -> [SnippetCollection] = { SnippetStore.allCollections() }
    static var phoneSets: () -> [(device: String, set: PhoneSnippetStore.DeviceSet)] = { PhoneSnippetStore.live.sets() }
    static var replacements: () -> [String: String] = { TextReplacements.items() }

    static let maxName = 100, maxKeyword = 50, maxDescription = 500, maxText = 20_000   // text in UTF-8 bytes

    /// The placeholders an agent body may use, by the name PlaceholderEngine resolves (head up to ':' or a space, lowercased).
    static let allowedPlaceholders: Set<String> = ["cursor", "date", "time", "datetime", "uuid", "argument"]


    /// The first of `name`, `keyword` or its trigger that a person's snippet (name, keyword, trigger), a phone snippet
    /// (name, keyword) or a Text Replacement shortcut already is. Exact, as {snippet:key} lookups and the matcher compare.
    static func collision(name: String, keyword: String, collection: String) -> String? {
        let affix = Dictionary(storeCollections().map { ($0.name, (prefix: $0.prefix, suffix: $0.suffix)) }) { a, _ in a }
        func trigger(_ kw: String, _ col: String) -> String {
            kw.isEmpty ? "" : SnippetStore.effectiveTrigger(keyword: kw, collection: col, collections: affix)
        }
        var taken = Set(replacements().keys)
        for h in storeAll() where !h.agentMade { taken.formUnion([h.name, h.keyword, trigger(h.keyword, h.collection)]) }
        for (_, set) in phoneSets() { for s in set.snippets { taken.formUnion([s.name, SnippetStore.sanitizeKeyword(s.keyword ?? "")]) } }
        taken.remove("")
        return [name, keyword, trigger(keyword, collection)].first { taken.contains($0) }
    }

    /// An optional string argument kept as given (not trimmed: "" clears), refused when it has an unseen scalar or is too long.
    private static func optional(_ args: [String: ControlJSON], _ key: String, max: Int) throws -> String? {
        guard case .string(let raw)? = args[key] else { return nil }
        guard raw.count <= max else { throw ControlError("\(key) is longer than \(max) characters") }
        if ControlSessionsTalk.hasUnseen(raw) { throw ControlError("\(key) has a control or hidden character") }
        return raw.trimmingCharacters(in: .whitespaces)
    }

    /// The stored snippet by exact name, else by case folded name (two matches: ambiguous).
    static func find(_ name: String) throws -> SnippetHit {
        let items = storeAll()
        if let hit = items.first(where: { $0.name == name }) { return hit }
        let hits = items.filter { $0.name.lowercased() == name.lowercased() }
        guard hits.count < 2 else { throw ControlError("\(hits.count) snippets are named \(OutsideText.shown(name, max: maxName)): use the exact name") }
        guard let hit = hits.first else { throw ControlError("no snippet named \(OutsideText.shown(name, max: maxName)) (snippets.list lists them)") }
        return hit
    }

    // MARK: - snippets.list / snippets.get

    /// {"snippets": [{name, keyword, collection, description, autoExpand, richText, bytes}]} by name; no bodies.
    static func list() -> ControlJSON {
        .object(["snippets": .array(storeAll().map { h in
            .object(["name": .string(h.name), "keyword": .string(h.keyword), "collection": .string(h.collection),
                     "description": .string(h.description), "autoExpand": .bool(h.autoExpand), "richText": .bool(h.richText),
                     "bytes": .number(Double(h.text.utf8.count))])
        })])
    }

    /// The list's fields plus `text` (RTF source when richText).
    static func get(_ args: [String: ControlJSON]) throws -> ControlJSON {
        let h = try find(try ControlSessions.required(args, "name"))
        return .object(["name": .string(h.name), "keyword": .string(h.keyword), "collection": .string(h.collection),
                        "description": .string(h.description), "autoExpand": .bool(h.autoExpand), "richText": .bool(h.richText),
                        "text": .string(h.text)])
    }

    // MARK: - snippets.set

    /// Saves (or replaces, by exact name) a plain text snippet with auto-expand off. A replaced snippet keeps its
    /// collection, and its keyword and description unless given. Undo restores the previous snippet, or removes the new one.
    static func set(_ args: [String: ControlJSON]) throws -> ControlChange {
        let name = try ControlSessions.required(args, "name")
        guard name.count <= maxName else { throw ControlError("name is longer than \(maxName) characters") }
        if ControlSessionsTalk.hasUnseen(name) { throw ControlError("name has a control or hidden character") }
        guard case .string(let text)? = args["text"], !text.isEmpty else { throw ControlError("argument 'text' is empty") }
        guard text.utf8.count <= maxText else { throw ControlError("text is longer than \(maxText) bytes") }
        if ControlSessionsTalk.hasUnseen(text, allowing: ["\n", "\t"]) {
            throw ControlError("text has a control or hidden character: only line breaks (LF) and tabs are allowed")
        }
        if let bad = PlaceholderEngine.tokenNames(in: text).first(where: { !allowedPlaceholders.contains($0) }) {
            throw ControlError("text cannot use a {\(OutsideText.shown(bad, max: 40))} placeholder: only {cursor}, {date}, {time}, {datetime}, {uuid} and {argument} are allowed")
        }
        let keywordArg = try optional(args, "keyword", max: maxKeyword), description = try optional(args, "description", max: maxDescription)
        let old = storeAll().first { $0.name == name }
        if let old, !old.agentMade {
            throw ControlError("\(OutsideText.shown(name, max: maxName)) is the person's snippet: an agent may only replace snippets it made")
        }
        let keyword = SnippetStore.sanitizeKeyword(keywordArg ?? old?.keyword ?? ""), collection = old?.collection ?? ""
        if let clash = collision(name: name, keyword: keyword, collection: collection) {
            throw ControlError("\(OutsideText.shown(clash, max: maxName)) is already the name or keyword of the person's snippet, a phone snippet or a Text Replacement")
        }
        let hit = SnippetHit(name: name, keyword: keyword, text: text, collection: collection,
                             description: description ?? old?.description ?? "", autoExpand: false, richText: false, agentMade: true)
        storeSave(hit)
        // The store drops what it cannot keep (an empty keyword after its cleaning is fine; a missing or other text is not).
        guard let saved = storeAll().first(where: { $0.name == name }), saved.text == text else { throw ControlError("the snippet store did not save it") }
        return ControlChange(summary: old == nil ? "new snippet \(name)" : "replaced snippet \(name)", result: .string(name),
                             verb: "saved a snippet", undo: {
            guard storeAll().first(where: { $0.name == name }) == saved else { return }   // edited since: theirs stays
            if let old { storeSave(old) } else { storeRemove(name) }
        })
    }

    // MARK: - snippets.remove

    /// Deletes one snippet an agent made (exact name, else case folded). Undo puts it back as it was, unless the name is taken again.
    static func remove(_ args: [String: ControlJSON]) throws -> ControlChange {
        let old = try find(try ControlSessions.required(args, "name"))
        guard old.agentMade else {
            throw ControlError("\(OutsideText.shown(old.name, max: maxName)) is the person's snippet: an agent may only remove snippets it made")
        }
        storeRemove(old.name)
        guard storeAll().first(where: { $0.name == old.name }) == nil else { throw ControlError("the snippet store did not remove it") }
        return ControlChange(summary: old.name, result: .string(old.name), verb: "removed a snippet", undo: {
            guard !storeAll().contains(where: { $0.name == old.name }) else { return }   // re-made since: theirs stays
            storeSave(old)
        })
    }
}

extension ControlRegistry {
    /// #1858: wired in ControlRegistry.standard().
    static func registerSnippets(_ r: inout ControlRegistry) {
        let name = ControlArg(type: "string", required: true, summary: "the snippet's name (snippets.list)")
        r.register(ControlCommand(name: "snippets.list", summary: "List saved snippets: name, keyword, collection, description, autoExpand, richText, bytes (no text).",
                                  args: [:], mutates: false) { _, _ in ControlSnippets.list() })
        r.register(ControlCommand(name: "snippets.get", summary: "One snippet with its text.", args: ["name": name], mutates: false) { _, a in
            try ControlSnippets.get(a)
        })
        r.register(.change(name: "snippets.set", summary: "Save or replace a plain text snippet the agent made. It never auto-expands; only {cursor} {date} {time} {datetime} {uuid} {argument} placeholders; a name or keyword the person's, a phone's or a Text Replacement's snippet uses is refused.", args: [
            "name": name,
            "text": ControlArg(type: "string", required: true, summary: "the body; line breaks and tabs allowed, no other control characters"),
            "keyword": ControlArg(type: "string", summary: "its keyword (kept when replacing, if absent)"),
            "description": ControlArg(type: "string", summary: "its description (kept when replacing, if absent)"),
        ]) { _, a in try ControlSnippets.set(a) })
        r.register(.change(name: "snippets.remove", summary: "Delete a snippet the agent made.", args: ["name": name]) { _, a in try ControlSnippets.remove(a) })
    }
}
