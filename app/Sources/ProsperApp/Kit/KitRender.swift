import Foundation

// #872 P1 (spec 4.2 placeholders and piece table, 4.3 summary, 4.5 runner line, errata A1, A4, A7,
// A8, A10, C12): the pure render step. No file is read or written here; the caller hands in a
// validated kit and the paths. Plain value types, no actor isolation.

/// The absolute paths a kit renders with (spec 4.2 placeholders, 4.5 runner). Never `~`.
struct KitRenderContext: Equatable, Sendable {
    var extensionID: String
    var kitDir: String // {{kit_dir}}
    var kitBin: String // {{kit_bin}}
    var kitConfig: String // {{kit_config}}
    var home: String // {{home}}
    var runner: String // prosper-kit-run

    /// `configHome` is the `kitconfig:` parent (ManagedConfigRoots.configHome, `~/.config`), so the
    /// rendered `{{kit_config}}` is the dir the seeds land in.
    static func standard(extensionID: String, slug: String, kitDir: URL, home: URL, configHome: URL) -> KitRenderContext {
        let prosper = configHome.appendingPathComponent("prosper", isDirectory: true)
        return KitRenderContext(
            extensionID: extensionID, kitDir: kitDir.standardizedFileURL.path,
            kitBin: prosper.appendingPathComponent("kits", isDirectory: true).appendingPathComponent(extensionID, isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true).path,
            kitConfig: configHome.appendingPathComponent(slug, isDirectory: true).path,
            home: home.path,
            runner: prosper.appendingPathComponent("kit-runtime/prosper-kit-run").path)
    }

    var placeholders: [(key: String, value: String)] {
        [("{{kit_dir}}", kitDir), ("{{kit_bin}}", kitBin), ("{{kit_config}}", kitConfig), ("{{home}}", home)]
    }
}

/// A generated `{{kit_bin}}/<name>` shim (spec 4.5 item 2). P1 plans it; P2 writes it.
struct KitShimPlan: Equatable, Sendable {
    var pieceID: String
    var name: String
    var target: String // absolute path of the shim
    var text: String
}

struct KitPlan: Equatable, Sendable {
    var pieces: [ManagedConfigPiece] = []
    var shims: [KitShimPlan] = []
    var refusals: [KitRefusal] = []
}

enum KitRender {
    /// The managed seed that makes `@{{kit_config}}/local.md` resolve (spec 4.5 item 1, errata A3).
    /// "_" cannot start a kit piece id or a seed piece id, so it never collides.
    static let localSeedID = "_local"
    static let localTemplate = """
    <!-- Your own lines for this kit go below. Claude Code reads this file last, after the kit's
         rules. A line here that contradicts a kit rule gives undefined behaviour: to change a kit
         rule, switch that piece off in Prosper and write your own. -->

    """

    // MARK: (a) placeholders

    /// spec 4.2: only `*.md` files are rendered; scripts are never rewritten.
    static func isRendered(_ relPath: String) -> Bool { relPath.lowercased().hasSuffix(".md") }

    /// One pass over the text. A placeholder right after `@` is an import path and gets the
    /// errata A4 form (spaces backslash-escaped); anywhere else it is the plain path.
    static func substitute(_ text: String, _ c: KitRenderContext) -> String {
        let pairs = c.placeholders
        var out = ""
        var rest = Substring(text)
        while let r = rest.range(of: "{{") {
            out += rest[..<r.lowerBound]
            let tail = rest[r.lowerBound...]
            if let hit = pairs.first(where: { tail.hasPrefix($0.key) }) {
                out += out.hasSuffix("@") ? escapeImport(hit.value) : hit.value
                rest = tail.dropFirst(hit.key.count)
            } else {
                out += "{{"
                rest = tail.dropFirst(2)
            }
        }
        return out + rest
    }

    /// A kit file as the staged copy holds it: `*.md` rendered, everything else byte-identical.
    static func renderFile(_ relPath: String, _ data: Data, _ c: KitRenderContext) -> Data {
        guard isRendered(relPath), let text = String(data: data, encoding: .utf8) else { return data }
        return Data(substitute(text, c).utf8)
    }

    // MARK: (b) import line

    /// errata A4: unquoted, spaces backslash-escaped, never in a code span or fence.
    static func escapeImport(_ path: String) -> String { path.replacingOccurrences(of: " ", with: "\\ ") }

    /// nil when no import line can carry the path.
    static func importLine(_ absolutePath: String) -> String? {
        guard !absolutePath.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else { return nil }
        return "@" + escapeImport(absolutePath)
    }

    // MARK: (c) runner line

    /// POSIX single quotes: every byte literal, a `'` closed, escaped and reopened.
    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// `prosper-kit-run <ext-id> <piece-id> <name> [<interpreter>] <kit-dir>/<path>` (spec 4.5,
    /// errata A7: the kit id and the piece id are always there). With an interpreter the runner
    /// runs the interpreter (a PATH name from `requires`) with the script as its first argument.
    static func runnerLine(_ c: KitRenderContext, pieceID: String, name: String, target: String, interpreter: String? = nil) -> String {
        ([c.runner, c.extensionID, pieceID, name] + (interpreter.map { [$0] } ?? []) + [target]).map(shellQuote).joined(separator: " ")
    }

    /// errata C12: plain `exec`, never `exec --` (dash runs "--" as the command).
    static func shimText(_ c: KitRenderContext, pieceID: String, name: String, target: String) -> String {
        "#!/bin/sh\nexec " + runnerLine(c, pieceID: pieceID, name: name, target: target) + " \"$@\"\n"
    }

    // MARK: (d) managed pieces

    static func seedPieceID(_ pieceID: String, _ under: String) -> String { pieceID + "." + under.replacingOccurrences(of: "/", with: ".") }

    /// The owner every piece of the kit carries: the extension id, the `kitconfig:` slug, the kit
    /// dir as the `ext:` root (spec 2.7, 4.1).
    static func owner(_ v: KitValidated, kitDir: URL) -> ManagedConfigOwner {
        ManagedConfigOwner(id: v.extensionID, version: v.version, kitSlug: v.slug, extensionDir: kitDir)
    }

    /// spec 4.2 piece table. Seeds come first, so local.md exists before the block importing it.
    /// The only settings.json paths written: hooks.<event> (append), statusLine (set) and
    /// permissions.allow / deny / ask (union); KitRenderTests walks every kind to prove it.
    static func plan(_ v: KitValidated, _ c: KitRenderContext) -> KitPlan {
        var plan = KitPlan()
        var seeds: [ManagedConfigPiece] = []
        var wiring: [ManagedConfigPiece] = []
        func missing(_ p: KitManifest.Piece) { plan.refusals.append(.init(subject: p.id, reason: .missingKey)) }
        for p in v.kit.pieces {
            switch p.kind {
            case .claudeMD:
                guard let source = p.source else { missing(p); continue }
                guard let line = importLine(c.kitDir + "/" + source) else {
                    plan.refusals.append(.init(subject: p.id, reason: .notImportable)); continue
                }
                wiring.append(ManagedConfigPiece(id: p.id, kind: .block, target: "claude:CLAUDE.md", text: line, position: p.position))
            case .tools:
                for t in v.tools[p.id] ?? [] {
                    plan.shims.append(KitShimPlan(pieceID: p.id, name: t.name, target: c.kitBin + "/" + t.name,
                                                  text: shimText(c, pieceID: p.id, name: t.name, target: c.kitDir + "/" + t.path)))
                }
            case .hook:
                guard let event = p.event, let run = p.run else { missing(p); continue }
                let command = runnerLine(c, pieceID: p.id, name: p.id, target: c.kitDir + "/" + run, interpreter: p.interpreter)
                let handler = #"{"type": "command", "command": "# + OrderedJSON.quote(command) + (p.timeout.map { #", "timeout": \#($0)"# } ?? "") + "}"
                let value = "{" + (p.matcher.map { #""matcher": "# + OrderedJSON.quote($0) + ", " } ?? "") + #""hooks": ["# + handler + "]}"
                wiring.append(ManagedConfigPiece(id: p.id, kind: .json, target: "claude:settings.json", path: ["hooks", event], op: .append, value: value))
            case .statusline:
                guard let run = p.run else { missing(p); continue }
                let command = runnerLine(c, pieceID: p.id, name: p.id, target: c.kitDir + "/" + run, interpreter: p.interpreter)
                wiring.append(ManagedConfigPiece(id: p.id, kind: .json, target: "claude:settings.json", path: ["statusLine"], op: .set,
                                                 value: #"{"type": "command", "command": "# + OrderedJSON.quote(command) + "}"))
            case .permissions:
                // errata A8: claude:settings.json only, never settings.local.json
                for (key, rules) in [("allow", p.allow), ("deny", p.deny), ("ask", p.ask)] where !rules.isEmpty {
                    wiring.append(ManagedConfigPiece(id: "\(p.id).\(key)", kind: .json, target: "claude:settings.json", path: ["permissions", key],
                                                     op: .union, value: "[" + rules.map(OrderedJSON.quote).joined(separator: ", ") + "]"))
                }
            case .seed:
                for f in v.seeds[p.id] ?? [] {
                    seeds.append(ManagedConfigPiece(id: seedPieceID(p.id, f.name), kind: .seed, target: "kitconfig:" + f.name, source: "ext:" + f.path))
                }
            }
        }
        if needsLocalSeed(v) {
            seeds.append(ManagedConfigPiece(id: localSeedID, kind: .seed, target: "kitconfig:local.md", text: localTemplate))
        }
        plan.pieces = seeds + wiring
        return plan
    }

    /// A kit with a claude-md piece imports local.md; Prosper seeds it unless a seed ships one.
    static func needsLocalSeed(_ v: KitValidated) -> Bool {
        v.kit.pieces.contains { $0.kind == .claudeMD } && !v.seeds.values.joined().contains { $0.name.lowercased() == "local.md" }
    }

    // MARK: (e) "What will change"

    /// spec 4.3: generated from the manifest; the authoritative description (errata A1 wording).
    static func summary(_ v: KitValidated, _ c: KitRenderContext) -> [String] {
        var lines: [String] = []
        for p in v.kit.pieces {
            let via = p.interpreter.map { " with \($0)" } ?? ""
            switch p.kind {
            case .claudeMD:
                lines.append("\(p.id): a block at the \(p.position.rawValue) of CLAUDE.md imports \(c.kitDir)/\(p.source ?? "")")
            case .tools:
                let names = (v.tools[p.id] ?? []).map(\.name).joined(separator: ", ")
                lines.append("\(p.id): commands \(names.isEmpty ? "(none)" : names) in \(c.kitBin)")
            case .hook:
                let timeout = p.timeout.map { "timeout \($0) s" } ?? "Claude Code's default timeout"
                lines.append("\(p.id): Claude Code runs \(p.run ?? "")\(via) on \(p.event ?? "") (\(p.matcher ?? "any")) in every session, \(timeout)")
            case .statusline:
                lines.append("\(p.id): Claude Code runs \(p.run ?? "")\(via) as the status line; Remove puts your own status line back")
            case .permissions:
                // one line per rule: a rule may itself hold ", "
                for (key, rules) in [("allow", p.allow), ("deny", p.deny), ("ask", p.ask)] {
                    for rule in rules { lines.append("\(p.id): permissions.\(key) in settings.json gains \(rule)") }
                }
            case .seed:
                let names = (v.seeds[p.id] ?? []).map(\.name).joined(separator: ", ")
                lines.append("\(p.id): copies \(names.isEmpty ? "(none)" : names) into \(c.kitConfig) when missing; never overwritten")
            }
        }
        if needsLocalSeed(v) {
            lines.append("\(localSeedID): \(c.kitConfig)/local.md is created for your own lines; Claude Code reads it last")
        }
        if !v.kit.requires.isEmpty { lines.append("requires on PATH: \(v.kit.requires.joined(separator: ", "))") }
        return lines
    }
}
