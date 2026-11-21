import Foundation

/// #1858: snippets over the control channel: snippets.list/get/set/remove, through SnippetStore (the palette's own
/// store). Text from an agent is outside text: a control or hidden character (other than LF and tab) refuses it whole,
/// and so does any {clipboard} placeholder (it would paste the person's clipboard history when they expand it).
/// A snippet an agent writes never auto-expands, even when it replaces one that did: the agent's text is not typed
/// into the person's apps on a keyword they set earlier. set and remove are changes with undo. On demand only.
@MainActor
enum ControlSnippets {
    /// Seams: the store's own calls; rows swap in memory (SnippetStore writes ~/.config/prosper/snippets.json, even under XCTest).
    static var storeAll: () -> [SnippetHit] = { SnippetStore.all() }
    static var storeSave: (SnippetHit) -> Void = { SnippetStore.save($0) }
    static var storeRemove: (String) -> Void = { SnippetStore.remove(name: $0) }

    static let maxName = 100, maxKeyword = 50, maxDescription = 500, maxText = 20_000   // text in UTF-8 bytes

    /// {clipboard}, {clipboard:N}, {Clipboard : 1}, {clipboard | trim}, {clipboard 1}: the engine's name is the head up to
    /// ':' or a space, case folded, so the token's name only has to start with "clipboard" and end there.
    private static let clipboardToken = try! NSRegularExpression(pattern: #"\{\s*clipboard(?![\p{L}\p{N}_])"#, options: [.caseInsensitive])

    static func hasClipboard(_ text: String) -> Bool {
        clipboardToken.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
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
        if hasClipboard(text) { throw ControlError("text cannot use a {clipboard} placeholder: the clipboard stays with the person") }
        let keyword = try optional(args, "keyword", max: maxKeyword), description = try optional(args, "description", max: maxDescription)
        let old = storeAll().first { $0.name == name }
        let hit = SnippetHit(name: name, keyword: keyword ?? old?.keyword ?? "", text: text, collection: old?.collection ?? "",
                             description: description ?? old?.description ?? "", autoExpand: false, richText: false)
        storeSave(hit)
        // The store drops what it cannot keep (an empty keyword after its cleaning is fine; a missing or other text is not).
        guard storeAll().first(where: { $0.name == name })?.text == text else { throw ControlError("the snippet store did not save it") }
        return ControlChange(summary: old == nil ? "new snippet \(name)" : "replaced snippet \(name)", result: .string(name),
                             verb: "saved a snippet", undo: { if let old { storeSave(old) } else { storeRemove(name) } })
    }

    // MARK: - snippets.remove

    /// Deletes one snippet (exact name, else case folded). Undo puts it back as it was.
    static func remove(_ args: [String: ControlJSON]) throws -> ControlChange {
        let old = try find(try ControlSessions.required(args, "name"))
        storeRemove(old.name)
        guard storeAll().first(where: { $0.name == old.name }) == nil else { throw ControlError("the snippet store did not remove it") }
        return ControlChange(summary: old.name, result: .string(old.name), verb: "removed a snippet", undo: { storeSave(old) })
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
        r.register(.change(name: "snippets.set", summary: "Save or replace a plain text snippet. It never auto-expands; {clipboard} placeholders are refused.", args: [
            "name": name,
            "text": ControlArg(type: "string", required: true, summary: "the body; line breaks and tabs allowed, no other control characters"),
            "keyword": ControlArg(type: "string", summary: "its keyword (kept when replacing, if absent)"),
            "description": ControlArg(type: "string", summary: "its description (kept when replacing, if absent)"),
        ]) { _, a in try ControlSnippets.set(a) })
        r.register(.change(name: "snippets.remove", summary: "Delete a snippet.", args: ["name": name]) { _, a in try ControlSnippets.remove(a) })
    }
}
