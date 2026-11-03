import Foundation

/// #619: the phone runs a fixed allowlist of this Mac's palette commands over Remote Terminal
/// (P4 of the phone-parity plan). DchConnection only dispatches 0x28 commands and 0x29
/// runCommand here; each gets exactly one reply. Gated by "Run commands from iPhone" (default
/// off): off refuses both, and machineInfo advertises no "commands".
///
/// Safety: the phone names a command id and only that handler runs, through the extension's
/// own async Lua lane. Never the universal palette (`>` there is shell), never invokeSync (a
/// main-thread VM), never CommandRouter.run (it can start a model load). Command ids are not
/// namespaced (ExtensionRegistry.rebuildRoutes is last-writer-wins), so a command counts only
/// while its extension is live, is a system extension, and has the table's extension id.
/// #724: the two fan ids are native Swift, matched exactly before any registry lookup.
/// #726: user and market extensions offer `phone = true` commands once the user allows the
/// extension on iPhone, as "<extension id>/<command id>", resolved on that record alone.
struct DchCommandOps: Sendable {
    var enabled: @Sendable () -> Bool = { Preferences.runCommandsFromPhone }
    var registry: @Sendable @MainActor () -> ExtensionRegistry? = { CommandRouter.registry }
    var fans = FanOps()

    /// #724: the fan commands' hardware side. Every member is a test seam; the shared popup
    /// paths they feed (StatsPopupView.engageManual / selectAuto) are not.
    struct FanOps: Sendable {
        /// Unprivileged SMC read; [] on a Mac with no fans.
        var read: @Sendable () -> [FanReading] = { FanInfo.read() }
        /// The first fan's engage (the popup's setManualReply at the cold ceiling). Never the
        /// approval modal (#728): an unapproved helper replies `.needsApproval`.
        var firstReply: @Sendable (Int, Double) async -> FanManualReply = {
            await FanControlHelper.setManualReply($0, rpm: $1, timeout: FanControlHelper.firstEngageTimeout, presentModal: false) }
        /// Every other fan's engage (the popup's setManual), also without the modal.
        var engage: @Sendable @MainActor (Int, Double) async -> Bool = { await FanControlHelper.setManual($0, rpm: $1, presentModal: false) }
    }

    typealias Reply = DchControlOps.Reply

    /// One allowlisted command: its id, the system extension that must own it, and the
    /// argument hint the phone shows (nil = no argument, tap to run).
    struct Allowed: Sendable {
        let id: String
        let ext: String
        var argument: String? = nil
    }

    /// The listing's order. Shell, scripts, killproc, anything that needs a window, focus, a
    /// Mac dialog or the model, and every user or market extension are never here.
    static let allowlist: [Allowed] = [
        Allowed(id: "calc.eval", ext: "com.prosper.calc", argument: "2+2"),
        Allowed(id: "unit.convert", ext: "com.prosper.units", argument: "1 km to m"),
        Allowed(id: "currency.convert", ext: "com.prosper.currency", argument: "32 usd to eur"),
        Allowed(id: "openlid.status", ext: "com.prosper.openlid"),
        Allowed(id: "openlid.toggle", ext: "com.prosper.openlid"),
        Allowed(id: "openlid.caffeine", ext: "com.prosper.openlid"),
        Allowed(id: "toggles.lock", ext: "com.prosper.toggles"),
        Allowed(id: "toggles.displayoff", ext: "com.prosper.toggles"),
        Allowed(id: "toggles.screensaver", ext: "com.prosper.toggles"),
        Allowed(id: "clipclear.now", ext: "com.prosper.clipclear"),
    ]

    /// #724: native Swift commands, not Lua: run by exact id before the Lua path, listed after
    /// the Lua rows while the Mac has an adjustable fan. Nothing else reaches native code.
    static let fanAuto = "fans.auto", fanManual = "fans.manual"
    static let fanRows: [[String: String]] = [
        ["id": fanAuto, "title": "Fans: Auto", "subtitle": "Hand every fan back to macOS",
         "ext": "System Stats", "icon": "fan"],
        ["id": fanManual, "title": "Fans: Manual", "subtitle": "Every fan at a percent of its min-max speed",
         "ext": "System Stats", "argument": "60%", "icon": "fan"],
    ]
    static let badSpeed = "speed must be 0-100%"

    /// UTF-8 bytes of a runCommand argument.
    static let maxArgument = 1 << 10
    static let offMessage = "commands are off"

    static func error(_ m: String) -> Data { DchControlOps.error(m) }

    /// `id`'s command, only while it is allowlisted, live, and owned by the table's system extension.
    @MainActor static func resolve(_ id: String, in reg: ExtensionRegistry) -> (record: ExtensionRecord, command: CommandContribution)? {
        guard let want = allowlist.first(where: { $0.id == id }),
              let hit = reg.command(id: id),
              hit.record.isLive, hit.record.isSystem, hit.record.id == want.ext else { return nil }
        return hit
    }

    /// #726: the wire id of a user or market extension's command. The phone confirms every id
    /// with a "/" before running it (iOS #727); allowlist and fan ids never contain one.
    static func phoneID(_ extID: String, _ commandID: String) -> String { "\(extID)/\(commandID)" }

    /// #726: "<ext>/<cmd>" (split on the first "/", both halves non-empty; the command id may
    /// hold more "/") → that extension's own phone command, while it is live, allowed on iPhone
    /// (isPhoneApproved: never a system extension, never after its phone commands changed) and
    /// still offers `cmd` to the phone. Never through the route table, so a same-id command in
    /// another extension can't stand in.
    @MainActor static func resolveUser(_ id: String, in reg: ExtensionRegistry) -> (record: ExtensionRecord, command: CommandContribution)? {
        guard let slash = id.firstIndex(of: "/") else { return nil }
        let extID = String(id[..<slash]), cmdID = String(id[id.index(after: slash)...])
        guard !extID.isEmpty, !cmdID.isEmpty, let record = reg.record(id: extID), record.isLive,
              reg.isPhoneApproved(id: extID),
              let cmd = record.manifest.contributes?.phoneCommands.first(where: { $0.id == cmdID }) else { return nil }
        return (record, cmd)
    }

    /// #726: the user rows, grouped by extension title. A row is listed only if run() would
    /// resolve its id back to the same record.
    @MainActor static func userRows(in reg: ExtensionRegistry) -> [[String: String]] {
        let titled = reg.records.sorted { ($0.manifest.extension.title, $0.id) < ($1.manifest.extension.title, $1.id) }
        return titled.flatMap { record in
            (record.manifest.contributes?.phoneCommands ?? []).compactMap { cmd -> [String: String]? in
                let id = phoneID(record.id, cmd.id)
                guard resolveUser(id, in: reg)?.record === record else { return nil }
                var row = ["id": id, "title": cmd.title, "ext": record.manifest.extension.title]
                row["subtitle"] = cmd.description
                row["argument"] = cmd.phoneArgument
                row["icon"] = cmd.icon
                return row
            }
        }
    }

    /// commands or runCommand; `reply` gets one frame.
    func handle(_ type: UInt8, _ payload: Data, reply: Reply) async {
        guard enabled() else { return reply(Self.error(Self.offMessage)) }
        if type == DchFrame.commands { await list(payload, reply) } else { await run(payload, reply) }
    }

    /// 0x28: `(empty) | {}` → commandsResp `[{id, title, subtitle?, ext, argument?, icon?}]`.
    func list(_ payload: Data, _ reply: Reply) async {
        let o = payload.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        guard o?.isEmpty == true else { return reply(Self.error("malformed")) }
        let registry = registry
        let (rows, userRows): ([[String: String]], [[String: String]]) = await MainActor.run {
            guard let reg = registry() else { return ([], []) }
            return (Self.allowlist.compactMap { a in
                guard let (record, cmd) = Self.resolve(a.id, in: reg) else { return nil }
                var row = ["id": cmd.id, "title": cmd.title, "ext": record.manifest.extension.title]
                row["subtitle"] = cmd.description
                row["argument"] = a.argument
                row["icon"] = cmd.icon
                return row
            }, Self.userRows(in: reg))
        }
        let fanRows = fans.read().contains { $0.max > $0.min } ? Self.fanRows : []
        reply(DchFrame.encode(DchFrame.commandsResp, json: rows + fanRows + userRows))
    }

    /// 0x29: `{id, argument?}` → commandResult `{text, detail?}`. Unknown keys are ignored.
    func run(_ payload: Data, _ reply: Reply) async {
        guard let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let id = o["id"] as? String else { return reply(Self.error("malformed")) }
        var argument = ""
        if let v = o["argument"] {
            guard let s = v as? String else { return reply(Self.error("malformed")) }
            argument = s
        }
        guard argument.utf8.count <= Self.maxArgument else { return reply(Self.error("argument too long")) }
        if id == Self.fanAuto || id == Self.fanManual { return reply(await runFans(id, argument)) }
        // ponytail: no manifest prefix is restored before the call (CommandRouter.runExtension
        // does); no allowlisted command reads its argument after one. Add it with the first that does.
        reply(await Self.invoke(id, argument, registry))
    }

    /// #724: "60", "60.5", "60%", " 60 % " → the number; nil unless plain decimal digits in
    /// 0...100. #728: no sign, hex, exponent, nan or inf (Double("…") takes them all).
    static func percent(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("%") { t = String(t.dropLast()).trimmingCharacters(in: .whitespaces) }
        guard t.wholeMatch(of: /[0-9]+(\.[0-9]+)?/) != nil, let v = Double(t), v <= 100 else { return nil }
        return v
    }

    /// #728: the phone's text for an unapproved helper, in place of the popup's modal.
    static let needsApproval = "Prosper's fan helper needs approval on the Mac: System Settings › General › Login Items"

    /// #724: the popup's own Automatic and Manual paths. Manual maps the percent onto each fan's
    /// min...max like the popup's slider and replies with the target rpm: the fans ramp for
    /// seconds after the engage, so a read here would still show the old speed.
    func runFans(_ id: String, _ argument: String) async -> Data {
        let fans = self.fans
        let adjustable = fans.read().filter { $0.max > $0.min }.sorted { $0.id < $1.id }
        guard !adjustable.isEmpty else { return Self.error("no adjustable fans") }
        if id == Self.fanAuto {
            await StatsPopupView.selectAuto(fanIDs: adjustable.map(\.id), presentModal: false).value
            return Self.shape("Auto")
        }
        guard let pct = Self.percent(argument) else { return Self.error(Self.badSpeed) }
        let rpms = adjustable.map { ($0.id, $0.min + pct / 100 * ($0.max - $0.min)) }
        let (saved, reply) = await Self.engage(Dictionary(uniqueKeysWithValues: rpms), fans)
        guard saved else {
            return Self.error(reply == .needsApproval ? Self.needsApproval : reply.errorText ?? "fans stayed automatic")
        }
        let each = rpms.map { String(Int($0.1.rounded())) }
        let shown = Set(each).count == 1 ? each[0] : each.joined(separator: " / ")
        return Self.shape("Manual · \(shown) rpm\ttarget at \(String(format: "%g", pct))%")
    }

    @MainActor static func engage(_ targets: [Int: Double], _ fans: FanOps) async -> (saved: Bool, reply: FanManualReply) {
        await StatsPopupView.engageManual(targets, firstReply: fans.firstReply, engage: fans.engage)
    }

    /// The check and invokeAsync's own lookup in one main-actor turn: no discover() can swap
    /// the record between them. Lua then runs on the extension's own lane, never on main.
    @MainActor static func invoke(_ id: String, _ argument: String,
                                  _ registry: @Sendable @MainActor () -> ExtensionRegistry?) async -> Data {
        guard let reg = registry() else { return error("not allowed") }
        if resolve(id, in: reg) != nil { return shape(await reg.invokeAsync(commandID: id, query: argument)) }
        guard let (record, cmd) = resolveUser(id, in: reg) else { return error("not allowed") }
        // #726: the record's own command. Its manifest prefix goes back on first, as in the
        // palette's locked mode (CommandRouter.runExtension): a third-party handler may parse it.
        return shape(await reg.invokeAsync(record, cmd, query: (cmd.prefix ?? "") + argument))
    }

    /// A handler's string as commandResult: "from\tto\tvalue" (units) → {value, "from → to"},
    /// "value\tdetail" → {value, detail}, else {raw}. nil or "" is "no result"; a view tree is
    /// refused, so raw JSON never reaches the phone as text.
    static func shape(_ raw: String?) -> Data {
        guard let raw, !raw.isEmpty else { return error("no result") }
        guard CommandRouter.viewNode(raw) == nil else { return error("unsupported result") }
        let p = raw.components(separatedBy: "\t")
        let out: [String: String]
        switch p.count {
        case 3: out = ["text": p[2], "detail": "\(p[0]) → \(p[1])"]
        case 2: out = ["text": p[0], "detail": p[1]]
        default: out = ["text": raw]
        }
        return DchFrame.encode(DchFrame.commandResult, json: out)
    }
}
