import XCTest
@testable import ProsperApp

/// The block-markdown parser behind QuickChat's rich answers.
final class MarkdownBlocksTests: XCTestCase {

    func testHeadingsBulletsNumberedAndParagraphs() {
        let md = """
        ## Key Differences

        * Social Structure
        - Diet

        1. First
        2) Second

        Plain paragraph.
        """
        XCTAssertEqual(parseMarkdownBlocks(md), [
            .heading(level: 2, text: "Key Differences"),
            .bullet("Social Structure"),
            .bullet("Diet"),
            .numbered(number: "1", text: "First"),
            .numbered(number: "2", text: "Second"),
            .paragraph("Plain paragraph."),
        ])
    }

    func testCodeFencePreservesInnerMarkers() {
        let md = """
        ```
        # not a heading
        * not a bullet
        ```
        """
        XCTAssertEqual(parseMarkdownBlocks(md),
                       [.code("# not a heading\n* not a bullet")])
    }

    func testUnterminatedFenceStillFlushes() {
        XCTAssertEqual(parseMarkdownBlocks("```\nx = 1"), [.code("x = 1")])
    }

    func testHashWithoutSpaceIsParagraphNotHeading() {
        XCTAssertEqual(parseMarkdownBlocks("#hashtag"), [.paragraph("#hashtag")])
    }
}
