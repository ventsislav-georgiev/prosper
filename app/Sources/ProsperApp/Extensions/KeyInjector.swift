import AppKit
import Carbon

// Phase 4 §E — synthetic keystroke / media-key injection. Used by the §D remap
// engine (inject the remapped combo) and exposed to extensions as
// host.keys.stroke / host.keys.system. Every injected event carries the same
// `syntheticEventMagic` the shared tap skips, so injection never re-enters the tap
// (no remap loops, no autocomplete retrigger).
@MainActor
enum KeyInjector {

    /// Must equal `AutocompleteEngine.syntheticEventMagic` / `SnippetExpander`'s so
    /// the shared tap ignores what we post.
    static let syntheticEventMagic: Int64 = 0x50_52_4F_53 // 'PROS'

    /// Post a key combo (down then up) with the chord's modifier flags applied.
    static func stroke(_ chord: KeyChord) {
        let source = CGEventSource(stateID: .combinedSessionState)
        var flags: CGEventFlags = []
        if chord.cmd { flags.insert(.maskCommand) }
        if chord.alt { flags.insert(.maskAlternate) }
        if chord.ctrl { flags.insert(.maskControl) }
        if chord.shift { flags.insert(.maskShift) }
        let key = CGKeyCode(chord.keyCode)
        // Post the bare keycode — byte-identical to a real keypress. We deliberately do
        // NOT stamp an ASCII char onto ⌘/⌃ chords to "fix" menu matching under a
        // non-Latin layout: stamping a unicode string breaks the way Chromium/WebKit/Qt
        // apps (Slack/Safari/Telegram) resolve ⌘W, so they stop closing windows/tabs.
        // The keycode alone closes ⌘W in every one of those apps in both layouts. A
        // native app that genuinely needs char-based matching under a non-Latin layout
        // (e.g. Prosper's own windows) is handled on demand by that app, not here —
        // far better than breaking every app that already works.
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMagic)
            event.post(tap: .cgSessionEventTap)
        }
    }

    /// Post a system-defined (media) key by name: PLAY, NEXT, PREVIOUS, FAST, REWIND,
    /// SOUND_UP, SOUND_DOWN, MUTE, BRIGHTNESS_UP, BRIGHTNESS_DOWN, ILLUMINATION_UP,
    /// ILLUMINATION_DOWN. Unknown names are ignored. Mirrors Hammerspoon's
    /// `hs.eventtap.event.newSystemKeyEvent`.
    @discardableResult
    static func system(_ name: String) -> Bool {
        guard let code = MediaKey.code(forName: name) else { return false }
        for down in [true, false] {
            let data1 = (code << 16) | ((down ? 0xA : 0xB) << 8)
            guard let nsEvent = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: down ? NSEvent.ModifierFlags(rawValue: 0xA00) : NSEvent.ModifierFlags(rawValue: 0xB00),
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8, // NX_SUBTYPE_AUX_CONTROL_BUTTONS
                data1: data1,
                data2: -1
            ), let cgEvent = nsEvent.cgEvent else { continue }
            cgEvent.setIntegerValueField(.eventSourceUserData, value: syntheticEventMagic)
            cgEvent.post(tap: .cgSessionEventTap)
        }
        return true
    }

}

/// NX_KEYTYPE_* aux-control (media) key names ↔ codes (IOKit/hidsystem/ev_keymap.h).
/// Shared by KeyInjector (post a media key) and the key-rule engine (decode an
/// INCOMING media key off the systemDefined tap, then match it against rules).
enum MediaKey {
    static let nameToCode: [String: Int] = [
        "SOUND_UP": 0, "SOUND_DOWN": 1, "BRIGHTNESS_UP": 2, "BRIGHTNESS_DOWN": 3,
        "MUTE": 7, "PLAY": 16, "NEXT": 17, "PREVIOUS": 18, "FAST": 19, "REWIND": 20,
        "ILLUMINATION_UP": 21, "ILLUMINATION_DOWN": 22,
    ]
    static let codeToName: [Int: String] = Dictionary(
        uniqueKeysWithValues: nameToCode.map { ($1, $0) })

    static func code(forName name: String) -> Int? { nameToCode[name.uppercased()] }
    static func name(forCode code: Int) -> String? { codeToName[code] }
}
