import XCTest
@testable import ProsperApp

/// Mixed-currency arithmetic ("$30 CAD + 5 USD - 7EUR"): parser and evaluator
/// run against a fixed rate table, so no network is involved.
final class CurrencyExpressionTests: XCTestCase {

    /// Units per 1 USD — fixed snapshot so results are deterministic.
    private let rates: [String: Double] = [
        "EUR": 0.9, "CAD": 1.35, "GBP": 0.8, "JPY": 150.0,
    ]

    private func parse(_ s: String) -> [CurrencyService.MoneyTerm]? {
        CurrencyService.parseExpression(s)
    }

    // MARK: - Parsing

    func testParsesMixedSpacingAndSymbols() throws {
        let terms = try XCTUnwrap(parse("$30 CAD + 5 USD - 7EUR"))
        XCTAssertEqual(terms, [
            .init(sign: 1, amount: 30, code: "CAD"),  // explicit code wins over '$'
            .init(sign: 1, amount: 5, code: "USD"),
            .init(sign: -1, amount: 7, code: "EUR"),  // attached code, no space
        ])
    }

    func testSymbolOnlyTermsMapToCodes() throws {
        let terms = try XCTUnwrap(parse("$30 + €5"))
        XCTAssertEqual(terms, [
            .init(sign: 1, amount: 30, code: "USD"),
            .init(sign: 1, amount: 5, code: "EUR"),
        ])
    }

    func testDigitSeparatorsAndUnicodeMinus() throws {
        let terms = try XCTUnwrap(parse("1,000 USD − 250 EUR"))
        XCTAssertEqual(terms, [
            .init(sign: 1, amount: 1000, code: "USD"),
            .init(sign: -1, amount: 250, code: "EUR"),
        ])
    }

    func testRejectsNonExpressions() {
        XCTAssertNil(parse("32 usd to eur"))   // single conversion, not arithmetic
        XCTAssertNil(parse("2+3*4"))           // plain calc, no currencies
        XCTAssertNil(parse("$30"))             // single term
        XCTAssertNil(parse("30 CAD + 5"))      // term without a currency
        XCTAssertNil(parse("30 CADX + 5 USD")) // 4-letter code
        XCTAssertNil(parse("hello + world"))
        XCTAssertNil(parse(""))
    }

    // MARK: - Evaluation

    func testResultIsInLastCurrency() throws {
        let terms = try XCTUnwrap(parse("30 CAD + 5 USD - 7EUR"))
        let c = try XCTUnwrap(CurrencyService.evaluateExpression(terms, rates: rates))
        // 30/1.35*0.9 + 5*0.9 - 7 = 20 + 4.5 - 7 = 17.5 EUR
        XCTAssertEqual(c.result, 17.5, accuracy: 1e-9)
        XCTAssertEqual(c.to, "EUR")
        XCTAssertEqual(c.formatted, "€ 17.50")
        XCTAssertEqual(c.detail, "30 CAD + 5 USD - 7 EUR → EUR")
    }

    func testUnknownCurrencyDeclines() throws {
        let terms = try XCTUnwrap(parse("30 XXX + 5 USD"))
        XCTAssertNil(CurrencyService.evaluateExpression(terms, rates: rates))
    }

    func testFormatMoneyFallsBackToCode() {
        XCTAssertEqual(CurrencyService.formatMoney(17.5, code: "SEK"), "17.50 SEK")
        XCTAssertEqual(CurrencyService.formatMoney(17.5, code: "JPY"), "¥ 17.50")
    }
}
