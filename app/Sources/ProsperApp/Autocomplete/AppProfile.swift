import AppKit

/// Classifies the frontmost application so the autocomplete pipeline can adapt to
/// how that app exposes (or fails to expose) text.
///
/// The Accessibility API is reliable for native AppKit text fields, but
/// Chromium/Electron apps (Slack, Notion, VS Code) expose little or nothing
/// through the integer-offset text attributes — their caret and text live behind
/// the WebKit text-marker APIs and Chromium pasteboard flavors. Terminals need a
/// different completion style, and credential managers must never be completed
/// into. `AppProfile` is the single place that encodes these per-app decisions so
/// the rest of the engine stays app-agnostic.
struct AppProfile: Sendable, Equatable {
    let bundleId: String?
    let kind: Kind

    enum Kind: Sendable {
        /// Chromium/Electron shell — AX text is unreliable; prefer the text-marker
        /// caret path and Chromium-pasteboard / OCR context extraction.
        case electron
        /// A terminal emulator — monospaced, command-oriented; completion should be
        /// conservative (see `TerminalCompletionMode` in Cotypist's design).
        case terminal
        /// A native web browser chrome (address bar etc.); page text fields still
        /// complete, but the omnibox is handled separately by `BrowserURL`.
        case browser
        /// A credential / password manager — NEVER complete here (leaks secrets,
        /// fights the app's own secure fields).
        case secure
        /// Everything else: native AppKit / standard text input.
        case standard
    }

    /// True for Chromium/Electron shells where the marker/pasteboard/OCR paths win.
    var isElectron: Bool { kind == .electron }
    /// True for terminal emulators.
    var isTerminal: Bool { kind == .terminal }
    /// True when completion must be fully suppressed for this app.
    var suppressesCompletion: Bool { kind == .secure }

    /// Whether inline completion can work in this app at all. Terminals are
    /// classified (`.terminal`) but have no completion implementation — they
    /// expose no AX-editable text, so the engine never triggers; secure apps are
    /// hard-suppressed. The menu bar uses this to show an honest
    /// "not supported" row instead of a misleading enabled checkmark.
    var supportsInlineCompletion: Bool {
        switch kind {
        case .terminal, .secure: return false
        case .electron, .browser, .standard: return true
        }
    }

    // MARK: - Writing surface (situational context for the completion prompt)

    /// What kind of writing the user is doing, inferred from the app. Drives the
    /// situational context and tone guidance handed to the LLM so a chat message
    /// reads casual and an email reads composed. Independent of `Kind` (which is
    /// about how the app exposes text); a chat app can be electron *and* `.chat`.
    enum Surface: Sendable, Equatable {
        case chat, email, social, notes, code, docs, terminal, browser, generic

        /// Human label used in the prompt ("a chat app", "an email client").
        var label: String {
            switch self {
            case .chat: return "a chat / instant-messaging app"
            case .email: return "an email client"
            case .social: return "a social-media app"
            case .notes: return "a notes app"
            case .code: return "a code / technical editor"
            case .docs: return "a document editor"
            case .terminal: return "a terminal"
            case .browser: return "a web browser"
            case .generic: return "an app"
            }
        }

        /// Surfaces where the visible content is a back-and-forth the user is
        /// replying into — so OCR should capture the dialog *above* the caret as
        /// conversation context, not just the line beside it.
        var isConversational: Bool {
            switch self {
            case .chat, .email, .social: return true
            default: return false
            }
        }

        /// Tone/length guidance appended to the situational context. Empty for
        /// `.generic` (no useful steer).
        var promptHint: String {
            switch self {
            case .chat:
                return "This is a live conversation, so keep the continuation short, "
                    + "casual, and conversational — contractions and an informal "
                    + "register are good; do not write like an essay."
            case .email:
                return "Write in complete, well-punctuated sentences with a "
                    + "professional but natural tone."
            case .social:
                return "Keep it punchy, casual, and brief, as fits a public post."
            case .notes:
                return "These are personal notes — be concise and neutral; fragments "
                    + "are fine."
            case .code:
                return "Output may be code, identifiers, or technical prose; preserve "
                    + "the surrounding syntax, indentation, and naming style."
            case .docs:
                return "Use clear, well-formed prose that fits a written document."
            case .terminal:
                return "Complete shell commands, flags, and file paths; never add "
                    + "prose or explanations."
            case .browser:
                return "This is a text field on a web page."
            case .generic:
                return ""
            }
        }
    }

    var surface: Surface { Self.surface(for: bundleId, kind: kind) }

    /// Maps a bundle id (plus the already-computed `Kind`) to a writing surface.
    static func surface(for bundleId: String?, kind: Kind) -> Surface {
        let bid = (bundleId ?? "").lowercased()
        if let s = surfaceByBundleId[bid] { return s }
        // Fall back to the structural kind for unlisted apps.
        switch kind {
        case .terminal: return .terminal
        case .browser: return .browser
        case .secure, .electron, .standard: return .generic
        }
    }

    /// Infers the writing surface from a web host (the active browser tab or a
    /// Chromium/Electron app's source URL), so "web.telegram.org" reads as chat
    /// and "mail.google.com" as email. Unknown sites fall back to `.browser`.
    static func surface(forHost host: String?) -> Surface {
        guard let host = host?.lowercased(), !host.isEmpty else { return .browser }
        func has(_ needles: String...) -> Bool {
            needles.contains { host == $0 || host.hasSuffix("." + $0) || host.contains($0) }
        }
        if has("web.telegram.org", "telegram.org", "web.whatsapp.com", "discord.com",
               "slack.com", "messenger.com", "teams.microsoft.com", "teams.live.com",
               "chat.google.com") { return .chat }
        if has("mail.google.com", "outlook.office.com", "outlook.live.com",
               "mail.proton.me", "mail.yahoo.com") { return .email }
        if has("twitter.com", "x.com", "reddit.com", "mastodon", "threads.net",
               "bsky.app", "facebook.com", "instagram.com", "linkedin.com") { return .social }
        if has("github.com", "gitlab.com", "stackoverflow.com", "stackexchange.com",
               "codepen.io", "replit.com") { return .code }
        if has("docs.google.com", "notion.so", "atlassian.net", "confluence",
               "quip.com", "coda.io") { return .docs }
        return .browser
    }

    /// Live, best-effort display name for the app — the app's own title, resolved
    /// dynamically (no hardcoded id→name table): the running instance's localized
    /// name, else the installed bundle's display name, else its file name.
    static func displayName(for bundleId: String?) -> String? {
        guard let bundleId, !bundleId.isEmpty else { return nil }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first,
           let name = running.localizedName, !name.isEmpty {
            return name
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
              let bundle = Bundle(url: url) else { return nil }
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let n = (bundle.localizedInfoDictionary?[key] ?? bundle.infoDictionary?[key]) as? String,
               !n.isEmpty {
                return n
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// The profile of the currently frontmost application.
    static func current() -> AppProfile {
        profile(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    /// Pure classifier (testable): maps a bundle id to a profile.
    static func profile(for bundleId: String?) -> AppProfile {
        let bid = (bundleId ?? "").lowercased()
        let kind: Kind
        if secureBundleIds.contains(bid) {
            kind = .secure
        } else if terminalBundleIds.contains(bid) {
            kind = .terminal
        } else if electronBundleIds.contains(bid) || bid.contains("electron") {
            kind = .electron
        } else if BrowserURL.browserBundleIds.contains(where: { $0.lowercased() == bid }) {
            kind = .browser
        } else {
            kind = .standard
        }
        return AppProfile(bundleId: bundleId, kind: kind)
    }

    // MARK: - Bundle-id tables (lowercased for case-insensitive match)

    /// Chromium/Electron apps confirmed to expose poor AX text. Cotypist
    /// special-cases the same family (Slack, Notion observed reading Chromium
    /// pasteboard flavors). A generic `"electron"` substring check in
    /// `profile(for:)` catches unlisted ones.
    static let electronBundleIds: Set<String> = [
        "com.tinyspeck.slackmacgap",   // Slack
        "notion.id",                   // Notion
        "com.microsoft.vscode",        // VS Code
        "com.microsoft.vscodeinsiders",
        "com.vscodium",                // VSCodium
        "com.figma.desktop",           // Figma
        "com.hnc.discord",             // Discord
        "com.spotify.client",          // Spotify
        "com.github.atom",             // Atom
        "md.obsidian",                 // Obsidian
        "com.postmanlabs.mac",         // Postman
        "com.linear",                  // Linear
        "com.todesktop.230313mzl4w4u92", // Cursor
    ]

    /// Terminal emulators -> terminal completion mode.
    static let terminalBundleIds: Set<String> = [
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.warp-stable",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "co.zeit.hyper",
        "org.tabby",
    ]

    /// Credential managers -> never complete. Apple's own secure-field detection
    /// already blocks password inputs, but these apps embed many such fields and
    /// it's safest to suppress wholesale.
    static let secureBundleIds: Set<String> = [
        "com.1password.1password",
        "com.1password.1password-launcher",
        "com.agilebits.onepassword",
        "com.agilebits.onepassword4",
        "com.apple.passwords",
        "com.lastpass.lastpassmacdesktop",
        "com.bitwarden.desktop",
        "in.sinew.enpass.mac",
        "com.dashlane.dashlanephoenix",
    ]

    /// Bundle id -> writing surface, for tone/length steering. Lowercased keys.
    /// Covers the common messaging/email/notes/code/docs apps; everything else
    /// falls back to the structural `Kind`.
    static let surfaceByBundleId: [String: Surface] = [
        // Chat / instant messaging
        "org.telegram.desktop": .chat,
        "ru.keepcoder.telegram": .chat,
        "com.tdesktop.telegram": .chat,
        "net.whatsapp.whatsapp": .chat,
        "desktop.whatsapp": .chat,
        "com.apple.mobilesms": .chat,          // Messages
        "com.apple.ichat": .chat,
        "com.tinyspeck.slackmacgap": .chat,    // Slack
        "com.hnc.discord": .chat,              // Discord
        "org.whispersystems.signal-desktop": .chat,
        "com.facebook.archon": .chat,          // Messenger
        "com.microsoft.teams2": .chat,
        "com.microsoft.teams": .chat,
        "us.zoom.xos": .chat,
        // Email
        "com.apple.mail": .email,
        "com.microsoft.outlook": .email,
        "com.readdle.smartemail-mac": .email,  // Spark
        "it.bloop.airmail2": .email,
        "io.canarymail.mac": .email,
        "com.superhuman.mail": .email,
        "com.google.gmail": .email,
        // Social
        "maccatalyst.com.atebits.tweetie2": .social, // X / Twitter
        "com.twitter.twitter-mac": .social,
        "org.mastodon": .social,
        // Notes
        "com.apple.notes": .notes,
        "md.obsidian": .notes,
        "net.shinyfrog.bear": .notes,
        "notion.id": .notes,
        "com.lukilabs.lukiapp": .notes,        // Craft
        "com.agiletortoise.drafts-osx": .notes,
        // Code / technical editors
        "com.apple.dt.xcode": .code,
        "com.microsoft.vscode": .code,
        "com.microsoft.vscodeinsiders": .code,
        "com.vscodium": .code,
        "com.todesktop.230313mzl4w4u92": .code, // Cursor
        "com.sublimetext.4": .code,
        "com.sublimetext.3": .code,
        "com.github.atom": .code,
        "com.jetbrains.intellij": .code,
        "com.jetbrains.pycharm": .code,
        "com.postmanlabs.mac": .code,
        // Documents
        "com.microsoft.word": .docs,
        "com.apple.iwork.pages": .docs,
        "com.apple.textedit": .docs,
        "com.google.docs": .docs,
    ]
}
