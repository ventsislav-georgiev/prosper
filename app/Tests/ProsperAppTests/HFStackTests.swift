import Foundation
import Hub
import Jinja
import Tokenizers
import XCTest

/// #171: offline sanity for the swift-transformers / swift-jinja behavior the MLX
/// path (#huggingFaceTokenizerLoader + the model's chat_template) relies on.
final class HFStackTests: XCTestCase {

    private func bpeTokenizer(byteFallback: Bool) throws -> Tokenizer {
        let vocab: [String: Int] = [
            "<unk>": 0, "A": 1, "L": 2, "<0xF0>": 3, "<0x9F>": 4, "<0x90>": 5, "<0x88>": 6,
        ]
        let model: [String: Any] = [
            "type": "BPE", "vocab": vocab, "merges": [String](), "fuse_unk": false,
            "unk_token": "<unk>", "byte_fallback": byteFallback,
        ]
        let decode = { (object: [String: Any]) throws -> Config in
            try JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: object))
        }
        return try AutoTokenizer.from(
            // Gemma's tokenizer_config names GemmaTokenizer (BPE + byte_fallback).
            tokenizerConfig: decode(["tokenizer_class": "GemmaTokenizer", "unk_token": "<unk>"]),
            tokenizerData: decode(["model": model])
        )
    }

    /// swift-transformers 1.3.5 honors `byte_fallback` in BPE: on, an out-of-vocab
    /// character becomes its UTF-8 byte tokens; off, it is one `<unk>`.
    func testBPEByteFallbackHonorsConfig() throws {
        let bytes = ["<0xF0>", "<0x9F>", "<0x90>", "<0x88>"]
        XCTAssertEqual(try bpeTokenizer(byteFallback: true).tokenize(text: "A🐈L"), ["A"] + bytes + ["L"])
        XCTAssertEqual(try bpeTokenizer(byteFallback: false).tokenize(text: "A🐈L"), ["A", "<unk>", "L"])
    }

    /// swift-jinja 2.5 serializes `tojson` like Python's json.dumps (", " / ": "
    /// separators, unescaped slashes) — the form tool-calling chat templates emit.
    func testToolsRenderThroughTojsonLikeJsonDumps() throws {
        let tools = try Value(any: [["name": "get_weather"], ["description": "Forecast for a city/region"]])
        let rendered = try Template("<tools>{{ tools | tojson }}</tools>").render(["tools": tools])
        XCTAssertEqual(rendered, #"<tools>[{"name": "get_weather"}, {"description": "Forecast for a city/region"}]</tools>"#)
    }
}
