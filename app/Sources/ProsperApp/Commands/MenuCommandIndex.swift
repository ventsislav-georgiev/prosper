// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// The AX menu-bar walk, the depth/item caps and the shortcut-glyph decode are
// ported from Vorssaint's Services/CommandBar/CommandBarMenus.swift. Prosper
// adds the pid + generation + TTL cache around it, because the palette warms
// the index on present() and scores against it while the walk is still running.

import AppKit
import ApplicationServices

/// One pressable menu item of the frontmost app, without the `AXUIElement` — the
/// element lives in `MenuCommandIndex`'s parallel store so this type stays pure
/// and testable, and so a row that outlives its generation can't press anything.
struct MenuCommand: Codable, Equatable {
    /// `"<generation>:<index>"` — see `MenuCommandIndex.decodeIndex`.
    let id: String
    /// Menu path above the item, e.g. `["Format", "Font"]`.
    let path: [String]
    let title: String
    /// Formatted glyphs, e.g. `"⇧⌘E"`. nil when the item has no key equivalent.
    let shortcut: String?

    /// `Format › Font › Bold` — the palette's secondary line and the extension's subtitle.
    var breadcrumb: String { (path + [title]).joined(separator: " › ") }
}

/// Turns AX's `AXMenuItemCmdChar` / `AXMenuItemCmdModifiers` pair into glyphs.
enum MenuShortcut {
    /// Modifier bitmask, upstream's: bit0 ⇧, bit1 ⌥, bit2 ⌃, and bit3 *set* means
    /// the item has **no** ⌘ — the mask records the absence, not the presence.
    static func format(char: String?, modifiers: Int) -> String? {
        guard let char, !char.isEmpty else { return nil }
        var glyphs = ""
        if modifiers & 0x04 != 0 { glyphs += "⌃" }
        if modifiers & 0x02 != 0 { glyphs += "⌥" }
        if modifiers & 0x01 != 0 { glyphs += "⇧" }
        if modifiers & 0x08 == 0 { glyphs += "⌘" }
        return glyphs + char.uppercased()
    }
}

/// Index of the frontmost app's menu commands, warmed when the runner opens and
/// read synchronously while the user types.
///
/// The walk is AX, so it can block for as long as the target app takes to answer;
/// it runs on `.userInitiated` and installs its result back on the main actor. A
/// warm inside the TTL is a no-op, which is what makes calling it from `present()`
/// on every open cheap.
@MainActor
final class MenuCommandIndex {
    static let shared = MenuCommandIndex()

    /// Reserved row-action id shared by the palette rows and `host.menus.press`.
    nonisolated static let pressActionID = "menus.press"

    /// Upstream's caps.
    nonisolated static let maximumDepth = 4
    nonisolated static let maximumItems = 400
    nonisolated static let axTimeout: Float = 0.35
    /// Upstream's cache lifetime. A menu bar changes with the app's own state
    /// (Undo greying out, a Window list growing), so it can't be cached forever.
    nonisolated static let ttl: TimeInterval = 8
    /// Settling delay between reactivating the target app and pressing the item.
    /// ponytail: a constant, not a handshake — bump it if presses land early.
    nonisolated static let activationSettle: TimeInterval = 0.06

    private(set) var generation = 0
    /// Localized name of the app the current rows belong to — the palette prefixes
    /// row subtitles with it. Resolved once per walk, not per keystroke.
    private(set) var appName = ""
    private var pid: pid_t?
    private var rows: [MenuCommand] = []
    private var elements: [AXUIElement] = []
    private var loadedAt = Date.distantPast
    private var loading = false

    /// True when a walk for `requested` would produce anything new.
    /// Pure so the cache policy is testable without an AX tree.
    nonisolated static func needsWalk(requested: pid_t, cached: pid_t?, loadedAt: Date,
                          loading: Bool, now: Date) -> Bool {
        if loading { return false }
        if cached != requested { return true }
        return now.timeIntervalSince(loadedAt) >= ttl
    }

    /// Row index encoded in `id`, or nil when the id is malformed or belongs to a
    /// generation the index has since replaced. Pure; the stale check is the whole
    /// point of the generation prefix — index 12 of the previous app's File menu is
    /// a different command than index 12 of this one.
    nonisolated static func decodeIndex(_ id: String, generation: Int) -> Int? {
        let parts = id.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let gen = Int(parts[0]), let idx = Int(parts[1]),
              gen == generation, idx >= 0 else { return nil }
        return idx
    }

    /// Kicks off a background walk of `pid`'s menu bar unless the cache is still
    /// fresh or a walk is already in flight. Returns immediately.
    func warm(pid: pid_t?) {
        guard let pid,
              Self.needsWalk(requested: pid, cached: self.pid, loadedAt: loadedAt,
                             loading: loading, now: Date()) else { return }
        loading = true
        let nextGeneration = generation + 1
        DispatchQueue.global(qos: .userInitiated).async {
            let walked = Self.walk(pid: pid, generation: nextGeneration)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.install(walked, pid: pid, generation: nextGeneration)
                }
            }
        }
    }

    private func install(_ walked: (rows: [MenuCommand], elements: [AXUIElement]),
                         pid: pid_t, generation: Int) {
        self.pid = pid
        self.generation = generation
        appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        rows = walked.rows
        elements = walked.elements
        loadedAt = Date()
        loading = false
    }

    /// Whatever the last completed walk produced. Empty until then — the palette
    /// simply shows no menu rows on the first keystrokes after opening.
    func cached() -> [MenuCommand] { rows }

    /// `cached()` as a JSON array, for `host.menus.list()`.
    func cachedJSON() -> String {
        guard let data = try? JSONEncoder().encode(rows),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    /// Presses the menu item behind `id`. Returns false when the id is stale or
    /// unknown; true means the press was dispatched (AX runs off the main actor,
    /// so the item's own success isn't awaited).
    @discardableResult
    func press(id: String) -> Bool {
        guard let idx = Self.decodeIndex(id, generation: generation),
              idx < elements.count else { return false }
        let element = elements[idx]
        DispatchQueue.global(qos: .userInitiated).async {
            AXUIElementPerformAction(element, kAXPressAction as CFString)
        }
        return true
    }

    // MARK: - AX walk (upstream CommandBarMenus, off-main)

    private nonisolated static func walk(pid: pid_t, generation: Int)
        -> (rows: [MenuCommand], elements: [AXUIElement]) {
        var rows: [MenuCommand] = []
        var elements: [AXUIElement] = []
        guard AXIsProcessTrusted() else { return (rows, elements) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        guard let menuBar = copyElement(app, kAXMenuBarAttribute) else { return (rows, elements) }

        // "Apple" is the  menu, "Window"/"Help" are noise the palette already
        // covers better; upstream skips the same three.
        let skipped: Set<String> = ["Apple", "Window", "Help"]
        for menu in children(of: menuBar) {
            guard let title = copyString(menu, kAXTitleAttribute), !title.isEmpty,
                  !skipped.contains(title) else { continue }
            for child in children(of: menu) {
                collect(child, path: [title], generation: generation,
                        rows: &rows, elements: &elements, depth: 1)
                if rows.count >= maximumItems { return (rows, elements) }
            }
        }
        return (rows, elements)
    }

    private nonisolated static func collect(_ element: AXUIElement, path: [String],
                                            generation: Int,
                                            rows: inout [MenuCommand],
                                            elements: inout [AXUIElement],
                                            depth: Int) {
        guard depth <= maximumDepth, rows.count < maximumItems else { return }
        let role = copyString(element, kAXRoleAttribute)
        if role == kAXMenuRole as String {
            for child in children(of: element) {
                collect(child, path: path, generation: generation,
                        rows: &rows, elements: &elements, depth: depth + 1)
            }
            return
        }
        guard role == kAXMenuItemRole as String,
              let title = copyString(element, kAXTitleAttribute), !title.isEmpty else { return }

        // A submenu parent isn't pressable — recurse into it instead.
        let submenus = children(of: element)
        if !submenus.isEmpty {
            for child in submenus {
                collect(child, path: path + [title], generation: generation,
                        rows: &rows, elements: &elements, depth: depth + 1)
            }
            return
        }
        guard isEnabled(element) else { return }
        rows.append(MenuCommand(id: "\(generation):\(rows.count)",
                                path: path,
                                title: title,
                                shortcut: shortcut(of: element)))
        elements.append(element)
    }

    private nonisolated static func shortcut(of element: AXUIElement) -> String? {
        var modifiers = 0
        if let raw = copyValue(element, "AXMenuItemCmdModifiers"),
           CFGetTypeID(raw) == CFNumberGetTypeID() {
            modifiers = (raw as? Int) ?? 0
        }
        return MenuShortcut.format(char: copyString(element, "AXMenuItemCmdChar"),
                                   modifiers: modifiers)
    }

    // MARK: - AX attribute helpers

    private nonisolated static func children(of element: AXUIElement) -> [AXUIElement] {
        guard let raw = copyValue(element, kAXChildrenAttribute),
              CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
        return (raw as? [AXUIElement]) ?? []
    }

    private nonisolated static func copyElement(_ element: AXUIElement,
                                                _ attribute: String) -> AXUIElement? {
        guard let raw = copyValue(element, attribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private nonisolated static func copyString(_ element: AXUIElement,
                                               _ attribute: String) -> String? {
        guard let raw = copyValue(element, attribute),
              CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        return (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func copyValue(_ element: AXUIElement,
                                              _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    /// AX omits `AXEnabled` on some items; absent means enabled, matching upstream.
    private nonisolated static func isEnabled(_ element: AXUIElement) -> Bool {
        guard let raw = copyValue(element, kAXEnabledAttribute),
              CFGetTypeID(raw) == CFBooleanGetTypeID() else { return true }
        return (raw as? Bool) ?? true
    }
}
