import XCTest
@testable import ProsperApp

/// Pure-logic checks for the HF URL → repo id parse, tool-format guess, and label
/// derivation that feed the "add your own model" flow. No network — `fetch` is exercised
/// only by these inputs.
final class HFModelImporterTests: XCTestCase {
    func testRepoIdFromVariousURLForms() {
        XCTAssertEqual(HFModelImporter.repoId(from: "mlx-community/Qwen3-8B-4bit-DWQ"),
                       "mlx-community/Qwen3-8B-4bit-DWQ")
        XCTAssertEqual(HFModelImporter.repoId(from: "https://huggingface.co/mlx-community/Qwen3-8B-4bit-DWQ"),
                       "mlx-community/Qwen3-8B-4bit-DWQ")
        XCTAssertEqual(HFModelImporter.repoId(from: "https://huggingface.co/mlx-community/Qwen3-8B-4bit-DWQ/tree/main"),
                       "mlx-community/Qwen3-8B-4bit-DWQ")
        XCTAssertEqual(HFModelImporter.repoId(from: "  huggingface.co/owner/name/  "),
                       "owner/name")
        XCTAssertEqual(HFModelImporter.repoId(from: "https://huggingface.co/owner/name?foo=bar"),
                       "owner/name")
        // host match is case-insensitive
        XCTAssertEqual(HFModelImporter.repoId(from: "https://HuggingFace.co/owner/name"),
                       "owner/name")
        XCTAssertEqual(HFModelImporter.repoId(from: "https://huggingface.co/owner/name/blob/main/x.json"),
                       "owner/name")
    }

    func testRepoIdRejectsBadInput() {
        XCTAssertNil(HFModelImporter.repoId(from: ""))
        XCTAssertNil(HFModelImporter.repoId(from: "justaname"))          // no owner/name
        XCTAssertNil(HFModelImporter.repoId(from: "https://example.com/x/y")) // other host
    }

    func testToolFormatGuess() {
        XCTAssertEqual(HFModelImporter.guessToolFormat("mlx-community/Qwen3-Coder-30B"), .qwenXML)
        XCTAssertEqual(HFModelImporter.guessToolFormat("mlx-community/Devstral-Small"), .mistral)
        XCTAssertEqual(HFModelImporter.guessToolFormat("foo/NVIDIA-Nemotron-3-Nano"), .nemotron)
        XCTAssertEqual(HFModelImporter.guessToolFormat("foo/GLM-5-4bit"), .glm)
        XCTAssertEqual(HFModelImporter.guessToolFormat("foo/Kimi-K2"), .kimi)
        XCTAssertEqual(HFModelImporter.guessToolFormat("foo/MiniMax-M2"), .minimax)
        XCTAssertEqual(HFModelImporter.guessToolFormat("foo/unknown-model"), .qwenXML) // default
    }

    func testDeriveLabel() {
        XCTAssertEqual(HFModelImporter.deriveLabel("mlx-community/Qwen3-8B-4bit-DWQ"),
                       "Qwen3 8B 4bit DWQ")
    }
}
