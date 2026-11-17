import Foundation

// #920: the agents piece kind's install half. An agent file goes to <claude>/agents/<name>.md byte for byte (the live copy's
// bytes: the validator refused every placeholder, so the render left them as shipped). The ownership record is
// kits/<ext-id>/agents.json: agent name -> the piece and the sha256 of the bytes the kit wrote.
// - A file there that the record does not name is the person's: that agent is refused and the file never touched.
// - A recorded file is replaced or removed only while it still hashes as written; an edited one is kept and reported.
// - Every step is relative to the agents dir opened O_NOFOLLOW (KitDir); a symlinked agents dir is refused, never followed.

extension KitStore {
    struct AgentRecord: Codable, Equatable, Sendable {
        var piece: String
        var sha256: String
    }

    static let agentMode: mode_t = 0o644
    var agentsRecordPath: String { layout.root + "/agents.json" }

    /// Outside data (Prosper's own file, but hand-editable): a name that is no agent name is dropped, never used as a path.
    func readAgentRecord() -> [String: AgentRecord] {
        guard let d = fs.read(agentsRecordPath, limit: 64 << 10),
              let r = try? JSONDecoder().decode([String: AgentRecord].self, from: d) else { return [:] }
        return r.filter { KitManifest.isValidPieceID($0.key) }
    }

    private func writeAgentRecord(_ r: [String: AgentRecord]) throws {
        try ensureLayout()
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        try fs.openDir(layout.root).write("agents.json", try e.encode(r), mode: Self.envMode)
    }

    private static func agentsDir(_ claude: URL) -> String { claude.appendingPathComponent("agents", isDirectory: true).path }

    /// Apply / repair / an off toggle: every planned agent installed, every recorded one no longer planned removed.
    /// Returns the notes (refusals, kept files, I/O errors); nothing here throws past the caller.
    func syncAgents(_ planned: [KitAgentPlan], from kitDir: String, claude: URL) -> [String] {
        var record = readAgentRecord()
        let keep = Set(planned.map(\.name))
        var notes = dropAgents(record.keys.filter { !keep.contains($0) }, claude: claude, record: &record)
        if !planned.isEmpty {
            do {
                let path = Self.agentsDir(claude)
                try fs.ensureDir(path, narrow: false)
                let dir = try fs.openDir(path)
                for a in planned { notes += installAgent(a, from: kitDir, in: dir, record: &record) }
            } catch {
                // O_NOFOLLOW | O_DIRECTORY answers ENOTDIR for a link on macOS, so ask lstat rather than read the error
                let why = fs.kind(Self.agentsDir(claude)) == .symlink ? "is a link; Prosper does not write through links" : "cannot be used: \(error)"
                notes.append("agents: not installed: \(Self.agentsDir(claude)) \(why)")
            }
        }
        do { try writeAgentRecord(record) } catch { notes.append("agents.json: \(error)") }
        return notes
    }

    private func installAgent(_ a: KitAgentPlan, from kitDir: String, in dir: any KitDir, record: inout [String: AgentRecord]) -> [String] {
        let file = a.name + ".md"
        let shown = dir.path + "/" + file
        guard let data = fs.read(kitDir + "/" + a.path, limit: KitValidator.maxAgentBytes) else {
            return ["\(a.pieceID): \(a.path) cannot be read in the kit copy"]
        }
        let sha = OrderedJSON.sha256(Array(data))
        let mine = record[a.name]
        do {
            switch dir.kind(file) {
            case .missing:
                // written under a dot name, then moved with RENAME_EXCL: a file that appears meanwhile is never replaced
                let temp = "." + file + ".prosper-kit"
                try? dir.remove(temp, dir: false)
                try dir.write(temp, data, mode: Self.agentMode)
                do { try dir.rename(temp, to: dir, file, swap: false) } catch { try? dir.remove(temp, dir: false); throw error }
            case .file where mine != nil:
                let onDisk = dir.read(file, limit: KitValidator.maxAgentBytes).map { OrderedJSON.sha256(Array($0)) }
                guard onDisk == mine?.sha256 else { return ["\(a.pieceID): kept \(shown): edited since the kit wrote it"] }
                // shortcut: an edit between this read and the rename is replaced; a base-hash check at the rename would close it
                if onDisk != sha { try dir.write(file, data, mode: Self.agentMode) }
            default:
                return ["\(a.pieceID): refused \(shown): a file the kit did not write is there; it is never overwritten"]
            }
        } catch {
            return ["\(a.pieceID): \(shown): \(error)"]
        }
        record[a.name] = AgentRecord(piece: a.pieceID, sha256: sha)
        return []
    }

    /// Remove: the recorded agents of `pieces` (nil: every one). A file still as written is deleted; an edited one is kept.
    /// Either way the record lets go of it.
    func removeAgents(pieces: [String]?, claude: URL) -> [String] {
        var record = readAgentRecord()
        let names = record.filter { r in pieces.map { $0.contains(r.value.piece) } ?? true }.map(\.key)
        guard !names.isEmpty else { return [] }
        var notes = dropAgents(names, claude: claude, record: &record)
        do { try writeAgentRecord(record) } catch { notes.append("agents.json: \(error)") }
        return notes
    }

    private func dropAgents(_ names: [String], claude: URL, record: inout [String: AgentRecord]) -> [String] {
        guard !names.isEmpty else { return [] }
        let dir: (any KitDir)? = fs.kind(Self.agentsDir(claude)) == .missing ? nil : try? fs.openDir(Self.agentsDir(claude))
        var notes: [String] = []
        for name in names.sorted() {
            guard let mine = record[name] else { continue }
            let file = name + ".md"
            if let dir, dir.kind(file) != .missing {
                let onDisk = dir.read(file, limit: KitValidator.maxAgentBytes).map { OrderedJSON.sha256(Array($0)) }
                if onDisk == mine.sha256 {
                    do { try dir.remove(file, dir: false) } catch { notes.append("\(mine.piece): \(dir.path)/\(file): \(error)"); continue }
                } else {
                    notes.append("\(mine.piece): kept \(dir.path)/\(file): edited since the kit wrote it")
                }
            }
            record[name] = nil
        }
        return notes
    }

    /// The pane's piece state for each agents piece: "installed", or each agent that is not, with why.
    func agentStates(_ planned: [KitAgentPlan], claude: URL) -> [String: String] {
        let record = readAgentRecord()
        let dir = try? fs.openDir(Self.agentsDir(claude))
        var lines: [String: [String]] = [:]
        for a in planned {
            let file = a.name + ".md"
            let onDisk = dir.flatMap { $0.kind(file) == .missing ? nil : $0.read(file, limit: KitValidator.maxAgentBytes) }
            let exists = dir.map { $0.kind(file) != .missing } ?? false
            let state: String
            switch (record[a.name], exists) {
            case (let mine?, true): state = onDisk.map { OrderedJSON.sha256(Array($0)) } == mine.sha256 ? "" : "\(file) edited"
            case (_?, false): state = "\(file) missing"
            case (nil, true): state = "\(file) refused: a file the kit did not write is there"
            case (nil, false): state = "\(file) not installed"
            }
            lines[a.pieceID, default: []] += state.isEmpty ? [] : [state]
        }
        return lines.mapValues { $0.isEmpty ? "installed" : $0.joined(separator: "; ") }
    }
}
