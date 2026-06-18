import Foundation

/// A tool call extracted from a model's decoded text, in OpenAI shape.
struct ParsedToolCall: Equatable, Sendable {
    let id: String
    let name: String
    /// The `arguments` object as a JSON **string** (OpenAI puts arguments as a
    /// stringified JSON object on the wire).
    let argumentsJSON: String
}

/// Result of scanning a model turn: the user-visible text with tool-call syntax
/// stripped, plus any tool calls found.
struct ToolCallParseResult: Equatable, Sendable {
    let content: String
    let toolCalls: [ParsedToolCall]
    var hasToolCalls: Bool { !toolCalls.isEmpty }
}

/// Converts between a model family's **native** tool-call syntax (as it appears in
/// the decoded token stream) and OpenAI `tool_calls`. mlx-swift-lm has no
/// grammar-constrained decoding, so this is where tool-call reliability lives:
///
///   • `parse()` — pull tool calls out of a completed assistant turn.
///   • `serializeAssistant()` — re-embed prior tool calls into assistant content
///     when replaying history, so the chat template reproduces what the model
///     originally emitted (round-trip fidelity for multi-turn agent loops).
///
/// Format coverage: `.qwenXML` / `.hermesJSON` (`<tool_call>` blocks whose body is
/// either `{json}` (Qwen3/Hermes) or the xml_function `<function=…>` form
/// Qwen3-Coder emits — both supported), `.mistral` (`[TOOL_CALLS]` array),
/// `.harmony` (gpt-oss channels, best-effort), `.nemotron` (`<toolcall>{json}`,
/// `<think>` stripped), `.glm` (`<tool_call>NAME<arg_key>…<arg_value>…`),
/// `.kimi` (`<|tool_call_begin|>functions.NAME:idx<|tool_call_argument_begin|>…`),
/// `.minimax` (`<invoke name="fn"><parameter name="p">…`).
enum ToolCallParser {

    // MARK: Parse

    static func parse(_ text: String, format: ToolCallFormat) -> ToolCallParseResult {
        switch format {
        case .qwenXML, .hermesJSON:
            let tagged = parseTagged(text, open: "<tool_call>", close: "</tool_call>")
            // Qwen3-Coder routinely omits the opening `<tool_call>` tag — the turn
            // starts directly with `<function=…>` and ends with a stray
            // `</tool_call>`. Mirror the reference parser's back-off
            // (qwen3coder_tool_parser.py: no tagged blocks → extract bare
            // `<function=…></function>` blocks from the whole output).
            // Require call-structure evidence beyond the bare opener so prose that
            // merely MENTIONS `<function=` is not eaten as a tool call.
            if tagged.toolCalls.isEmpty, text.contains("<function="),
               text.contains("</function>") || text.contains("<parameter=") {
                return parseBareXMLFunctions(text)
            }
            return tagged
        case .mistral: return parseMistral(text)
        case .harmony: return parseHarmony(text)
        case .nemotron: return parseNemotron(text)
        case .glm: return parseGLM(text)
        case .kimi: return parseKimi(text)
        case .minimax: return parseMiniMax(text)
        }
    }

    // MARK: Serialize (history replay)

    static func serializeAssistant(
        content: String, toolCalls: [ParsedToolCall], format: ToolCallFormat
    ) -> String {
        guard !toolCalls.isEmpty else { return content }
        switch format {
        case .qwenXML, .hermesJSON:
            let blocks = toolCalls.map { tc in
                "<tool_call>\n{\"name\": \(jsonString(tc.name)), \"arguments\": \(normalizedArgs(tc.argumentsJSON))}\n</tool_call>"
            }.joined(separator: "\n")
            return content.isEmpty ? blocks : content + "\n" + blocks
        case .mistral:
            let arr = toolCalls.map { tc in
                "{\"name\": \(jsonString(tc.name)), \"arguments\": \(normalizedArgs(tc.argumentsJSON))}"
            }.joined(separator: ", ")
            return content + "[TOOL_CALLS][\(arr)]"
        case .harmony:
            // Replay as a commentary channel call per tool.
            let calls = toolCalls.map { tc in
                "<|channel|>commentary to=functions.\(tc.name) <|constrain|>json<|message|>\(normalizedArgs(tc.argumentsJSON))<|call|>"
            }.joined()
            return content.isEmpty ? calls : "<|channel|>final<|message|>\(content)<|end|>\(calls)"
        case .nemotron:
            let blocks = toolCalls.map { tc in
                "<toolcall>{\"name\": \(jsonString(tc.name)), \"arguments\": \(normalizedArgs(tc.argumentsJSON))}</toolcall>"
            }.joined(separator: "\n")
            return content.isEmpty ? blocks : content + "\n" + blocks
        case .glm:
            let blocks = toolCalls.map { tc in
                "<tool_call>\(tc.name)\n\(glmArgPairs(tc.argumentsJSON))</tool_call>"
            }.joined(separator: "\n")
            return content.isEmpty ? blocks : content + "\n" + blocks
        case .kimi:
            var body = "<|tool_calls_section_begin|>"
            for (i, tc) in toolCalls.enumerated() {
                body += "<|tool_call_begin|>functions.\(tc.name):\(i)<|tool_call_argument_begin|>\(normalizedArgs(tc.argumentsJSON))<|tool_call_end|>"
            }
            body += "<|tool_calls_section_end|>"
            return content.isEmpty ? body : content + "\n" + body
        case .minimax:
            let invokes = toolCalls.map { tc in
                "<invoke name=\"\(tc.name)\">\(minimaxParams(tc.argumentsJSON))</invoke>"
            }.joined()
            let section = "<minimax:tool_call>\(invokes)</minimax:tool_call>"
            return content.isEmpty ? section : content + "\n" + section
        }
    }

    // MARK: - Tagged JSON blocks (Qwen / Hermes)

    /// Scans for `open … close` blocks holding `{"name":…, "arguments":{…}}`.
    /// Robust to: surrounding prose, multiple blocks, missing closing tag at the
    /// end of a truncated stream, and `arguments` being an object or a string.
    private static func parseTagged(_ text: String, open: String, close: String) -> ToolCallParseResult {
        var calls: [ParsedToolCall] = []
        var content = ""
        var idx = text.startIndex
        var n = 0
        while let openR = text.range(of: open, range: idx..<text.endIndex) {
            content += text[idx..<openR.lowerBound]
            let bodyStart = openR.upperBound
            let bodyEnd: String.Index
            let nextIdx: String.Index
            if let closeR = text.range(of: close, range: bodyStart..<text.endIndex) {
                bodyEnd = closeR.lowerBound
                nextIdx = closeR.upperBound
            } else {
                // Unterminated (truncated stream): take the rest.
                bodyEnd = text.endIndex
                nextIdx = text.endIndex
            }
            let body = text[bodyStart..<bodyEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            // Qwen3 emits a `{json}` body; Qwen3-Coder emits the xml_function body
            // `<function=name><parameter=key>value</parameter></function>`. Try both.
            if let call = callFromNameArgsJSON(body, index: n)
                ?? callFromXMLFunction(body, index: n)
            {
                calls.append(call); n += 1
            }
            idx = nextIdx
        }
        content += text[idx..<text.endIndex]
        return ToolCallParseResult(
            content: content.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: calls
        )
    }

    /// Back-off for Qwen3-Coder turns that skip the opening `<tool_call>` tag:
    /// extract `<function=…></function>` blocks (last one may be unterminated on a
    /// truncated stream) and drop stray `<tool_call>`/`</tool_call>` tags from the
    /// surrounding content.
    private static func parseBareXMLFunctions(_ text: String) -> ToolCallParseResult {
        var calls: [ParsedToolCall] = []
        var content = ""
        var idx = text.startIndex
        var n = 0
        while let openR = text.range(of: "<function=", range: idx..<text.endIndex) {
            content += text[idx..<openR.lowerBound]
            let blockEnd: String.Index
            if let closeR = text.range(of: "</function>", range: openR.upperBound..<text.endIndex) {
                blockEnd = closeR.upperBound
            } else {
                blockEnd = text.endIndex
            }
            if let call = callFromXMLFunction(String(text[openR.lowerBound..<blockEnd]), index: n) {
                calls.append(call); n += 1
            }
            idx = blockEnd
        }
        content += text[idx..<text.endIndex]
        content = content
            .replacingOccurrences(of: "<tool_call>", with: "")
            .replacingOccurrences(of: "</tool_call>", with: "")
        return ToolCallParseResult(
            content: content.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: calls
        )
    }

    // MARK: - Mistral / Devstral

    /// `[TOOL_CALLS][ {"name":…, "arguments":{…}}, … ]`
    private static func parseMistral(_ text: String) -> ToolCallParseResult {
        guard let tagR = text.range(of: "[TOOL_CALLS]") else {
            return ToolCallParseResult(content: text.trimmingCharacters(in: .whitespacesAndNewlines), toolCalls: [])
        }
        let content = String(text[text.startIndex..<tagR.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = String(text[tagR.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        var calls: [ParsedToolCall] = []
        if let data = rest.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for (n, obj) in arr.enumerated() {
                if let call = callFromObject(obj, index: n) { calls.append(call) }
            }
        }
        return ToolCallParseResult(content: content, toolCalls: calls)
    }

    // MARK: - Harmony (gpt-oss), best-effort

    /// Extracts `final` channel as content and `commentary to=functions.NAME …
    /// <|message|>{args}<|call|>` segments as tool calls. gpt-oss is gnarly; this
    /// handles the common single/multi tool-call shape and falls back to treating
    /// unstructured text as content.
    private static func parseHarmony(_ text: String) -> ToolCallParseResult {
        var calls: [ParsedToolCall] = []
        var content = ""
        var n = 0
        // The `.*?` channel/call patterns scan with dotMatchesLineSeparators; on a
        // pathological multi-MB generation the regex engine's backtracking is wasted
        // work. Cap the scanned span — a real tool-call block is small (< a few KB).
        // Both the match target and the substring source are this one capped string, so
        // every returned range is in-bounds for the substrings below.
        let scanned = text.count > 256 * 1024 ? String(text.prefix(256 * 1024)) : text
        let scanner = scanned as NSString
        let full = NSRange(location: 0, length: scanner.length)
        // Tool calls: ...to=functions.NAME ... <|message|> ARGS <|call|>
        let callPattern = "to=functions\\.([A-Za-z0-9_\\-]+).*?<\\|message\\|>(.*?)<\\|call\\|>"
        if let re = try? NSRegularExpression(pattern: callPattern, options: [.dotMatchesLineSeparators]) {
            for m in re.matches(in: scanned, range: full) {
                let name = scanner.substring(with: m.range(at: 1))
                let args = scanner.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                if let call = callFromObject(["name": name, "arguments": parseJSONObject(args) ?? args], index: n) {
                    calls.append(call); n += 1
                }
            }
        }
        // Content: final channel.
        let finalPattern = "<\\|channel\\|>final<\\|message\\|>(.*?)(<\\|end\\|>|<\\|return\\|>|$)"
        if let re = try? NSRegularExpression(pattern: finalPattern, options: [.dotMatchesLineSeparators]),
           let m = re.firstMatch(in: scanned, range: full) {
            content = scanner.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if calls.isEmpty {
            // No channels at all — treat the whole thing as plain content.
            content = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ToolCallParseResult(content: content, toolCalls: calls)
    }

    // MARK: - Nemotron 3 (NVIDIA)

    /// `<toolcall>{"name":…, "arguments":{…}}</toolcall>` (lowercase, no underscore).
    /// Reasoning arrives in `<think>…</think>` which is stripped first. Reuses the
    /// tagged-block scanner (tolerant of prose, multiple calls, truncation).
    private static func parseNemotron(_ text: String) -> ToolCallParseResult {
        parseTagged(stripThink(text), open: "<toolcall>", close: "</toolcall>")
    }

    // MARK: - GLM (Zhipu)

    /// `<tool_call>NAME<arg_key>k</arg_key><arg_value>v</arg_value>…</tool_call>`.
    /// Also accepts a Qwen-compat `{json}` body. Reasoning in `<think>…</think>`.
    private static func parseGLM(_ text: String) -> ToolCallParseResult {
        let stripped = stripThink(text)
        var calls: [ParsedToolCall] = []
        var content = ""
        var idx = stripped.startIndex
        var n = 0
        while let openR = stripped.range(of: "<tool_call>", range: idx..<stripped.endIndex) {
            content += stripped[idx..<openR.lowerBound]
            let bodyStart = openR.upperBound
            let bodyEnd: String.Index, nextIdx: String.Index
            if let closeR = stripped.range(of: "</tool_call>", range: bodyStart..<stripped.endIndex) {
                bodyEnd = closeR.lowerBound; nextIdx = closeR.upperBound
            } else {
                bodyEnd = stripped.endIndex; nextIdx = stripped.endIndex
            }
            let body = String(stripped[bodyStart..<bodyEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let call = callFromNameArgsJSON(body, index: n) ?? callFromGLMArgs(body, index: n) {
                calls.append(call); n += 1
            }
            idx = nextIdx
        }
        content += stripped[idx..<stripped.endIndex]
        return ToolCallParseResult(
            content: content.trimmingCharacters(in: .whitespacesAndNewlines), toolCalls: calls
        )
    }

    /// GLM body `NAME<arg_key>k</arg_key><arg_value>v</arg_value>…`: name is the text
    /// before the first `<arg_key>`; each value is JSON-typed if it parses.
    private static func callFromGLMArgs(_ body: String, index: Int) -> ParsedToolCall? {
        let nameEnd = body.range(of: "<arg_key>")?.lowerBound ?? body.endIndex
        let name = String(body[body.startIndex..<nameEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var args: [String: Any] = [:]
        var search = nameEnd
        while let ks = body.range(of: "<arg_key>", range: search..<body.endIndex),
              let ke = body.range(of: "</arg_key>", range: ks.upperBound..<body.endIndex),
              let vs = body.range(of: "<arg_value>", range: ke.upperBound..<body.endIndex),
              let ve = body.range(of: "</arg_value>", range: vs.upperBound..<body.endIndex) {
            let key = String(body[ks.upperBound..<ke.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let val = String(body[vs.upperBound..<ve.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            args[key] = jsonScalar(val)
            search = ve.upperBound
        }
        let argsJSON = (try? jsonData(args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ParsedToolCall(id: makeID(index), name: name, argumentsJSON: argsJSON)
    }

    // MARK: - Kimi K2 (Moonshot)

    /// `<|tool_calls_section_begin|>` then repeated
    /// `<|tool_call_begin|>functions.NAME:idx<|tool_call_argument_begin|>{json}<|tool_call_end|>`.
    private static func parseKimi(_ text: String) -> ToolCallParseResult {
        let stripped = stripThink(text)
        guard let secR = stripped.range(of: "<|tool_calls_section_begin|>") else {
            return ToolCallParseResult(
                content: stripped.trimmingCharacters(in: .whitespacesAndNewlines), toolCalls: []
            )
        }
        let content = String(stripped[stripped.startIndex..<secR.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var calls: [ParsedToolCall] = []
        var idx = secR.upperBound
        var n = 0
        while let bs = stripped.range(of: "<|tool_call_begin|>", range: idx..<stripped.endIndex) {
            let beEnd = stripped.range(of: "<|tool_call_end|>", range: bs.upperBound..<stripped.endIndex)
            let blockEnd = beEnd?.lowerBound ?? stripped.endIndex
            let block = stripped[bs.upperBound..<blockEnd]
            if let argR = block.range(of: "<|tool_call_argument_begin|>") {
                let idPart = String(block[block.startIndex..<argR.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let argsRaw = String(block[argR.upperBound..<block.endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                let name = kimiName(idPart)
                if !name.isEmpty {
                    let norm = normalizedArgs(argsRaw)
                    calls.append(ParsedToolCall(id: makeID(n), name: name, argumentsJSON: norm.isEmpty ? "{}" : norm))
                    n += 1
                }
            }
            idx = beEnd?.upperBound ?? stripped.endIndex
        }
        return ToolCallParseResult(content: content, toolCalls: calls)
    }

    /// `functions.NAME:idx` → `NAME`.
    private static func kimiName(_ id: String) -> String {
        var s = id
        if let dot = s.range(of: "functions.") { s = String(s[dot.upperBound...]) }
        if let colon = s.range(of: ":") { s = String(s[s.startIndex..<colon.lowerBound]) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - MiniMax M2

    /// Anthropic-style `<minimax:tool_call><invoke name="fn"><parameter name="p">v</parameter>…</invoke>`.
    /// Scans `<invoke …>` blocks directly so a missing wrapper still parses.
    private static func parseMiniMax(_ text: String) -> ToolCallParseResult {
        let stripped = stripThink(text)
        var calls: [ParsedToolCall] = []
        var content = ""
        var idx = stripped.startIndex
        var n = 0
        while let openR = stripped.range(of: "<invoke name=", range: idx..<stripped.endIndex) {
            content += stripped[idx..<openR.lowerBound]
            let invEnd = stripped.range(of: "</invoke>", range: openR.upperBound..<stripped.endIndex)
            let blockEnd = invEnd?.upperBound ?? stripped.endIndex
            if let call = callFromInvoke(String(stripped[openR.lowerBound..<blockEnd]), index: n) {
                calls.append(call); n += 1
            }
            idx = blockEnd
        }
        content += stripped[idx..<stripped.endIndex]
        content = content
            .replacingOccurrences(of: "<minimax:tool_call>", with: "")
            .replacingOccurrences(of: "</minimax:tool_call>", with: "")
        return ToolCallParseResult(
            content: content.trimmingCharacters(in: .whitespacesAndNewlines), toolCalls: calls
        )
    }

    /// `<invoke name="NAME"><parameter name="K">V</parameter>…</invoke>`; values JSON-typed.
    private static func callFromInvoke(_ block: String, index: Int) -> ParsedToolCall? {
        guard let name = attrValue(block, attr: "<invoke name="), !name.isEmpty else { return nil }
        var args: [String: Any] = [:]
        var search = block.startIndex
        while let ps = block.range(of: "<parameter name=", range: search..<block.endIndex) {
            guard let key = quotedAfter(block, from: ps.upperBound),
                  let pgt = block.range(of: ">", range: ps.upperBound..<block.endIndex),
                  let pe = block.range(of: "</parameter>", range: pgt.upperBound..<block.endIndex)
            else { break }
            let val = String(block[pgt.upperBound..<pe.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            args[key] = jsonScalar(val)
            search = pe.upperBound
        }
        let argsJSON = (try? jsonData(args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ParsedToolCall(id: makeID(index), name: name, argumentsJSON: argsJSON)
    }

    /// First double-quoted string after `from`.
    private static func quotedAfter(_ s: String, from: String.Index) -> String? {
        guard let q1 = s.range(of: "\"", range: from..<s.endIndex),
              let q2 = s.range(of: "\"", range: q1.upperBound..<s.endIndex) else { return nil }
        return String(s[q1.upperBound..<q2.lowerBound])
    }

    /// First double-quoted value following the literal `attr`.
    private static func attrValue(_ s: String, attr: String) -> String? {
        guard let r = s.range(of: attr) else { return nil }
        return quotedAfter(s, from: r.upperBound)
    }

    // MARK: - Shared serialize/strip helpers

    /// Drop `<think>…</think>` reasoning blocks (Nemotron/GLM/Kimi). Keeps prose
    /// before/after; an unterminated `<think>` drops everything from the opener.
    private static func stripThink(_ text: String) -> String {
        var out = text
        while let openR = out.range(of: "<think>") {
            if let closeR = out.range(of: "</think>", range: openR.upperBound..<out.endIndex) {
                out = String(out[out.startIndex..<openR.lowerBound]) + String(out[closeR.upperBound...])
            } else {
                out = String(out[out.startIndex..<openR.lowerBound])
                break
            }
        }
        return out
    }

    /// `{json}` → `<arg_key>k</arg_key>\n<arg_value>v</arg_value>` pairs (GLM replay).
    private static func glmArgPairs(_ argsJSON: String) -> String {
        guard let obj = parseJSONObject(argsJSON) else { return "" }
        return obj.keys.sorted().map { k in
            "<arg_key>\(k)</arg_key>\n<arg_value>\(stringifyValue(obj[k]!))</arg_value>"
        }.joined(separator: "\n")
    }

    /// `{json}` → `<parameter name="k">v</parameter>` (MiniMax replay).
    private static func minimaxParams(_ argsJSON: String) -> String {
        guard let obj = parseJSONObject(argsJSON) else { return "" }
        return obj.keys.sorted().map { k in
            "<parameter name=\"\(k)\">\(stringifyValue(obj[k]!))</parameter>"
        }.joined()
    }

    /// String values pass through raw; everything else re-serializes to JSON.
    private static func stringifyValue(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let data = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]),
           let str = String(data: data, encoding: .utf8) { return str }
        return "\(v)"
    }

    // MARK: - Helpers

    private static func callFromNameArgsJSON(_ body: String, index: Int) -> ParsedToolCall? {
        guard let obj = parseJSONObject(body) else { return nil }
        return callFromObject(obj, index: index)
    }

    /// Qwen3-Coder xml_function body:
    /// `<function=NAME><parameter=KEY>\nVALUE\n</parameter>…</function>`. Each value
    /// is typed by JSON if it parses (so `["ls","-la"]` becomes a real array), else
    /// kept as a string. Ref: mlx_lm tool_parsers/qwen3_coder.py.
    private static func callFromXMLFunction(_ body: String, index: Int) -> ParsedToolCall? {
        guard let nameR = body.range(of: "<function="),
              let gt = body.range(of: ">", range: nameR.upperBound..<body.endIndex)
        else { return nil }
        let name = String(body[nameR.upperBound..<gt.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        var args: [String: Any] = [:]
        var search = gt.upperBound
        while let ps = body.range(of: "<parameter=", range: search..<body.endIndex) {
            // A truncated final parameter (model cut off mid-call) is kept best-effort
            // with whatever args parsed so far — the name + partial args are still
            // actionable and the schema-validate/repair ladder handles bad args. ponytail.
            guard let pgt = body.range(of: ">", range: ps.upperBound..<body.endIndex),
                  let pe = body.range(of: "</parameter>", range: pgt.upperBound..<body.endIndex)
            else { break }
            let key = String(body[ps.upperBound..<pgt.lowerBound])
            var val = String(body[pgt.upperBound..<pe.lowerBound])
            if val.hasPrefix("\n") { val.removeFirst() }
            if val.hasSuffix("\n") { val.removeLast() }
            args[key] = jsonScalar(val)
            search = pe.upperBound
        }
        let argsJSON = (try? jsonData(args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ParsedToolCall(id: makeID(index), name: name, argumentsJSON: argsJSON)
    }

    /// Parse a parameter value as JSON (array/object/number/bool/quoted-string);
    /// fall back to the raw string when it isn't valid JSON.
    private static func jsonScalar(_ s: String) -> Any {
        if let data = s.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return obj
        }
        return s
    }

    private static func callFromObject(_ obj: [String: Any], index: Int) -> ParsedToolCall? {
        guard let name = obj["name"] as? String, !name.isEmpty else { return nil }
        let argsJSON: String
        switch obj["arguments"] {
        case let s as String:
            argsJSON = s.isEmpty ? "{}" : s
        case let dict as [String: Any]:
            argsJSON = (try? jsonData(dict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        case .some(let other):
            argsJSON = (try? jsonData(other)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        case .none:
            // Some models use "parameters" instead of "arguments".
            if let dict = obj["parameters"] as? [String: Any] {
                argsJSON = (try? jsonData(dict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            } else {
                argsJSON = "{}"
            }
        }
        return ParsedToolCall(id: makeID(index), name: name, argumentsJSON: argsJSON)
    }

    private static func parseJSONObject(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Re-serialize an arguments JSON string to compact canonical form; if it does
    /// not parse, pass it through (the model may have emitted slightly-off JSON that
    /// the downstream consumer still tolerates).
    private static func normalizedArgs(_ s: String) -> String {
        guard let obj = parseJSONObject(s),
              let data = try? jsonData(obj),
              let out = String(data: data, encoding: .utf8) else { return s }
        return out
    }

    private static func jsonData(_ obj: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    private static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data()
        let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
        // strip the enclosing [ ] to get the quoted scalar
        return String(arr.dropFirst().dropLast())
    }

    private static func makeID(_ index: Int) -> String {
        "call_\(UUID().uuidString.prefix(8))_\(index)"
    }
}
