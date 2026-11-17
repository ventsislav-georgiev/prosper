import XCTest
@testable import ProsperApp

/// #1245 (N1235-b, R1235-1): the consent sheet's title quotes the owner's display name after a fixed word, so a name equal
/// to Prosper, macOS or another extension never reads as that product asking; one id is one owner whatever its name; a
/// name made only of combining marks keeps at most three, on the opening quote. Hand-built change sets with fake ids:
/// nothing is read or written, no view is hosted.
@MainActor
final class ManagedConfigConsentOwnerNameTests: XCTestCase {
    private static let owner = "com.example.kit"

    private func model(_ name: String) -> ManagedConfigConsentModel {
        ManagedConfigConsentModel(changes: ManagedConfigChangeSet(action: .apply, owner: Self.owner, displayName: name, files: [], pieces: [])) { _ in }
    }

    private static func scalars(_ s: String?) -> [UInt32] { (s ?? "").unicodeScalars.map(\.value) }

    func testANameEqualToAProductShowsQuotedAfterTheWord() {
        for name in ["Prosper", "macOS", "Other Kit"] {
            let m = model(name)
            XCTAssertEqual(m.title, "Extension \"\(name)\"", name)
            XCTAssertEqual(m.idLine, Self.owner, "\(name): the id under it")
            XCTAssertEqual(m.renderedStrings.first, m.title, name)
            XCTAssertFalse(m.renderedStrings.contains(name), "\(name): never drawn bare")
        }
    }

    func testTwoOwnersWithOneIdAndDifferentNamesAreOneOwner() {
        let a = ManagedConfigOwner(id: Self.owner, version: "1.0.0", kitSlug: "example-kit", displayName: "Fake Kit")
        var b = a
        b.displayName = "Prosper"
        XCTAssertTrue(a == b, "a name never splits one owner")
        b.displayName = nil
        XCTAssertTrue(a == b, "nor a missing one")
        XCTAssertEqual([a].firstIndex(of: b), 0, "a lookup finds it")
        var other = a
        other.id = "com.example.other"
        XCTAssertFalse(a == other, "another id is another owner")
    }

    /// OutsideText.shown keeps the first three marks (capMarks counts from the start, no base needed) and drops the
    /// rest: the three ride on the opening quote, one character of at most four scalars, and the id line stays.
    func testANameOfCombiningMarksOnlyKeepsThreeOnTheOpeningQuote() {
        let m = model(String(repeating: "\u{0301}", count: 10))
        XCTAssertEqual(Self.scalars(m.displayName), Self.scalars("\u{0301}\u{0301}\u{0301}"))
        XCTAssertEqual(Self.scalars(m.title), Self.scalars("Extension \"\u{0301}\u{0301}\u{0301}\""))
        XCTAssertTrue(m.title.allSatisfy { $0.unicodeScalars.count <= 4 }, "\(Self.scalars(m.title))")
        XCTAssertEqual(m.idLine, Self.owner)
    }

    /// #1437 (R1245-s1): a quote mark inside the name never closes the quoting: the title keeps exactly the two quotes it draws.
    func testAQuoteInsideTheNameCannotCloseTheQuoting() {
        let m = model("Fake Kit\" from Prosper. \"OK")
        XCTAssertEqual(m.title, "Extension \"Fake Kit' from Prosper. 'OK\"")
        XCTAssertEqual(m.title.unicodeScalars.filter { $0.value == 0x22 }.count, 2)
        XCTAssertEqual(m.displayName, "Fake Kit\" from Prosper. \"OK", "the name itself is unchanged")
        XCTAssertEqual(m.idLine, Self.owner)
    }

    func testEachOfTheTwelveQuoteMarksShowsAsAnApostrophe() {
        let literal: [UInt32] = [0x22, 0x201C, 0x201D, 0x201E, 0x201F, 0xAB, 0xBB, 0x2033, 0xFF02, 0x301D, 0x301E, 0x301F]
        XCTAssertEqual(Set(literal), Set(ManagedConfigConsentModel.quoteMarks.map(\.value)), "the list is the set the code maps")
        for v in literal {
            guard let u = Unicode.Scalar(v) else { return XCTFail("\(v)") }
            let m = model("A\(u)B")
            XCTAssertEqual(Self.scalars(m.title), Self.scalars("Extension \"A'B\""), "U+\(String(v, radix: 16))")
        }
    }

    func testAQuoteCarryingAMarkStillShowsAsAnApostrophe() {
        let m = model("A\u{22}\u{0301}B")
        XCTAssertEqual(m.title.unicodeScalars.filter { $0.value == 0x22 }.count, 2)
    }

    func testANameOfOnlyQuoteMarksStaysAnApostropheName() {
        let m = model("\u{22}\u{201D}")
        XCTAssertEqual(m.title, "Extension \"''\"")
        XCTAssertEqual(m.idLine, Self.owner)
    }
}
