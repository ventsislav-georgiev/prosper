import Foundation

/// Deterministic currency conversion. Fetches today's FX rates **once** (the one
/// allowed network call besides the model download), caches them in memory and
/// `UserDefaults` keyed by day, and converts via USD cross-rates. Subsequent
/// conversions the same day hit the cache — no further network.
actor CurrencyService {
    static let shared = CurrencyService()

    // Base currency for the rate table.
    private let base = "USD"
    // Free, key-less endpoint. Returns { result, rates: {CODE: Double}, time_last_update_unix }.
    private let endpoint = "https://open.er-api.com/v6/latest/USD"

    private struct Snapshot {
        let rates: [String: Double] // CODE -> units per 1 USD
        let day: String             // yyyy-MM-dd (UTC) the rates were cached for
    }

    private var cached: Snapshot?

    private enum Keys {
        static let rates = "fxRates"
        static let day = "fxRatesDay"
        /// Wall-clock time the rate table was last fetched from the network. Read
        /// by the UI to render Raycast's "Updated N ago" subtitle on the card.
        static let fetchedAt = "fxRatesFetchedAt"
    }

    struct Conversion {
        let amount: Double
        let from: String
        let to: String
        let result: Double
        /// e.g. "29.44 EUR".
        let formatted: String
        /// e.g. "32 USD → EUR (rate 0.9200)".
        let detail: String
    }

    /// Parses `"<n> <CUR> to <CUR>"` and converts. Returns nil if not a currency
    /// query or the currencies are unknown. Mixed-currency arithmetic
    /// (`"$30 CAD + 5 USD - 7EUR"`) is tried first; the result is expressed in
    /// the LAST term's currency (Numi parity).
    func convert(_ input: String) async -> Conversion? {
        if let terms = Self.parseExpression(input) {
            guard let rates = await ratesForToday() else { return nil }
            return Self.evaluateExpression(terms, rates: rates)
        }
        guard let q = Self.parse(input) else { return nil }
        guard let rates = await ratesForToday() else { return nil }

        // Cross-rate via USD base. base==USD ⇒ rates[USD] is implicitly 1.
        func rate(_ code: String) -> Double? {
            if code == base { return 1.0 }
            return rates[code]
        }
        guard let rFrom = rate(q.from), let rTo = rate(q.to), rFrom > 0 else { return nil }

        let usd = q.amount / rFrom          // to USD
        let result = usd * rTo              // to target
        let crossRate = rTo / rFrom
        return Conversion(
            amount: q.amount,
            from: q.from,
            to: q.to,
            result: result,
            formatted: "\(Calc.format(result)) \(q.to)",
            detail: "\(Calc.format(q.amount)) \(q.from) → \(q.to) (rate \(String(format: "%.4f", crossRate)))"
        )
    }

    // MARK: - Rate cache

    private func ratesForToday() async -> [String: Double]? {
        let today = Self.utcDayString()

        if let cached, cached.day == today { return cached.rates }

        // Try persisted cache.
        let defaults = UserDefaults.standard
        if let storedDay = defaults.string(forKey: Keys.day), storedDay == today,
           let storedRates = defaults.dictionary(forKey: Keys.rates) as? [String: Double], !storedRates.isEmpty {
            cached = Snapshot(rates: storedRates, day: today)
            return storedRates
        }

        // Fetch.
        guard let rates = await fetch() else {
            // Fall back to any stale cache so the feature degrades, not breaks.
            if let stale = defaults.dictionary(forKey: Keys.rates) as? [String: Double], !stale.isEmpty {
                return stale
            }
            return nil
        }
        cached = Snapshot(rates: rates, day: today)
        defaults.set(rates, forKey: Keys.rates)
        defaults.set(today, forKey: Keys.day)
        defaults.set(Date(), forKey: Keys.fetchedAt)
        return rates
    }

    private struct APIResponse: Decodable {
        let result: String
        let rates: [String: Double]
    }

    private func fetch() async -> [String: Double]? {
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let decoded = try JSONDecoder().decode(APIResponse.self, from: data)
            guard decoded.result == "success", !decoded.rates.isEmpty else { return nil }
            return decoded.rates
        } catch {
            NSLog("prosper: FX fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Mixed-currency expressions

    /// One signed money term in a mixed-currency expression, e.g. the `- 7 EUR`
    /// of `"$30 CAD + 5 USD - 7EUR"`.
    struct MoneyTerm: Equatable {
        let sign: Double
        let amount: Double
        let code: String
    }

    /// Currency symbols accepted as a term's currency when no 3-letter code
    /// follows the amount (`"$30 + 5 EUR"`). An explicit code always wins over
    /// the symbol (`"$30 CAD"` → CAD).
    private static let symbolCodes: [Character: String] = [
        "$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY", "₹": "INR",
    ]

    /// Display symbols for formatting an expression result (`"€ 18.56"`). Kept
    /// byte-identical to the map in the currency system extension's init.lua.
    private static let displaySymbols: [String: String] = [
        "USD": "$", "EUR": "€", "GBP": "£", "JPY": "¥", "INR": "₹",
    ]

    /// Money formatting for expression results: two decimals, the currency's
    /// symbol when known (`"€ 18.56"`), else the code (`"18.56 SEK"`).
    nonisolated static func formatMoney(_ value: Double, code: String) -> String {
        let s = String(format: "%.2f", value)
        if let sym = displaySymbols[code] { return "\(sym) \(s)" }
        return "\(s) \(code)"
    }

    /// Parses a mixed-currency arithmetic expression: two or more money terms
    /// joined by `+`/`-`. A term is an optional currency symbol, a number
    /// (`,`/`_` digit separators allowed), and an optional 3-letter code, in
    /// any spacing (`"$30 CAD"`, `"5 USD"`, `"7EUR"`). Every term must carry a
    /// currency (symbol or code). Returns nil when the input is not exactly
    /// this shape, so plain calc/single-conversion queries fall through.
    nonisolated static func parseExpression(_ input: String) -> [MoneyTerm]? {
        let normalized = input
            .replacingOccurrences(of: "−", with: "-") // unicode minus
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = Array(normalized)
        var i = 0
        var terms: [MoneyTerm] = []
        func skipSpace() { while i < chars.count, chars[i].isWhitespace { i += 1 } }

        while i < chars.count {
            var sign = 1.0
            if !terms.isEmpty {
                guard chars[i] == "+" || chars[i] == "-" else { return nil }
                sign = chars[i] == "-" ? -1 : 1
                i += 1
                skipSpace()
            }
            // Optional leading symbol ("$30").
            var symCode: String?
            if i < chars.count, let mapped = Self.symbolCodes[chars[i]] {
                symCode = mapped
                i += 1
                skipSpace()
            }
            // Number; ','/'_' are digit separators (same as Calc).
            var numStr = ""
            while i < chars.count,
                  chars[i].isNumber || chars[i] == "." || chars[i] == "," || chars[i] == "_" {
                let c = chars[i]
                if c != "," && c != "_" { numStr.append(c) }
                i += 1
            }
            guard let amount = Double(numStr) else { return nil }
            skipSpace()
            // Optional 3-letter code, attached or spaced ("7EUR", "5 USD").
            var code = ""
            while i < chars.count, chars[i].isLetter, code.count < 4 {
                code.append(chars[i])
                i += 1
            }
            if code.count == 3 {
                // explicit code wins over a symbol
            } else if code.isEmpty, let symCode {
                code = symCode
            } else {
                return nil
            }
            terms.append(MoneyTerm(sign: sign, amount: amount, code: code.uppercased()))
            skipSpace()
        }
        // A single term is not an expression (and would shadow "<n> CUR to CUR").
        guard terms.count >= 2 else { return nil }
        return terms
    }

    /// Evaluates parsed terms against a USD-based rate table. The result is in
    /// the LAST term's currency. Returns nil when any code is unknown.
    nonisolated static func evaluateExpression(
        _ terms: [MoneyTerm], rates: [String: Double]
    ) -> Conversion? {
        func rate(_ code: String) -> Double? { code == "USD" ? 1.0 : rates[code] }
        guard let last = terms.last, let first = terms.first,
              let rTarget = rate(last.code), rTarget > 0 else { return nil }
        var total = 0.0
        for t in terms {
            guard let r = rate(t.code), r > 0 else { return nil }
            total += t.sign * (t.amount / r) * rTarget
        }
        let detail = terms.enumerated().map { i, t -> String in
            let amt = "\(Calc.format(t.amount)) \(t.code)"
            if i == 0 { return t.sign < 0 ? "-\(amt)" : amt }
            return "\(t.sign < 0 ? "-" : "+") \(amt)"
        }.joined(separator: " ") + " → \(last.code)"
        return Conversion(
            amount: last.amount,
            from: first.code,
            to: last.code,
            result: total,
            formatted: Self.formatMoney(total, code: last.code),
            detail: detail
        )
    }

    // MARK: - Parsing / helpers

    /// Known set of 3-letter codes is validated against the live rate table, so
    /// here we only require the `<n> <CUR> to <CUR>` shape with 3-letter codes.
    private struct Query { let amount: Double; let from: String; let to: String }

    nonisolated private static func parse(_ input: String) -> Query? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let separators = [" to ", " in ", "->", " → "]
        var lhs = "", rhs = ""
        var found = false
        for sep in separators {
            if let range = trimmed.range(of: sep, options: .caseInsensitive) {
                lhs = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                rhs = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                found = true
                break
            }
        }
        guard found else { return nil }

        // LHS: "<number> <CUR>" or "<CUR> <number>" or symbol-prefixed.
        var numStr = ""
        var rest = ""
        var seenDigit = false
        for c in lhs {
            if c.isNumber || c == "." || c == "," || c == "_" {
                if c != "," && c != "_" { numStr.append(c) }
                seenDigit = true
            } else if !c.isWhitespace {
                // symbol or currency letters
                if seenDigit { rest.append(c) } else if c.isLetter { rest.append(c) }
            } else if seenDigit && !rest.isEmpty {
                break
            }
        }
        guard let amount = Double(numStr) else { return nil }
        let from = rest.uppercased()
        let to = rhs.uppercased()
        guard from.count == 3, to.count == 3,
              from.allSatisfy({ $0.isLetter }), to.allSatisfy({ $0.isLetter }) else { return nil }
        return Query(amount: amount, from: from, to: to)
    }

    nonisolated private static func utcDayString() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
