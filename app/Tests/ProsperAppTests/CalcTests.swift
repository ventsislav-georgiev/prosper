import XCTest
@testable import ProsperApp

final class CalcTests: XCTestCase {

    private func eval(_ s: String) -> Double? { Calc.evaluate(s) }

    func testBasicArithmetic() {
        XCTAssertEqual(eval("128*24"), 3072)
        XCTAssertEqual(eval("2+3*4"), 14)        // precedence
        XCTAssertEqual(eval("(2+3)*4"), 20)      // parentheses
        XCTAssertEqual(eval("10/4"), 2.5)
        XCTAssertEqual(eval("7%3"), 1)
        XCTAssertEqual(eval("2^10"), 1024)
    }

    func testUnaryAndAssociativity() {
        XCTAssertEqual(eval("-5+3"), -2)
        XCTAssertEqual(eval("3*-2"), -6)
        XCTAssertEqual(eval("2^3^2"), 512)       // right-associative: 2^(3^2)
    }

    func testSeparatorsAndUnicodeOps() {
        XCTAssertEqual(eval("1_000*2"), 2000)
        XCTAssertEqual(eval("1,000+1"), 1001)
        XCTAssertEqual(eval("6×7"), 42)
        XCTAssertEqual(eval("84÷2"), 42)
    }

    func testRejectsNonMath() {
        XCTAssertNil(eval("hello world"))       // no operator, words
        XCTAssertNil(eval("42"))                // bare number, no operator
        XCTAssertNil(eval("32 usd to eur"))     // currency
        XCTAssertNil(eval("(2+3"))              // unbalanced
        XCTAssertNil(eval("5/0"))               // div by zero → nil
        XCTAssertNil(eval(""))                  // empty
    }

    func testFormatting() {
        XCTAssertEqual(Calc.format(3072), "3072")
        XCTAssertEqual(Calc.format(2.5), "2.5")
        XCTAssertEqual(Calc.format(2.0), "2")
    }
}
