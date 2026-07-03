import AppKit
import Foundation

/// Headless quality bench: runs the inline-completion corpus straight through
/// `CoreBridge.complete` — no synthetic host window, no CGEvent typing, no
/// per-case settle waits. This measures COMPLETION QUALITY (prompt, ladder,
/// sanitize, language gates) an order of magnitude faster than the UI bench;
/// ghost mechanics (type-through, delete-regrow, positioning) stay in the UI
/// bench (`bench.swift --capture ...`), which is what the overlay actually needs.
///
/// Activation: launch the app with
///   PROSPER_BENCH_CORPUS=/path/corpus.json PROSPER_BENCH_OUT=/path/out.json
/// Optional: PROSPER_BENCH_CASES=en01,bg03 (filter), PROSPER_BENCH_QUIT=1
/// (terminate the app when done — the normal flow for a bench-only instance).
enum BenchRunner {
    struct Case {
        let id: String
        let lang: String
        let kind: String?
        let prefix: String
        let after: String
        let expect: String?
    }

    /// The corpus file has grown organically (objects + a nested array block),
    /// so walk the JSON and collect anything case-shaped instead of decoding a
    /// strict schema.
    static func loadCases(_ data: Data) -> [Case] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var out: [Case] = []
        var seen = Set<String>()
        func walk(_ any: Any) {
            if let a = any as? [Any] { a.forEach(walk); return }
            guard let d = any as? [String: Any] else { return }
            guard let id = d["id"] as? String, let prefix = d["prefix"] as? String else {
                // Container object (e.g. {"cases": [...]}) — descend.
                d.values.forEach(walk)
                return
            }
            guard seen.insert(id).inserted else { return }
            out.append(Case(
                id: id, lang: d["lang"] as? String ?? "", kind: d["kind"] as? String,
                prefix: prefix, after: d["after"] as? String ?? "",
                expect: d["expect"] as? String
            ))
        }
        walk(root)
        return out
    }

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["PROSPER_BENCH_CORPUS"] != nil
    }

    @MainActor
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let corpusPath = env["PROSPER_BENCH_CORPUS"] else { return }
        let outPath = env["PROSPER_BENCH_OUT"] ?? "/tmp/prosper-bench/headless.json"
        let filter: Set<String>? = env["PROSPER_BENCH_CASES"].map {
            Set($0.split(separator: ",").map(String.init))
        }
        Task { @MainActor in
            await run(corpusPath: corpusPath, outPath: outPath, filter: filter)
            if env["PROSPER_BENCH_QUIT"] == "1" { NSApp.terminate(nil) }
        }
    }

    @MainActor
    static func run(corpusPath: String, outPath: String, filter: Set<String>?) async {
        guard let data = FileManager.default.contents(atPath: corpusPath) else {
            NSLog("prosper bench: cannot read corpus at %@", corpusPath)
            return
        }
        let all = loadCases(data)
        guard !all.isEmpty else {
            NSLog("prosper bench: no cases parsed from %@", corpusPath)
            return
        }
        let cases = filter.map { f in all.filter { f.contains($0.id) } } ?? all
        NSLog("prosper bench: headless run, %d case(s)", cases.count)
        var results: [[String: Any]] = []
        var nonEmpty = 0, expectHits = 0
        for (i, c) in cases.enumerated() {
            let (completion, ms) = await completeOnce(before: c.prefix, after: c.after)
            let got = completion ?? ""
            if !got.isEmpty { nonEmpty += 1 }
            // Soft quality signal: does the completion begin with the corpus
            // expectation (case/space-insensitive)? Not a hard gate — several
            // continuations can be right — but drift shows up in the aggregate.
            let hit = !got.isEmpty && c.expect.map {
                got.lowercased().trimmingCharacters(in: .whitespaces)
                    .hasPrefix($0.lowercased().prefix(8))
            } ?? false
            if hit { expectHits += 1 }
            results.append([
                "id": c.id, "lang": c.lang, "ms": ms,
                "completion": got, "expect": c.expect ?? "",
                "nonEmpty": !got.isEmpty, "expectHit": hit,
            ])
            NSLog("prosper bench: [%d/%d] %@ %@ -> \"%@\" (%dms)",
                  i + 1, cases.count, c.id, got.isEmpty ? "·" : "✓",
                  String(got.prefix(40)), ms)
        }
        let summary: [String: Any] = [
            "cases": cases.count, "nonEmpty": nonEmpty, "expectHits": expectHits,
            "results": results,
        ]
        if let out = try? JSONSerialization.data(
            withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(
                atPath: (outPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: outPath, contents: out)
        }
        NSLog("prosper bench: done — %d/%d non-empty, %d expect-hits, wrote %@",
              nonEmpty, cases.count, expectHits, outPath)
    }

    /// One completion with a 30s guard so a wedged model can't hang the run.
    @MainActor
    private static func completeOnce(before: String, after: String) async -> (String?, Int) {
        let start = Date()
        return await withCheckedContinuation { cont in
            var finished = false
            _ = CoreBridge.complete(before: before, after: after,
                                    bundleId: "com.prosper.bench") { s in
                guard !finished else { return }
                finished = true
                cont.resume(returning: (s, Int(Date().timeIntervalSince(start) * 1000)))
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !finished else { return }
                finished = true
                cont.resume(returning: (nil, -1))
            }
        }
    }
}
