import XCTest
import MLXLMCommon
@testable import ProsperApp

/// Model-free units of the llama.cpp agent engine: prompt rendering, the
/// tool-call grammar builder, UTF-8 stream assembly, and GGUF catalog routing.
/// (Decode-path behavior needs a loaded model — covered by the agent bench.)
final class LlamaAgentEngineTests: XCTestCase {

    /// #385 (QA #184): a row that overrides the `physicalMemoryGB` seam must restore it; a leak
    /// would let later rows read a fake RAM tier. Reset after the check so only the leaker fails.
    override func tearDown() {
        let real = Int(ProcessInfo.processInfo.physicalMemory / 1_000_000_000)
        XCTAssertEqual(AgentModelRegistry.physicalMemoryGB, real, "a row leaked a physicalMemoryGB override")
        AgentModelRegistry.physicalMemoryGB = real
        super.tearDown()
    }

    // MARK: ChatML rendering

    func testRenderChatMLBasicTurns() {
        let out = LlamaAgentEngine.renderChatML(
            messages: [
                .init(role: "system", content: "You are helpful."),
                .init(role: "user", content: "hi"),
                .init(role: "assistant", content: "hello"),
                .init(role: "user", content: "bye"),
            ], tools: [])
        XCTAssertEqual(out, """
        <|im_start|>system
        You are helpful.<|im_end|>
        <|im_start|>user
        hi<|im_end|>
        <|im_start|>assistant
        hello<|im_end|>
        <|im_start|>user
        bye<|im_end|>
        <|im_start|>assistant

        """)
    }

    func testRenderChatMLToolResponseTurn() {
        let out = LlamaAgentEngine.renderChatML(
            messages: [
                .init(role: "user", content: "run it"),
                .init(role: "tool", content: "exit 0"),
            ], tools: [])
        XCTAssertTrue(out.contains("<|im_start|>user\n<tool_response>\nexit 0\n</tool_response><|im_end|>\n"))
    }

    func testRenderChatMLInjectsToolsIntoExistingSystem() {
        // ToolSpec == [String: any Sendable]; annotate each nested level so the
        // literal doesn't infer non-Sendable Any.
        let tool: ToolSpec = [
            "type": "function",
            "function": [
                "name": "read_file",
                "parameters": ["type": "object"] as [String: any Sendable],
            ] as [String: any Sendable],
        ]
        let out = LlamaAgentEngine.renderChatML(
            messages: [
                .init(role: "system", content: "Base prompt."),
                .init(role: "user", content: "go"),
            ], tools: [tool])
        // One system turn, carrying both the base prompt and the tools block.
        XCTAssertEqual(out.components(separatedBy: "<|im_start|>system").count - 1, 1)
        XCTAssertTrue(out.contains("Base prompt."))
        XCTAssertTrue(out.contains("<tools>"))
        XCTAssertTrue(out.contains("\"read_file\""))
        XCTAssertTrue(out.contains("<tool_call></tool_call> XML tags"))
    }

    /// #294 / #313: toolsSystemBlock encodes through ToolCallParser.jsonText; a spec
    /// JSONSerialization can't encode is skipped instead of aborting (rc 134).
    func testToolsSystemBlockSkipsUnencodableSpec() {
        let bad: ToolSpec = ["type": "function", "function": ["name": "bad", "max": Double.infinity] as [String: any Sendable]]
        let good: ToolSpec = ["type": "function", "function": ["name": "ls", "description": "list"] as [String: any Sendable]]
        let out = LlamaAgentEngine.toolsSystemBlock([bad, good])
        XCTAssertFalse(out.contains("bad"), out)
        XCTAssertTrue(out.contains("<tools>\n{\"function\":{\"description\":\"list\",\"name\":\"ls\"},\"type\":\"function\"}\n</tools>"), out)
    }

    func testRenderChatMLSynthesizesSystemWhenMissing() {
        let tool: ToolSpec = [
            "type": "function",
            "function": ["name": "ls"] as [String: any Sendable],
        ]
        let out = LlamaAgentEngine.renderChatML(
            messages: [.init(role: "user", content: "go")], tools: [tool])
        XCTAssertTrue(out.hasPrefix("<|im_start|>system\n# Tools"))
    }

    // MARK: tool-call grammar

    func testToolCallGrammarBakesNameEnum() throws {
        let g = try XCTUnwrap(LlamaAgentEngine.toolCallGrammar(toolNames: ["read_file", "shell.exec"]))
        XCTAssertTrue(g.contains(#"name ::= "\"read_file\"" | "\"shell.exec\"""#))
        XCTAssertTrue(g.contains(#"block ::= "<tool_call>""#))
        XCTAssertTrue(g.contains("</tool_call>"))
    }

    func testToolCallGrammarRefusesUnsafeNames() {
        // A name that could break out of a GBNF string literal must kill the
        // grammar entirely (SchemaValidator backstop remains), not ship escaped-ish.
        XCTAssertNil(LlamaAgentEngine.toolCallGrammar(toolNames: [#"a"b"#]))
        XCTAssertNil(LlamaAgentEngine.toolCallGrammar(toolNames: ["ok", "bad name"]))
        XCTAssertNil(LlamaAgentEngine.toolCallGrammar(toolNames: []))
    }

    // MARK: UTF-8 assembly

    func testUTF8AssemblerPassesASCIIThrough() {
        var a = UTF8Assembler()
        XCTAssertEqual(a.push(Array("hello".utf8)), "hello")
        XCTAssertEqual(a.push(Array(" world".utf8)), " world")
    }

    func testUTF8AssemblerHoldsSplitMultibyte() {
        // "я" = D1 8F, split across two pushes.
        var a = UTF8Assembler()
        XCTAssertEqual(a.push([0xD1]), "")
        XCTAssertEqual(a.push([0x8F]), "я")
    }

    func testUTF8AssemblerSplitFourByteEmoji() {
        // "😀" = F0 9F 98 80 split 1+3, prefixed by complete text.
        var a = UTF8Assembler()
        XCTAssertEqual(a.push(Array("ok".utf8) + [0xF0]), "ok")
        XCTAssertEqual(a.push([0x9F, 0x98, 0x80]), "😀")
    }

    func testUTF8AssemblerBulgarianStream() {
        var a = UTF8Assembler()
        var out = ""
        for b in Array("Здравей, свят".utf8) { out += a.push([b]) }
        XCTAssertEqual(out, "Здравей, свят")
    }

    // MARK: GGUF catalog routing

    func testGGUFLookupIsExactMatchOnly() {
        XCTAssertNotNil(AgentModelRegistry.gguf(for: "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF"))
        // Unknown ids must NOT fall back to the recommended model here —
        // this lookup routes engine selection.
        XCTAssertNil(AgentModelRegistry.gguf(for: "mlx-community/some-unknown-model"))
        // MLX rows carry no GGUF.
        XCTAssertNil(AgentModelRegistry.gguf(for: "mlx-community/Qwen3-8B-4bit-DWQ"))
    }

    func testRecommendedIsGGUFRow() {
        XCTAssertNotNil(AgentModelRegistry.gguf(for: AgentModelRegistry.recommendedId))
        XCTAssertEqual(AgentModelRegistry.model(for: AgentModelRegistry.recommendedId).toolFormat, .qwenXML)
    }

    func testQwen36RowPinnedAndDefaultUnchanged() throws {
        let id = "unsloth/Qwen3.6-35B-A3B-GGUF"
        let spec = try XCTUnwrap(AgentModelRegistry.gguf(for: id))
        XCTAssertEqual(spec.fileName, "Qwen3.6-35B-A3B-UD-Q4_K_M.gguf")
        XCTAssertEqual(spec.bytes, 22_134_528_992)
        XCTAssertEqual(spec.downloadURL.absoluteString,
                       "https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/a483e9e6cbd595906af30beda3187c2663a1118c/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf")
        XCTAssertEqual(AgentModelRegistry.model(for: id).toolFormat, .qwenXML)
        // Default stays Qwen3-Coder until 3.6 passes the on-device e2e + latency check.
        XCTAssertEqual(AgentModelRegistry.recommendedId, "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF")
    }

    /// #245: every GGUF row downloads from a commit-sha-pinned URL matching its id and fileName.
    func testEveryGGUFRowPinnedToCommitSha() throws {
        // HF main sha + x-linked-size as of #245 (raw responses in work/245-hf/).
        let expected: [String: (sha: String, bytes: Int64)] = [
            "unsloth/Qwen3.5-4B-GGUF": ("e87f176479d0855a907a41277aca2f8ee7a09523", 2_740_937_888),
            "unsloth/NVIDIA-Nemotron-3-Nano-4B-GGUF": ("8e81be55c5aa3d63bb82b6ceec62d50805d9e1bb", 2_900_295_712),
            "unsloth/Qwen3.5-9B-GGUF": ("3885219b6810b007914f3a7950a8d1b469d598a5", 5_680_522_464),
            "unsloth/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF": ("f2d3fe3694501008786e81e5f20360cbf715496a", 25_266_255_936),
            "unsloth/Qwen3-Next-80B-A3B-Instruct-GGUF": ("6688872b7a4e5eb8a121ceea08009530a024ba1d", 48_506_100_512),
            "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF": ("b17cb02dd882d5b6ab62fc777ad2995f19668350", 18_556_689_568),
            "unsloth/Qwen3.6-35B-A3B-GGUF": ("a483e9e6cbd595906af30beda3187c2663a1118c", 22_134_528_992),
            "unsloth/Qwen3-Coder-Next-GGUF": ("ce09c67b53bc8739eef83fe67b2f5d293c270632", 48_528_320_544),
        ]
        let rows = AgentModelRegistry.all().filter { $0.gguf != nil }
        XCTAssertEqual(rows.count, 8)
        XCTAssertEqual(Set(rows.map(\.id)), Set(expected.keys))
        for m in rows {
            let g = try XCTUnwrap(m.gguf)
            let pattern = "^https://huggingface\\.co/" + NSRegularExpression.escapedPattern(for: m.id)
                + "/resolve/[0-9a-f]{40}/" + NSRegularExpression.escapedPattern(for: g.fileName) + "$"
            XCTAssertNotNil(g.downloadURL.absoluteString.range(of: pattern, options: .regularExpression),
                            "\(m.id) not pinned: \(g.downloadURL)")
            let e = try XCTUnwrap(expected[m.id], "\(m.id) missing from table")
            XCTAssertTrue(g.downloadURL.absoluteString.contains("/resolve/\(e.sha)/"), "\(m.id) sha")
            XCTAssertEqual(g.bytes, e.bytes, "\(m.id) bytes")
        }
    }

    /// #159: Qwen3-8B → Qwen3.5-9B and Nemotron-3-Nano-30B → Nemotron-3.5-Lightning-30B,
    /// both pinned to a commit sha; the replaced ids are gone and the default is unchanged.
    func testRefreshedRowsPinnedAndReplacedIdsGone() throws {
        let rows: [(id: String, file: String, sha: String, bytes: Int64)] = [
            ("unsloth/Qwen3.5-9B-GGUF", "Qwen3.5-9B-Q4_K_M.gguf",
             "3885219b6810b007914f3a7950a8d1b469d598a5", 5_680_522_464),
            ("unsloth/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF",
             "NVIDIA-Nemotron-3.5-Lightning-30B-A3B-UD-Q4_K_M.gguf",
             "f2d3fe3694501008786e81e5f20360cbf715496a", 25_266_255_936),
        ]
        for r in rows {
            let spec = try XCTUnwrap(AgentModelRegistry.gguf(for: r.id), r.id)
            XCTAssertEqual(spec.fileName, r.file)
            XCTAssertEqual(spec.bytes, r.bytes)
            XCTAssertEqual(spec.downloadURL.absoluteString,
                           "https://huggingface.co/\(r.id)/resolve/\(r.sha)/\(r.file)")
            XCTAssertEqual(AgentModelRegistry.model(for: r.id).toolFormat, .qwenXML)
        }
        XCTAssertNil(AgentModelRegistry.gguf(for: "unsloth/Qwen3-8B-GGUF"))
        XCTAssertNil(AgentModelRegistry.gguf(for: "unsloth/Nemotron-3-Nano-30B-A3B-GGUF"))
        XCTAssertEqual(AgentModelRegistry.recommendedId, "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF")
    }

    /// #247: a saved id #159 removed heals to its same-tier replacement, not the 32 GB recommended.
    func testCanonicalIdMapsRemovedIdsToReplacements() {
        XCTAssertEqual(AgentModelRegistry.canonicalId("unsloth/Qwen3-8B-GGUF"), "unsloth/Qwen3.5-9B-GGUF")
        XCTAssertEqual(AgentModelRegistry.canonicalId("unsloth/Nemotron-3-Nano-30B-A3B-GGUF"),
                       "unsloth/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF")
        XCTAssertEqual(AgentModelRegistry.canonicalId("mlx-community/some-unknown-model", physicalMemoryGB: 64),
                       AgentModelRegistry.recommendedId)
        XCTAssertEqual(AgentModelRegistry.canonicalId("unsloth/Qwen3.5-4B-GGUF"), "unsloth/Qwen3.5-4B-GGUF")
        XCTAssertEqual(AgentModelRegistry.model(for: "unsloth/Qwen3-8B-GGUF").id, "unsloth/Qwen3.5-9B-GGUF")
    }

    /// #247/#256: Preferences.agentModel heals on read through the same map; the stored id is never rewritten.
    func testPreferencesAgentModelHealsOnReadWithoutWriteBack() {
        let d = Preferences.defaults, key = "agentModel"
        let saved = d.object(forKey: key)
        defer { d.set(saved, forKey: key) }
        d.set("unsloth/Qwen3-8B-GGUF", forKey: key)
        XCTAssertEqual(Preferences.agentModel, "unsloth/Qwen3.5-9B-GGUF")
        XCTAssertEqual(d.string(forKey: key), "unsloth/Qwen3-8B-GGUF")
        d.set("unsloth/Nemotron-3-Nano-30B-A3B-GGUF", forKey: key)
        XCTAssertEqual(Preferences.agentModel, "unsloth/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF")
        d.set("gone/unknown", forKey: key)
        XCTAssertEqual(Preferences.agentModel, thisMacDefault)
        XCTAssertEqual(d.string(forKey: key), "gone/unknown")   // may be another Mac's custom pick: not rewritten
        d.removeObject(forKey: key)
        XCTAssertEqual(Preferences.agentModel, thisMacDefault)
        XCTAssertNil(d.string(forKey: key))   // default is not persisted
    }

    private var thisMacDefault: String {
        AgentModelRegistry.defaultId(physicalMemoryGB: AgentModelRegistry.physicalMemoryGB)
    }

    /// #332/#340: the default follows physical RAM — the smallest row (4B) below every floor,
    /// 9B from the 16 GB floor, the 30B coder at or above 32 GB.
    func testDefaultIdFollowsPhysicalMemory() {
        for gb in [4, 8] {
            XCTAssertEqual(AgentModelRegistry.defaultId(physicalMemoryGB: gb), "unsloth/Qwen3.5-4B-GGUF", "\(gb) GB")
        }
        for gb in [16, 24] {
            XCTAssertEqual(AgentModelRegistry.defaultId(physicalMemoryGB: gb), "unsloth/Qwen3.5-9B-GGUF", "\(gb) GB")
        }
        for gb in [32, 48, 64, 128] {
            XCTAssertEqual(AgentModelRegistry.defaultId(physicalMemoryGB: gb), AgentModelRegistry.recommendedId, "\(gb) GB")
        }
        // Unknown id falls back to the memory-derived default; retired ids keep their #247/#248 mapping.
        XCTAssertEqual(AgentModelRegistry.canonicalId("gone/unknown", physicalMemoryGB: 16), "unsloth/Qwen3.5-9B-GGUF")
        XCTAssertEqual(AgentModelRegistry.canonicalId("gone/unknown", physicalMemoryGB: 32), AgentModelRegistry.recommendedId)
        XCTAssertEqual(AgentModelRegistry.canonicalId("mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit", physicalMemoryGB: 16),
                       "unsloth/Qwen3-Next-80B-A3B-Instruct-GGUF")
    }

    /// #332: the unset case returns this Mac's default without writing it (agentModel syncs, #256).
    func testUnsetAgentModelIsMemoryDerivedAndNotPersisted() {
        let d = Preferences.defaults, key = "agentModel"
        let saved = d.object(forKey: key)
        defer { d.set(saved, forKey: key) }
        d.removeObject(forKey: key)
        XCTAssertEqual(Preferences.agentModel, thisMacDefault)
        XCTAssertNil(d.object(forKey: key))
    }

    /// #366: the unset and unknown cases follow the RAM seam, not a fixed id.
    func testAgentModelFollowsPhysicalMemorySeam() {
        let d = Preferences.defaults, key = "agentModel"
        let saved = d.object(forKey: key), savedGB = AgentModelRegistry.physicalMemoryGB
        defer { d.set(saved, forKey: key); AgentModelRegistry.physicalMemoryGB = savedGB }
        d.removeObject(forKey: key)
        for (gb, want) in [(8, "unsloth/Qwen3.5-4B-GGUF"), (16, "unsloth/Qwen3.5-9B-GGUF"), (32, AgentModelRegistry.recommendedId)] {
            AgentModelRegistry.physicalMemoryGB = gb
            XCTAssertEqual(Preferences.agentModel, want, "\(gb) GB")
        }
        XCTAssertNil(d.object(forKey: key))
        d.set("gone/unknown", forKey: key)
        AgentModelRegistry.physicalMemoryGB = 16
        XCTAssertEqual(Preferences.agentModel, "unsloth/Qwen3.5-9B-GGUF")
    }

    /// #340: healAgentModelMirror re-reads the healed id without writing it, and the
    /// persist guard is released afterwards so a later user pick still persists.
    @MainActor
    func testHealAgentModelMirrorDoesNotPersistAndReleasesGuard() {
        let d = Preferences.defaults, key = "agentModel"
        let saved = d.object(forKey: key)
        defer { d.set(saved, forKey: key) }
        d.set("unsloth/NVIDIA-Nemotron-3-Nano-4B-GGUF", forKey: key)
        let model = SettingsModel()
        XCTAssertEqual(model.agentModel, "unsloth/NVIDIA-Nemotron-3-Nano-4B-GGUF")
        d.set("gone/unknown", forKey: key)
        model.healAgentModelMirror()
        XCTAssertEqual(model.agentModel, thisMacDefault)
        XCTAssertEqual(d.string(forKey: key), "gone/unknown")   // heal never writes
        model.agentModel = "unsloth/Qwen3.5-9B-GGUF"
        XCTAssertEqual(d.string(forKey: key), "unsloth/Qwen3.5-9B-GGUF")   // guard not stuck
    }

    /// #247: every replacement target is a live catalog id (else canonicalId falls to recommended).
    func testEveryReplacementTargetIsInCatalog() {
        let ids = Set(AgentModelRegistry.all().map(\.id))
        XCTAssertFalse(AgentModelRegistry.replacements.isEmpty)
        for (old, new) in AgentModelRegistry.replacements {
            XCTAssertTrue(ids.contains(new), "\(old) → \(new) not in catalog")
            XCTAssertFalse(ids.contains(old), "\(old) is still a catalog id")
        }
    }

    /// #248: every MLX id retired in 2756432 heals to a GGUF row in the same or a smaller
    /// RAM tier, and only a 32 GB pick (the recommended row's tier) may land on recommendedId.
    func testRetiredMLXIdsResolveWithinTheirRAMTier() {
        let retired: [Int: [String]] = [
            16: ["mlx-community/Qwen3.5-4B-MLX-4bit", "mlx-community/NVIDIA-Nemotron-3-Nano-4B-4bit",
                 "mlx-community/Qwen3-8B-4bit-DWQ", "mlx-community/phi-4-4bit", "mlx-community/gpt-oss-20b-MXFP4-Q4"],
            24: ["mlx-community/Devstral-Small-2507-4bit-DWQ", "mlx-community/Devstral-Small-2-24B-Instruct-2512-6bit",
                 "mlx-community/GLM-4.7-Flash-4bit"],
            32: ["mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit-dwq-v2", "lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-6bit",
                 "mlx-community/Qwen3.6-35B-A3B-4bit-DWQ", "mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit",
                 "leonsarmiento/Ornith-1.0-35B-5bit-mlx", "airagrp/ornith-1.0-9B-mlx-BF16"],
            64: ["mlx-community/Qwen3-Coder-Next-4bit", "mlx-community/gpt-oss-120b-MXFP4-Q4",
                 "mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit", "mlx-community/GLM-4.5-Air-4bit",
                 "mlx-community/Llama-4-Scout-17B-16E-Instruct-4bit"],
            128: ["lmstudio-community/MiniMax-M2.5-MLX-4bit"],
            192: ["inferencerlabs/MiMo-V2.5-Pro-MLX-4.3bit-INF"],
            256: ["mlx-community/GLM-4.6-4bit"],
            512: ["mlx-community/Nemotron-3-Ultra-550B-A55B-4bit", "mlx-community/GLM-5-4bit",
                  "pipenetwork/Kimi-K2.7-Code-MLX-4bit-hiprec"],
        ]
        XCTAssertEqual(retired.values.joined().count, 25)
        let catalog = Dictionary(uniqueKeysWithValues: AgentModelRegistry.models.map { ($0.id, $0) })
        for (tier, ids) in retired {
            for old in ids {
                let healed = AgentModelRegistry.canonicalId(old)
                guard let row = catalog[healed] else { XCTFail("\(old) → \(healed) not a catalog row"); continue }
                XCTAssertLessThanOrEqual(row.minRAMGB, tier, "\(old) (\(tier) GB) → \(healed) (\(row.minRAMGB) GB) went up a tier")
                if tier != 32 {
                    XCTAssertNotEqual(healed, AgentModelRegistry.recommendedId, "\(old) (\(tier) GB) fell through to recommendedId")
                }
            }
        }
    }

    /// #247: a custom (HF-imported) id is canonical as-is, and the getter leaves it in UserDefaults.
    /// Both stores read Preferences.defaults only, so save/restore the two keys.
    func testCustomIdIsCanonicalAndNotRewritten() {
        let d = Preferences.defaults, key = "agentModel", customKey = "customAgentModelsV1", labelsKey = "modelLabelOverridesV1"
        let savedPick = d.object(forKey: key), savedCustom = d.object(forKey: customKey), savedLabels = d.object(forKey: labelsKey)
        defer { d.set(savedPick, forKey: key); d.set(savedCustom, forKey: customKey); d.set(savedLabels, forKey: labelsKey) }
        let id = "test-247/Custom-Coder-GGUF"
        CustomModelStore.upsert(CustomAgentModel(id: id, label: "Custom", sizeBytes: 0, note: "", toolFormat: .qwenXML))
        XCTAssertEqual(AgentModelRegistry.canonicalId(id), id)
        XCTAssertEqual(AgentModelRegistry.model(for: id).id, id)
        d.set(id, forKey: key)
        XCTAssertEqual(Preferences.agentModel, id)
        XCTAssertEqual(d.string(forKey: key), id)
        // Same id on a Mac without that custom model: resolves to this Mac's default, stays stored.
        CustomModelStore.remove(id)
        XCTAssertEqual(Preferences.agentModel, thisMacDefault)
        XCTAssertEqual(d.string(forKey: key), id)
    }

    /// #256: a retired id re-added as a custom model is the user's pick, not stale.
    func testRetiredIdReaddedAsCustomIsNotRewritten() throws {
        let d = Preferences.defaults, key = "agentModel", customKey = "customAgentModelsV1", labelsKey = "modelLabelOverridesV1"
        let savedPick = d.object(forKey: key), savedCustom = d.object(forKey: customKey), savedLabels = d.object(forKey: labelsKey)
        defer { d.set(savedPick, forKey: key); d.set(savedCustom, forKey: customKey); d.set(savedLabels, forKey: labelsKey) }
        let id = try XCTUnwrap(AgentModelRegistry.replacements.keys.sorted().first)
        CustomModelStore.upsert(CustomAgentModel(id: id, label: "Custom", sizeBytes: 0, note: "", toolFormat: .qwenXML))
        d.set(id, forKey: key)
        XCTAssertEqual(Preferences.agentModel, id)
        XCTAssertEqual(d.string(forKey: key), id)
        XCTAssertEqual(AgentModelRegistry.model(for: id).id, id)
    }

    func testGGUFRowsSurviveCatalogMerge() {
        let all = AgentModelRegistry.all()
        let ggufRows = all.filter { $0.gguf != nil }
        XCTAssertEqual(ggufRows.count, 8)
        // No duplicate ids after the custom-model merge.
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
    }

    // MARK: on-device e2e (gated — GGUF download + Metal load)

    /// The llama twin of `AgentToolCallE2ETests`: full production path
    /// (download → load → ChatML render → lazy-grammar decode → stream), asserting
    /// the `<tool_call>` wire form survives to `ToolCallParser`. Uses the smallest
    /// catalog GGUF (Qwen3.5 4B, ~2.6 GB). Run:
    ///   PROSPER_AGENT_E2E=1 swift test --filter testLlamaAgentToolCall 2>&1 | tee /tmp/llama-agent-e2e.log
    func testLlamaAgentToolCallE2E() async throws {
        guard ProcessInfo.processInfo.environment["PROSPER_AGENT_E2E"] == "1" else {
            throw XCTSkip("Set PROSPER_AGENT_E2E=1 to run the on-device llama agent e2e.")
        }
        let spec = try XCTUnwrap(AgentModelRegistry.gguf(for: "unsloth/Qwen3.5-4B-GGUF"))
        let engine = LlamaAgentEngine.shared
        try await engine.ensureModel(spec) { p, s in
            NSLog("llama-agent-e2e: %3.0f%% %@", p * 100, s)
        }

        let commandProp: [String: any Sendable] = [
            "type": "array",
            "items": ["type": "string"] as [String: any Sendable],
            "description": "argv of the command to run, e.g. [\"ls\", \"-la\"].",
        ]
        let parameters: [String: any Sendable] = [
            "type": "object",
            "properties": ["command": commandProp] as [String: any Sendable],
            "required": ["command"] as [any Sendable],
        ]
        let shellTool: ToolSpec = [
            "type": "function",
            "function": [
                "name": "shell",
                "description": "Run a shell command and return its stdout/stderr.",
                "parameters": parameters,
            ] as [String: any Sendable],
        ]

        let messages: [MLXEngine.ChatTurn] = [
            .init(role: "system",
                  content: "You are a coding agent. Use the provided tools to accomplish "
                      + "the user's goal. To run a shell command, emit a tool call."),
            .init(role: "user", content: "List the files in the current directory."),
        ]
        var out = ""
        let stream = engine.generateChat(
            messages: messages, tools: [shellTool],
            maxTokens: 512, temperature: 0, topP: 1, stop: [])
        for try await chunk in stream { out += chunk }
        NSLog("llama-agent-e2e: output(len=%d) = %@", out.count, out)

        let parsed = ToolCallParser.parse(out, format: .qwenXML)
        XCTAssertTrue(parsed.hasToolCalls,
                      "llama stream did not yield a parseable tool call: \(out)")
        // Grammar-locked call must also validate against the schema (the whole
        // point of the GBNF path: the repair ladder should never be needed).
        XCTAssertTrue(SchemaValidator.validate(
            toolCalls: parsed.toolCalls, against: [shellTool]).isEmpty)
        await engine.unload()
    }
}
