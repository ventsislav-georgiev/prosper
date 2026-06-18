import Foundation

/// Deterministic arithmetic evaluator for the command runner.
///
/// Hand-rolled tokenizer + shunting-yard → RPN → eval. Avoids `NSExpression`,
/// which raises uncatchable Objective-C exceptions on malformed input. Supports
/// `+ - * / % ^`, parentheses, unary minus, decimals, and `_`/`,` digit
/// separators. Pure and synchronous — safe to call on the main thread.
enum Calc {

    /// Evaluates an arithmetic expression. Returns nil if the string is not a
    /// well-formed math expression (caller then falls through to translate).
    static func evaluate(_ input: String) -> Double? {
        let tokens = tokenize(input)
        guard !tokens.isEmpty else { return nil }
        // Require at least one operator so plain numbers / words don't match.
        guard tokens.contains(where: { if case .op = $0 { return true } else { return false } }) else {
            return nil
        }
        guard let rpn = toRPN(tokens) else { return nil }
        return evalRPN(rpn)
    }

    /// Formats a result: integers without a fraction, else up to 8 significant
    /// decimals trimmed of trailing zeros.
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value == value.rounded() && abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        var s = String(format: "%.8f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    // MARK: - Tokenizer

    private enum Token: Equatable {
        case number(Double)
        case op(Character)
        case lparen
        case rparen
    }

    private static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }

            if c.isNumber || c == "." {
                var numStr = ""
                while i < chars.count, chars[i].isNumber || chars[i] == "." || chars[i] == "_" || chars[i] == "," {
                    let d = chars[i]
                    if d != "_" && d != "," { numStr.append(d) }
                    i += 1
                }
                guard let value = Double(numStr) else { return [] }
                tokens.append(.number(value))
                continue
            }

            switch c {
            case "+", "-", "*", "/", "%", "^", "×", "÷":
                let normalized: Character = (c == "×") ? "*" : (c == "÷") ? "/" : c
                tokens.append(.op(normalized))
            case "(", "[":
                tokens.append(.lparen)
            case ")", "]":
                tokens.append(.rparen)
            default:
                // Any other character → not a math expression.
                return []
            }
            i += 1
        }
        return tokens
    }

    // MARK: - Shunting yard

    private static func precedence(_ op: Character) -> Int {
        switch op {
        case "+", "-": return 2
        case "*", "/", "%": return 3
        case "^": return 4
        case "~": return 5 // unary negation — binds tighter than everything
        default: return 0
        }
    }

    private static func isRightAssociative(_ op: Character) -> Bool { op == "^" || op == "~" }

    private static func toRPN(_ tokens: [Token]) -> [Token]? {
        var output: [Token] = []
        var stack: [Token] = []
        var prev: Token? = nil

        for token in tokens {
            switch token {
            case .number:
                output.append(token)
            case .op(let o):
                // Unary minus/plus: an operator at the start or after another
                // operator or '(' → unary. Unary '+' is a no-op; unary '-' maps
                // to the high-precedence right-assoc negation operator '~'.
                let isUnary: Bool = {
                    switch prev {
                    case .none, .op, .lparen: return o == "-" || o == "+"
                    default: return false
                    }
                }()
                if isUnary {
                    if o == "+" { prev = token; continue } // drop unary plus
                    let neg: Token = .op("~")
                    // '~' is highest precedence + right-assoc → nothing to pop.
                    stack.append(neg)
                    prev = neg
                    continue
                }
                while case .op(let top)? = stack.last {
                    if (isRightAssociative(o) && precedence(o) < precedence(top)) ||
                       (!isRightAssociative(o) && precedence(o) <= precedence(top)) {
                        output.append(stack.removeLast())
                    } else { break }
                }
                stack.append(token)
            case .lparen:
                stack.append(token)
            case .rparen:
                var matched = false
                while let top = stack.last {
                    if top == .lparen { stack.removeLast(); matched = true; break }
                    output.append(stack.removeLast())
                }
                if !matched { return nil } // unbalanced
            }
            prev = token
        }

        while let top = stack.last {
            if top == .lparen { return nil } // unbalanced
            output.append(stack.removeLast())
        }
        return output
    }

    private static func evalRPN(_ rpn: [Token]) -> Double? {
        var stack: [Double] = []
        for token in rpn {
            switch token {
            case .number(let v):
                stack.append(v)
            case .op(let o):
                if o == "~" { // unary negation
                    guard let a = stack.popLast() else { return nil }
                    stack.append(-a)
                    continue
                }
                guard stack.count >= 2 else { return nil }
                let b = stack.removeLast()
                let a = stack.removeLast()
                let r: Double
                switch o {
                case "+": r = a + b
                case "-": r = a - b
                case "*": r = a * b
                case "/": guard b != 0 else { return nil }; r = a / b
                case "%": guard b != 0 else { return nil }; r = a.truncatingRemainder(dividingBy: b)
                case "^": r = pow(a, b)
                default: return nil
                }
                stack.append(r)
            default:
                return nil
            }
        }
        return stack.count == 1 ? stack.first : nil
    }
}
