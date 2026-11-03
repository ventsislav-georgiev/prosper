import AppKit

/// #731: the snippets each phone owns and pushes with 0x2c putPhoneSnippets, shown on this
/// Mac read-only (palette, keyword expansion, Settings). Stored in phone-snippets.json beside
/// snippets.json, keyed by device id: {device_id: {name, hash, updated, snippets}}. Never in
/// snippets.json, the UserDefaults maps or the export, so the library 0x0f never sends a phone
/// its own set back, and nothing Mac-side can edit or save over a phone snippet.
struct PhoneSnippetStore: Sendable {
    var url: URL

    static let fileName = "phone-snippets.json"
    static let maxSnippets = 5000
    static var live: PhoneSnippetStore {
        PhoneSnippetStore(url: SnippetStore.fileURL.deletingLastPathComponent().appendingPathComponent(fileName))
    }

    /// A phone snippet's id in the matcher and expander. A Mac snippet's id is its bare name, so the
    /// prefix keeps a phone snippet named like a Mac one from shadowing or resolving to it.
    static let idPrefix = "\u{1}phone\u{1}"
    static func id(device: String, name: String) -> String { idPrefix + device + "\u{1}" + name }

    struct Snippet: Codable, Equatable, Sendable {
        var name: String
        var text: String
        var keyword: String?
        var group: String?
    }

    struct DeviceSet: Codable, Equatable, Sendable {
        var name: String?
        var hash: String
        /// Seconds since 1970: between phones, the most recently put set wins a keyword.
        var updated: Double
        var snippets: [Snippet]

        /// What the palette groups the set under.
        var label: String { name ?? "iPhone" }
    }

    private struct Put: Decodable {
        var deviceID: String
        var deviceName: String?
        var hash: String
        var snippets: [Snippet]
        enum CodingKeys: String, CodingKey {
            case deviceID = "device_id", deviceName = "device_name", hash, snippets
        }
    }

    enum PutResult: Equatable {
        case ok(count: Int, hash: String)
        case refused(String)
    }

    /// One lock for every read-modify-write: two phones putting at once, or a put racing Remove.
    private static let lock = NSLock()

    // MARK: - Put / remove

    /// Idempotent replace of one device's set; an empty list removes the device. Every refusal
    /// leaves the file untouched; an unchanged hash skips the write and still succeeds.
    func put(_ payload: Data, now: Date = Date()) -> PutResult {
        guard payload.count <= DchLibraryOps.fileCap else { return .refused("too large") }
        guard let req = try? JSONDecoder().decode(Put.self, from: payload),
              (1...128).contains(req.deviceID.count),
              req.snippets.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 256 })
        else { return .refused("malformed snippets") }
        guard req.snippets.count <= Self.maxSnippets else { return .refused("too large") }
        var seen = Set<String>()
        for s in req.snippets where !seen.insert(s.name).inserted { return .refused("duplicate name: \(s.name)") }
        return Self.lock.withLock {
            var all = load()
            if all[req.deviceID]?.hash == req.hash { return .ok(count: req.snippets.count, hash: req.hash) }
            all[req.deviceID] = req.snippets.isEmpty ? nil
                : DeviceSet(name: req.deviceName, hash: req.hash, updated: now.timeIntervalSince1970, snippets: req.snippets)
            guard save(all) else { return .refused("could not save snippets") }
            return .ok(count: req.snippets.count, hash: req.hash)
        }
    }

    /// Settings' Remove: drops one device's set.
    func remove(deviceID: String) {
        Self.lock.withLock {
            var all = load()
            guard all.removeValue(forKey: deviceID) != nil else { return }
            _ = save(all)
        }
    }

    // MARK: - Read

    /// Every device's set, keyed by device id. A missing or unreadable file is no sets.
    func load() -> [String: DeviceSet] {
        guard let data = try? Data(contentsOf: url),
              let all = try? JSONDecoder().decode([String: DeviceSet].self, from: data) else { return [:] }
        return all
    }

    /// The sets newest first (ties by device id): the order keyword clashes resolve in.
    func sets() -> [(device: String, set: DeviceSet)] {
        load().map { ($0.key, $0.value) }
            .sorted { $0.set.updated != $1.set.updated ? $0.set.updated > $1.set.updated : $0.device < $1.device }
    }

    /// The phone snippet behind a namespaced id, as the expander plans it (never rich).
    func hit(id: String) -> SnippetHit? {
        for (device, set) in load() {
            for s in set.snippets where Self.id(device: device, name: s.name) == id {
                return SnippetHit(name: id, keyword: SnippetStore.sanitizeKeyword(s.keyword ?? ""), text: s.text,
                                  collection: set.label, description: s.group ?? "")
            }
        }
        return nil
    }

    /// `{snippet:key}` inside a template: the newest phone snippet with that keyword or name.
    static func text(forKey key: String, in sets: [(device: String, set: DeviceSet)]) -> String? {
        for (_, set) in sets {
            if let s = set.snippets.first(where: { SnippetStore.sanitizeKeyword($0.keyword ?? "") == key || $0.name == key }) {
                return s.text
            }
        }
        return nil
    }

    /// The expander's id lookup: a phone id resolves only among the phone sets, a #732 Text
    /// Replacement id only among the replacements, any other id only among the Mac's own snippets.
    static func lookup(_ id: String, phone: PhoneSnippetStore = .live,
                       mac: (String) -> SnippetHit? = SnippetStore.byName,
                       replacements: [String: String] = TextReplacements.items()) -> SnippetHit? {
        if TextReplacements.isID(id) { return TextReplacements.hit(id: id, in: replacements) }
        return id.hasPrefix(idPrefix) ? phone.hit(id: id) : mac(id)
    }

    /// Mac triggers as given, then each phone keyword that no Mac keyword (auto-expanding or not)
    /// and no newer phone set already holds, then (#732) each Text Replacement shortcut nothing
    /// above holds. `macKeywords` is every Mac effective trigger.
    static func triggers(mac: [(trigger: String, id: String)], macKeywords: Set<String>,
                         sets: [(device: String, set: DeviceSet)],
                         replacements: [String: String] = [:]) -> [(trigger: String, id: String)] {
        var taken = macKeywords, out = mac
        for (device, set) in sets {
            for s in set.snippets {
                let kw = SnippetStore.sanitizeKeyword(s.keyword ?? "")
                guard !kw.isEmpty, taken.insert(kw).inserted else { continue }
                out.append((kw, id(device: device, name: s.name)))
            }
        }
        // A shortcut with a space or quote is not typeable as a keyword: search only, never sanitized
        // into a different trigger.
        for shortcut in replacements.keys.sorted()
        where !shortcut.isEmpty && SnippetStore.sanitizeKeyword(shortcut) == shortcut && taken.insert(shortcut).inserted {
            out.append((shortcut, TextReplacements.id(shortcut)))
        }
        return out
    }

    // MARK: - Internals

    private func save(_ all: [String: DeviceSet]) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(all) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("prosper: failed to write \(Self.fileName): \(error)")
            return false
        }
        SnippetStore.touch()   // the expander rebuilds its keyword cache
        return true
    }
}

/// #732: the user's macOS Text Replacements (iCloud-synced, so the iPhone's too), read-only:
/// palette search, keyword expansion after the Mac snippets and the phone sets, inserted literally.
/// Read through NSSpellChecker's public [shortcut: phrase] dictionary, never the KeyboardServices db;
/// nothing here writes. Never in SnippetStore, so never in snippets.json, the export or the 0x0f payload.
enum TextReplacements {
    static let idPrefix = "\u{1}textreplacement\u{1}"
    static let label = "Text Replacements"
    static func id(_ shortcut: String) -> String { idPrefix + shortcut }
    static func isID(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// The read seam. Never the real NSSpellChecker under XCTest: a test swaps this.
    nonisolated(unsafe) static var read: @MainActor () -> [String: String] = {
        NSClassFromString("XCTestCase") == nil ? NSSpellChecker.shared.userReplacementsDictionary : [:]
    }

    /// The clock seam for the throttle (#733): a test drives a fake clock.
    nonisolated(unsafe) static var now: @MainActor () -> Date = Date.init
    /// A menu-bar app can go hours without an activation; the expander re-reads this often.
    static let staleAfter: TimeInterval = 30

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: [String: String] = [:]
    @MainActor private static var lastRefresh: Date?

    /// Re-reads (app activation, every expander keyword rebuild). A change bumps SnippetStore's
    /// token so the expander rebuilds its keywords.
    @MainActor static func refresh() {
        lastRefresh = now()
        let fresh = Preferences.snippetsTextReplacements ? read() : [:]   // off: no read at all
        let changed = lock.withLock { () -> Bool in
            defer { cached = fresh }
            return cached != fresh
        }
        if changed { SnippetStore.touch() }
    }

    /// #733: refresh() once the last one is `staleAfter` old, so an entry added in System Settings
    /// expands without an app activation. Called on every expander keystroke, before its token guard.
    @MainActor static func refreshIfStale() {
        if let last = lastRefresh, now().timeIntervalSince(last) < staleAfter { return }
        refresh()
    }

    /// The last read, or none while Settings > Snippets "Include macOS Text Replacements" is off.
    static func items() -> [String: String] {
        Preferences.snippetsTextReplacements ? lock.withLock { cached } : [:]
    }

    /// The replacement behind an id: name = phrase, keyword = shortcut, text = the phrase, literal.
    static func hit(id: String, in items: [String: String]) -> SnippetHit? {
        guard isID(id) else { return nil }
        let shortcut = String(id.dropFirst(idPrefix.count))
        guard let phrase = items[shortcut] else { return nil }
        return SnippetHit(name: phrase, keyword: shortcut, text: phrase, collection: label, literal: true)
    }
}
