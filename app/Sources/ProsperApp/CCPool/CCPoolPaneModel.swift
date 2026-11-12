import Combine
import Foundation

/// #871 P2a: everything the ccpool Settings pane shows and does, derived from the store, the
/// service status and the last Refresh report, against an injected clock.
///
/// Isolation: @MainActor (the pane's model). Every blocking or async step (the add-time probe,
/// Keychain writes, Refresh, the listener start/restart, the import) runs in `Task.detached` on
/// nonisolated statics: no closure formed here is handed to Network, URLSession, the store or a
/// queue unless it is @Sendable and nonisolated (errata C7). Results come back through
/// `await self?.…` on the main actor. The token typed into the pane lives in `tokenDraft` until
/// commit and in the detached add task's locals after; it is never logged, echoed, counted or
/// kept in any other property.
@MainActor
final class CCPoolPaneModel: ObservableObject {
    nonisolated static let routeKey = "ccpoolRouteAgentSessions"

    enum RowState: Equatable, Sendable {
        case active, ready
        case limited(until: Int, claims: [String])
        case held(until: Int)
        case rejected
        /// The last check of this token could not answer (network error, no rate-limit headers).
        case unverified
    }

    struct Row: Equatable, Identifiable {
        var label: String
        var state: RowState
        var stateText: String
        var usageText: String
        var id: String { label }
    }

    enum ImportPhase: Equatable {
        case idle
        case review(CCPoolMigration.Plan)
        case imported(CCPoolMigration.Outcome)
        case finished(String)
    }

    let store: CCPoolStore
    let secrets: CCPoolSecrets
    let service: CCPoolService
    let logger: CCPoolLogger
    let defaults: UserDefaults
    let clock: @Sendable () -> Double
    let timeZone: TimeZone
    let probeBase: URL
    let vaultURL: URL
    let trash: CCPoolMigration.Trash
    let launcherPath: String?

    @Published var labelDraft = ""
    @Published var tokenDraft = ""
    @Published private(set) var busy = false
    @Published private(set) var proxyBusy = false
    @Published private(set) var refreshing = false
    @Published var notice: String?
    /// The account whose actions are open.
    @Published var selected: String?
    /// Remove asks first, in the pane: the label waiting for its confirm.
    @Published private(set) var confirmingRemove: String?
    @Published var renameDraft = ""
    @Published var customHours = ""
    @Published private(set) var report: CCPoolUsage.Report?
    @Published private(set) var rejected: Set<String> = []
    @Published private(set) var unverified: Set<String> = []
    @Published private(set) var importPhase: ImportPhase = .idle
    @Published var importChoices: [String: CCPoolMigration.Choice] = [:]

    init(store: CCPoolStore, secrets: CCPoolSecrets, service: CCPoolService, logger: CCPoolLogger = CCPoolOSLog(),
         defaults: UserDefaults = Preferences.defaults,
         clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
         timeZone: TimeZone = .current, probeBase: URL = CCPoolService.productionUpstream,
         vaultURL: URL, trash: @escaping CCPoolMigration.Trash = CCPoolMigration.moveToTrash,
         launcherPath: String? = nil) {
        self.store = store
        self.secrets = secrets
        self.service = service
        self.logger = logger
        self.defaults = defaults
        self.clock = clock
        self.timeZone = timeZone
        self.probeBase = probeBase
        self.vaultURL = vaultURL
        self.trash = trash
        self.launcherPath = launcherPath
    }

    // MARK: Proxy row

    var proxyRunning: Bool {
        if case .running = service.status { return true }
        return false
    }

    var port: UInt16 {
        if case .running(let p) = service.status { return p }
        return service.config.port
    }

    var proxyText: String {
        switch service.status {
        case .running(let p): return "Running on 127.0.0.1:\(p)"
        case .stopped: return "Stopped"
        case .heldByCCPool(let pid):
            return "Another ccpool proxy\(pid.map { " (pid \($0))" } ?? "") holds port \(service.config.port). "
                + "Prosper never stops it: quit it, then Start proxy."
        case .heldByOther: return "Port \(service.config.port) is in use by another program"
        case .failed: return "Could not start"
        }
    }

    var currentText: String { store.snapshot.current ?? "none yet" }

    /// QA #734 INFO-4: state.json exists but could not be read; account changes are refused.
    var storeProblem: String? { store.unreadable ? CCPoolStore.unreadableNote : nil }

    // MARK: Accounts

    var rows: [Row] {
        let now = clock()
        let st = store.snapshot
        return st.order.compactMap { label in
            guard let acct = st.accounts[label] else { return nil }
            let state = Self.rowState(label: label, account: acct, current: st.current, now: now,
                                      rejected: rejected, unverified: unverified)
            return Row(label: label, state: state, stateText: Self.stateText(state, timeZone: timeZone),
                       usageText: Self.usageText(store.usageSample(label), now: now))
        }
    }

    /// Precedence: a rejected token, a hand hold, a limit, an unanswered check, current, ready.
    nonisolated static func rowState(label: String, account: CCPoolState.Account, current: String?, now: Double,
                                     rejected: Set<String>, unverified: Set<String>) -> RowState {
        if rejected.contains(label) { return .rejected }
        if let h = account.held, Double(h) > now { return .held(until: h) }
        let live = account.cooldown.filter { Double($0.value) > now }
        if let until = live.values.min() {
            return .limited(until: until, claims: CCPoolCore.displayOrder.filter { live[$0] != nil }
                + live.keys.filter { !CCPoolCore.displayOrder.contains($0) }.sorted())
        }
        if unverified.contains(label) { return .unverified }
        return current == label ? .active : .ready
    }

    nonisolated static func stateText(_ s: RowState, timeZone: TimeZone) -> String {
        switch s {
        case .active: return "active"
        case .ready: return "ready"
        case .limited(let until, let claims):
            return "limited until \(timeText(until, timeZone: timeZone)) (\(claims.map { CCPoolCore.display[$0] ?? $0 }.joined(separator: ", ")))"
        case .held(let until): return "held until \(timeText(until, timeZone: timeZone))"
        case .rejected: return "token rejected"
        case .unverified: return "not verified"
        }
    }

    nonisolated static func timeText(_ epoch: Int, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "EEE HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(epoch)))
    }

    nonisolated static func ageText(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86400 { return "\(s / 3600) h ago" }
        return "\(s / 86400) d ago"
    }

    /// "5h 42% · week 10% · 3 min ago"; from proxy traffic or the last Refresh, whichever was last.
    nonisolated static func usageText(_ sample: CCPoolUsageSample?, now: Double) -> String {
        guard let sample else { return "no usage seen yet" }
        let known = CCPoolCore.displayOrder.filter { sample.util[$0] != nil }
        let cells = (known + sample.util.keys.filter { !known.contains($0) }.sorted()).map { claim in
            "\(CCPoolCore.display[claim] ?? claim) \(Int(((sample.util[claim] ?? 0) * 100).rounded()))%"
        }
        return (cells + [ageText(now - sample.at)]).joined(separator: " · ")
    }

    /// B6: cooldowns on a claim no model reads would never take an account out.
    var unreachableWarning: String? {
        let keys = CCPoolCore.unreachableKeys(store.snapshot)
        guard !keys.isEmpty else { return nil }
        return "Cooldowns on limits no model reads never skip an account: \(keys.sorted().joined(separator: ", "))"
    }

    /// The pool headroom row of the last Refresh ("All" in the Python status).
    var poolText: String? {
        guard let cells = report?.pool, !cells.isEmpty else { return nil }
        return cells.map { c in
            "\(CCPoolCore.display[c.claim] ?? c.claim) \(Int((c.free * 100).rounded()))%"
                + (c.growsAt.map { " (more at \(Self.timeText($0, timeZone: timeZone)))" } ?? "")
        }.joined(separator: " · ")
    }

    // MARK: Agent Sessions toggle

    var routeAgentSessions: Bool {
        get { defaults.bool(forKey: Self.routeKey) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.routeKey)
        }
    }

    var routeDisabledReason: String? {
        if store.read({ $0.order.isEmpty }) { return "Add an account first." }
        if !proxyRunning { return "The proxy is not running." }
        return nil
    }

    // MARK: Terminal use

    var terminalCommand: String { "ANTHROPIC_BASE_URL=\(CCPool.baseURL(port: port)) claude" }

    var launcherText: String {
        launcherPath.map { "Or run \($0), which checks the proxy first." }
            ?? "Or run bin/ccpool-launch from the extension folder, which checks the proxy first."
    }

    // MARK: Actions: accounts

    enum AddResult: Equatable, Sendable { case added(verified: Bool), rejected, failed(String) }

    /// Commit: the token buffer is cleared before any work starts.
    @discardableResult
    func addAccount() -> Task<Void, Never> {
        let label = labelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = tokenDraft
        tokenDraft = ""
        notice = nil
        busy = true
        let store = store, secrets = secrets, base = probeBase
        return Task.detached { [weak self] in
            let result = await Self.add(label: label, token: token, store: store, secrets: secrets, base: base)
            await self?.finishAdd(label, result)
        }
    }

    /// Validate by one probe (spec 3.4): 401/403 stores nothing; a probe that cannot answer stores
    /// the token "not verified". Error text names the label at most.
    nonisolated static func add(label: String, token: String, store: CCPoolStore, secrets: CCPoolSecrets,
                                base: URL) async -> AddResult {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return .failed(CCPoolStoreError.emptyLabel.description) }
        guard !token.isEmpty else { return .failed(CCPoolStoreError.emptyToken.description) }
        guard !store.unreadable else { return .failed(CCPoolStoreError.stateUnreadable.description) }
        guard store.read({ $0.accounts[label] == nil }) else { return .failed(CCPoolStoreError.duplicateLabel.description) }
        let probe = await CCPoolUsage.probe(token: token, base: base)
        if let s = probe?.status, s == 401 || s == 403 { return .rejected }
        do {
            try store.addAccount(label: label, token: token, secrets: secrets)
        } catch let e as CCPoolStoreError {
            return .failed(e.description)
        } catch let e as CCPoolSecretsError {
            return .failed("ccpool: \(e.description)")
        } catch {
            return .failed("ccpool: the account could not be stored")
        }
        if let p = probe { store.recordUsage(label, limits: p.limits) }
        // A 3xx is never followed (QA #734 INFO-10) and says nothing about the token.
        return .added(verified: probe.map { $0.status < 300 || (400..<500).contains($0.status) } ?? false)
    }

    private func finishAdd(_ label: String, _ result: AddResult) {
        busy = false
        switch result {
        case .added(let verified):
            labelDraft = ""
            if verified { unverified.remove(label) } else { unverified.insert(label) }
            rejected.remove(label)
            notice = verified ? "Added \(label)." : "Added \(label), not verified: the check could not reach Anthropic."
        case .rejected:
            notice = "Token rejected: \(label) was not added."
        case .failed(let why):
            notice = why
        }
    }

    func select(_ label: String?) {
        selected = selected == label ? nil : label
        renameDraft = selected ?? ""
        confirmingRemove = nil
    }

    /// The first step of Remove: asks, removes nothing.
    func requestRemove(_ label: String) { confirmingRemove = label }

    func cancelRemove() { confirmingRemove = nil }

    /// The confirm row's Remove: the Keychain item, the state entry and the upstream session go.
    @discardableResult
    func confirmRemove() -> Task<Void, Never>? {
        guard let label = confirmingRemove else { return nil }
        confirmingRemove = nil
        busy = true
        let service = service
        return Task.detached { [weak self] in
            let failure = Self.remove(label, service: service)
            await self?.finishRemove(label, failure)
        }
    }

    nonisolated static func remove(_ label: String, service: CCPoolService) -> String? {
        do { try service.removeAccount(label: label) } catch let e as CCPoolStoreError {
            return e.description
        } catch let e as CCPoolSecretsError {
            return "ccpool: \(e.description)"
        } catch {
            return "ccpool: \(label) could not be removed"
        }
        return nil
    }

    private func finishRemove(_ label: String, _ failure: String?) {
        busy = false
        if failure == nil {
            if selected == label { selected = nil }
            rejected.remove(label)
            unverified.remove(label)
        }
        notice = failure ?? "Removed \(label)."
    }

    func rename(_ label: String, to newLabel: String) {
        do {
            try store.renameAccount(label, to: newLabel)
            let to = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if rejected.remove(label) != nil { rejected.insert(to) }
            if unverified.remove(label) != nil { unverified.insert(to) }
            if selected == label { selected = to }
            notice = nil
        } catch {
            notice = "\(error)"
        }
        objectWillChange.send()
    }

    func move(_ label: String, by offset: Int) {
        store.moveAccount(label, by: offset)
        objectWillChange.send()
    }

    func hold(_ label: String, hours: Double) {
        guard hours > 0, hours.isFinite else { notice = "Hold for a number of hours above zero."; return }
        let now = clock()
        store.mutate { $0.hold(label, hours: hours, now: now) }
        notice = nil
        objectWillChange.send()
    }

    func holdCustom(_ label: String) {
        hold(label, hours: Double(customHours.trimmingCharacters(in: .whitespaces)) ?? 0)
    }

    /// Release = the Python `clear <label>`: every cooldown of that account, hold included.
    func release(_ label: String) {
        store.mutate { $0.clear(label) }
        objectWillChange.send()
    }

    // MARK: Actions: usage and proxy

    /// B21: one tiny request per account, straight to Anthropic (never through the proxy).
    @discardableResult
    func refreshUsage() -> Task<Void, Never> {
        refreshing = true
        let store = store, secrets = secrets, base = probeBase, logger = logger
        return Task.detached { [weak self] in
            let report = await CCPoolUsage.refresh(store: store, secrets: secrets, base: base, logger: logger)
            await self?.finishRefresh(report)
        }
    }

    private func finishRefresh(_ r: CCPoolUsage.Report) {
        refreshing = false
        report = r
        for row in r.rows {
            if let s = row.status, s == 401 || s == 403 {
                rejected.insert(row.label)
            } else if row.limits == nil {
                // Unknown is never healthy.
                rejected.remove(row.label)
                unverified.insert(row.label)
            } else {
                rejected.remove(row.label)
                unverified.remove(row.label)
            }
        }
    }

    /// Start (or restart) the listener off the main actor, with the brief bind retry.
    @discardableResult
    func restartProxy() -> Task<Void, Never> {
        proxyBusy = true
        let service = service
        return Task.detached { [weak self] in
            service.restart()
            await self?.finishProxy()
        }
    }

    @discardableResult
    func startProxy() -> Task<Void, Never> {
        proxyBusy = true
        let service = service
        return Task.detached { [weak self] in
            service.start(bindRetry: 3)
            await self?.finishProxy()
        }
    }

    private func finishProxy() { proxyBusy = false }

    // MARK: Actions: import (spec 3.7)

    /// Shown only while there is an old vault, or an import in progress.
    var importVisible: Bool { importPhase != .idle || FileManager.default.fileExists(atPath: vaultURL.path) }

    var canRunImport: Bool {
        guard case .review(let plan) = importPhase, !busy else { return false }
        return plan.conflicts.allSatisfy { importChoices[$0] != nil }
    }

    @discardableResult
    func beginImport() -> Task<Void, Never> {
        busy = true
        notice = nil
        let vault = vaultURL, store = store
        return Task.detached { [weak self] in
            let result = Result { try CCPoolMigration.inspect(vault: vault, store: store) }
                .mapError { ($0 as? CCPoolMigration.ReadError) ?? .unreadable }
            await self?.finishInspect(result)
        }
    }

    private func finishInspect(_ r: Result<CCPoolMigration.Plan, CCPoolMigration.ReadError>) {
        busy = false
        switch r {
        case .success(let plan) where plan.labels.isEmpty: notice = "The old vault lists no accounts."
        case .success(let plan):
            importChoices = [:]
            importPhase = .review(plan)
        case .failure(let e): notice = e.description
        }
    }

    @discardableResult
    func runImport() -> Task<Void, Never>? {
        guard canRunImport else { return nil }
        busy = true
        let vault = vaultURL, store = store, secrets = secrets, service = service, choices = importChoices, now = clock()
        return Task.detached { [weak self] in
            let result = Result { try CCPoolMigration.run(vault: vault, store: store, secrets: secrets, choices: choices, now: now) }
                .mapError { ($0 as? CCPoolMigration.ReadError) ?? .unreadable }
            if case .success(let o) = result { o.retiredIDs.forEach { service.upstream.drop(accountID: $0) } }
            await self?.finishRun(result)
        }
    }

    private func finishRun(_ r: Result<CCPoolMigration.Outcome, CCPoolMigration.ReadError>) {
        busy = false
        switch r {
        case .success(let o): importPhase = .imported(o)
        case .failure(let e):
            importPhase = .idle
            notice = e.description
        }
    }

    /// The last step: "Move the old vault to the Trash" (the default) or "Keep it".
    func finishImport(trash moveToTrash: Bool) {
        guard case .imported = importPhase else { return }
        guard moveToTrash else {
            importPhase = .finished("Kept the old vault. The Homebrew ccpool keeps using it; it and Prosper never share state.")
            return
        }
        do {
            try trash(vaultURL)
            importPhase = .finished("Moved the old vault to the Trash.")
        } catch {
            importPhase = .finished("The old vault could not be moved to the Trash; it is still in place.")
        }
    }

    func dismissImport() { importPhase = .idle }

    /// Lines summarising an import, labels only.
    nonisolated static func summary(_ o: CCPoolMigration.Outcome) -> [String] {
        var lines: [String] = []
        if !o.imported.isEmpty { lines.append("Imported: \(o.imported.joined(separator: ", "))") }
        if !o.replaced.isEmpty { lines.append("Replaced: \(o.replaced.joined(separator: ", "))") }
        if !o.skipped.isEmpty { lines.append("Skipped: \(o.skipped.joined(separator: ", "))") }
        if !o.undecided.isEmpty { lines.append("Already in the pool, left alone: \(o.undecided.joined(separator: ", "))") }
        lines += o.failures.map { "Not imported, \($0)" }
        lines += o.notes
        return lines
    }
}
