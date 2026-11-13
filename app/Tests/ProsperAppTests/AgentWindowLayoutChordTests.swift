import AppKit
import XCTest
@testable import ProsperApp

/// #882: the Agent Sessions window's chords on Latin, non-Latin and Dvorak keyboard layouts. Every event is
/// built with NSEvent.keyEvent and handed to the pure `route` (or a never-shown window); nothing is posted and
/// the input source is never read or changed. The characters are the ones UCKeyTranslate gives for the
/// installed Russian, Bulgarian (Phonetic), Greek and Dvorak layouts: `characters` under Command,
/// `charactersIgnoringModifiers` without it.
final class AgentWindowLayoutChordTests: XCTestCase {
    typealias R = AgentsNSWindow.KeyRoute

    @MainActor
    func ev(_ code: UInt16, _ chars: String, _ ignoring: String, _ flags: NSEvent.ModifierFlags,
            repeat isRepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: ignoring,
                         isARepeat: isRepeat, keyCode: code)!
    }

    @MainActor
    func route(_ e: NSEvent, _ r: AgentsNSWindow.ResponderKind = .terminal, terminal: Bool = true,
               renaming: Bool = false) -> R {
        AgentsNSWindow.route(e, responder: r, sidebarFocused: false, terminalMode: terminal, renaming: renaming)
    }

    /// Letter, ANSI key code, Russian, Bulgarian Phonetic, Greek letter on that key, Dvorak's key code for the
    /// letter, what Dvorak types on the ANSI key, and the route in Terminal mode.
    static var chords: [(String, UInt16, String, String, String, UInt16, String, R)] { [
        ("w", 13, "ц", "в", "ς", 43, ",", .close),
        ("t", 17, "е", "т", "τ", 40, "y", .toggleMode),
        ("f", 3, "а", "ф", "φ", 16, "u", .find),
        ("g", 5, "п", "г", "γ", 32, "i", .findNext(true)),
        ("n", 45, "т", "н", "ν", 37, "b", .newSession),
    ] }

    @MainActor
    func testAgentWindowChordsFireOnLatinCyrillicGreekAndDvorakLayouts() {
        for (l, code, ru, bg, el, dvCode, dvAtAnsi, want) in Self.chords {
            for r: AgentsNSWindow.ResponderKind in [.text, .terminal, .other] {
                XCTAssertEqual(route(ev(code, l, l, .command), r), want, "Latin ⌘\(l)")
                XCTAssertEqual(route(ev(code, l, ru, .command), r), want, "Russian ⌘\(l): characters \(l), ignoring \(ru)")
                XCTAssertEqual(route(ev(code, l, bg, .command), r), want, "Bulgarian Phonetic ⌘\(l)")
                XCTAssertEqual(route(ev(code, l, el, .command), r), want, "Greek ⌘\(l)")
                XCTAssertEqual(route(ev(dvCode, l, l, .command), r), want, "Dvorak ⌘\(l): its own key, the letter rules")
                XCTAssertEqual(route(ev(code, dvAtAnsi, dvAtAnsi, .command), r), .pass,
                               "Dvorak: the ANSI \(l) key types \(dvAtAnsi), so no chord (the key position is not the rule)")
            }
        }
        // Transcript mode: ⌘F and ⌘G stay the transcript's on every layout, as on Latin.
        XCTAssertEqual(route(ev(3, "f", "а", .command), terminal: false), .pass)
        XCTAssertEqual(route(ev(5, "g", "п", .command), terminal: false), .pass)
        XCTAssertEqual(route(ev(17, "t", "е", .command), terminal: false), .toggleMode)
        // #829 G4: renaming, ⌘W still closes on Cyrillic and every other chord stands down.
        XCTAssertEqual(route(ev(13, "w", "ц", .command), .text, renaming: true), .close)
        XCTAssertEqual(route(ev(45, "n", "т", .command), .text, renaming: true), .pass)
    }

    @MainActor
    func testAgentWindowChordsIgnoreCapsLockAndKeepShiftApart() {
        let caps: NSEvent.ModifierFlags = [.command, .capsLock]
        XCTAssertEqual(route(ev(45, "N", "N", caps)), .newSession, "Latin, Caps Lock on")
        XCTAssertEqual(route(ev(45, "N", "Ν", caps)), .newSession, "Greek, Caps Lock on: Command gives N")
        XCTAssertEqual(route(ev(13, "W", "Σ", caps)), .close, "Greek ⌘W, Caps Lock on")
        XCTAssertEqual(route(ev(45, "n", "т", .command)), .newSession, "Russian ⌘N")
        XCTAssertEqual(route(ev(45, "N", "N", [.command, .shift])), .newShell, "Latin ⇧⌘N")
        XCTAssertEqual(route(ev(45, "N", "Т", [.command, .shift])), .newShell, "Russian ⇧⌘N")
        XCTAssertEqual(route(ev(45, "N", "Ν", [.command, .shift])), .newShell, "Greek ⇧⌘N")
        XCTAssertEqual(route(ev(5, "G", "П", [.command, .shift])), .findNext(false), "Russian ⇧⌘G")
        XCTAssertEqual(route(ev(3, "F", "А", [.command, .shift])), .pass, "⇧⌘F is no chord on any layout")
    }

    @MainActor
    func testAgentWindowHeldNewSessionChordIsSwallowedOnACyrillicLayout() {
        XCTAssertEqual(route(ev(45, "n", "т", .command, repeat: true)), .swallow, "#847 R2 F1 on Russian")
        XCTAssertEqual(route(ev(45, "N", "Т", [.command, .shift], repeat: true)), .swallow)
        XCTAssertEqual(route(ev(45, "n", "ν", .command, repeat: true), .text), .swallow, "Greek, the form's field")
        XCTAssertEqual(route(ev(45, "n", "т", .command)), .newSession, "the first press still opens")
    }

    /// No layout installed on macOS 27 has one; built anyway so the rule is pinned.
    @MainActor
    func testAgentWindowCommandCharacterWinsWhenBothAreChordLetters() {
        XCTAssertEqual(route(ev(17, "t", "n", .command)), .toggleMode)
        XCTAssertEqual(route(ev(45, "n", "w", .command)), .newSession, "not ⌘W's close")
        XCTAssertEqual(route(ev(13, "w", "n", .command)), .close)
        XCTAssertEqual(route(ev(5, "g", "f", .command)), .findNext(true))
    }

    /// The Command-modified character is an Option or Control glyph: charactersIgnoringModifiers decides, as before.
    @MainActor
    func testAgentWindowLetterWithoutCommandCharacterStillMatches() {
        XCTAssertEqual(route(ev(13, "∑", "w", [.command, .option])), .close, "US ⌥⌘W")
        XCTAssertEqual(route(ev(13, "\u{17}", "w", [.command, .control])), .close, "US ⌃⌘W")
        XCTAssertEqual(route(ev(43, "", "w", .command)), .close, "no characters at all")
        XCTAssertEqual(route(ev(45, "", "n", .command)), .newSession)
    }

    /// Text field, terminal, anything else: a key without Command is the first responder's, as on the base,
    /// even when its character is a chord letter (Bulgarian Phonetic's ⌥W types "w").
    @MainActor
    func testAgentWindowTypedKeysPassThroughOnANonLatinLayout() {
        let typed: [(UInt16, String, String, NSEvent.ModifierFlags)] = [
            (45, "т", "т", []), (45, "Т", "Т", .shift), (45, "™", "т", .option), (13, "w", "в", .option),
            (45, "\u{0E}", "т", .control), (13, "\u{17}", "ц", .control), (45, "n", "n", []), (13, "\u{17}", "w", .control),
            (45, "Т", "т", .capsLock), (45, "ν", "ν", []),
        ]
        for (code, chars, ignoring, flags) in typed {
            for r: AgentsNSWindow.ResponderKind in [.text, .terminal, .other] {
                for terminal in [true, false] {
                    XCTAssertEqual(route(ev(code, chars, ignoring, flags), r, terminal: terminal), .pass,
                                   "\(chars) / \(ignoring) with \(flags.rawValue) into \(r)")
                }
            }
        }
    }

    /// #887 (QA #754 INFO-1): "Dvorak - QWERTY ⌘" types Dvorak but gives the QWERTY character under Command (the
    /// installed layout's UCKeyTranslate values). With Command and no Option a printable ASCII `characters` decides,
    /// so each chord fires from its QWERTY key only: the Dvorak-letter key's ⌘, ⌘K, ⌘Y, ⌘U, ⌘L are no chord.
    @MainActor
    func testAgentWindowDvorakQwertyCommandFiresEachChordFromOneKey() {
        // Letter, QWERTY key, what Dvorak types there, the Dvorak-letter key, what Command gives there, the route.
        let rows: [(String, UInt16, String, UInt16, String, R)] = [
            ("w", 13, ",", 43, ",", .close), ("t", 17, "y", 40, "k", .toggleMode), ("f", 3, "u", 16, "y", .find),
            ("g", 5, "i", 32, "u", .findNext(true)), ("n", 45, "b", 37, "l", .newSession),
        ]
        for (l, qwerty, typed, dvorak, cmd, want) in rows {
            for r: AgentsNSWindow.ResponderKind in [.text, .terminal, .other] {
                XCTAssertEqual(route(ev(qwerty, l, typed, .command), r), want, "⌘ on the QWERTY \(l) key")
                XCTAssertEqual(route(ev(dvorak, cmd, l, .command), r), .pass, "⌘\(cmd) on the Dvorak \(l) key is no chord")
            }
        }
        XCTAssertEqual(route(ev(45, "n", "B", [.command, .shift])), .newShell, "⇧⌘ on the QWERTY N key")
        XCTAssertEqual(route(ev(37, "l", "N", [.command, .shift])), .pass, "⇧⌘ on the Dvorak N key")
        XCTAssertEqual(route(ev(5, "g", "I", [.command, .shift])), .findNext(false))
        XCTAssertEqual(route(ev(32, "u", "G", [.command, .shift])), .pass)
        XCTAssertEqual(route(ev(43, "<", "W", [.command, .shift])), .pass, "⇧⌘ on the Dvorak W key")
        // Option held: the #882 rule stays. Finnish/Norwegian Extended and the Sami layouts type an ASCII "," with ⌥⌘
        // on the W key, which must still close; the same fields on this layout's Dvorak W key close too (not separable).
        XCTAssertEqual(route(ev(13, ",", "w", [.command, .option])), .close, "Finnish Extended ⌥⌘W")
        XCTAssertEqual(route(ev(43, ",", "w", [.command, .option])), .close, "Dvorak - QWERTY ⌘'s ⌥⌘ on its W key")
        XCTAssertEqual(route(ev(13, "w", ",", [.command, .option])), .close, "its ⌥⌘ on the QWERTY W key")
        XCTAssertEqual(route(ev(45, "n", "b", [.command, .option])), .pass, "⌥⌘N is no chord")
        // The modelless window: ⌘, is not its ⌘W.
        let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .closable],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        XCTAssertFalse(win.performKeyEquivalent(with: ev(43, ",", "w", .command)), "⌘, passes on")
        XCTAssertFalse(win.isVisible, "never shown")
    }

    /// The modelless window's own ⌘W (performKeyEquivalent): closes on a Cyrillic layout. Never shown.
    @MainActor
    func testAgentWindowWithoutModelClosesOnCyrillicCommandW() {
        let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .closable],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        XCTAssertFalse(win.performKeyEquivalent(with: ev(45, "n", "т", .command)), "⌘N is not this window's without a model")
        XCTAssertTrue(win.performKeyEquivalent(with: ev(13, "w", "ц", .command)))
        XCTAssertFalse(win.isVisible, "never shown")
    }
}
