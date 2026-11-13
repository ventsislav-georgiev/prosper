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
    /// P2b-1 (spec 3.2): starts and stops the proxy with the extension and the account list. nil
    /// for a model built without it (the P2a tests drive the service directly).
    let lifecycle: CCPoolLifecycle?

    @Published var labelDraft = ""
    @Published var tokenDraft = ""
    @Published private(set) var busy = false
    /// Proxy starts, stops and restarts in flight (several events can queue one each).
    @Published private var proxyJobs = 0
    var proxyBusy: Bool { proxyJobs > 0 }
    /// QA #739 INFO-8: whether the old vault exists, checked once per appearance and on Refresh,
    /// never per render.
    @Published private(set) var vaultExists = false
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
         launcherPath: String? = nil, lifecycle: CCPoolLifecycle? = nil) {
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
        self.lifecycle = lifecycle
        store.onChange = Self.republisher(self)
    }

    /// QA #739 INFO-9: a state change made by the proxy (a limit, `current`) or by a hold reaches
    /// the visible pane at once instead of at the next 30 s tick. Formed in a nonisolated static,
    /// so the closure the store calls off main is never @MainActor (errata C7).
    nonisolated static func republisher(_ model: CCPoolPaneModel) -> @Sendable () -> Void {
        { [weak model] in
            guard let model else { return }
            Task { @MainActor in model.objectWillChange.send() }
        }
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
        // QA #739 INFO-11: the service's fixed reason, never a raw system error text.
        case .failed(let why): return "Not running: \(why)"
        }
    }

    var currentText: String { store.snapshot.current ?? "none yet" }

    /// The proxy row's second line: with no account the proxy does not run (spec 3.2).
    var proxySubtitle: String {
        store.hasAccounts ? "Current account: \(currentText)" : "Starts when the first account is added."
    }

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

    /// What the toggle shows (QA #739 F1): off while the pool has no account, the stored choice
    /// otherwise. Turning it never happens while it is disabled, so the stored choice survives.
    var routeToggleShown: Bool { store.hasAccounts && routeAgentSessions }

    var routeDisabledReason: String? {
        if !store.hasAccounts { return "Add an account first." }
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
        if let problem = CCPoolStore.labelProblem(label) { return .failed(problem.description) }
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
            reconcileProxy()   // the first account starts the proxy
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
        // QA #739 INFO-10: one account change at a time; the confirm stays open until it is free.
        guard let label = confirmingRemove, !busy else { return nil }
        confirmingRemove = nil
        busy = true
        let service = service
        return Task.detached { [weak self] in
            let (failure, itemDeleted) = Self.remove(label, service: service)
            await self?.finishRemove(label, failure, itemDeleted: itemDeleted)
        }
    }

    /// `itemDeleted` false: the account is gone but its Keychain item stayed (P2a review carry 1).
    nonisolated static func remove(_ label: String, service: CCPoolService) -> (failure: String?, itemDeleted: Bool) {
        do { return (nil, try service.removeAccount(label: label)) } catch let e as CCPoolStoreError {
            return (e.description, true)
        } catch let e as CCPoolSecretsError {
            return ("ccpool: \(e.description)", true)
        } catch {
            return ("ccpool: \(label) could not be removed", true)
        }
    }

    private func finishRemove(_ label: String, _ failure: String?, itemDeleted: Bool) {
        busy = false
        if failure == nil {
            if selected == label { selected = nil }
            rejected.remove(label)
            unverified.remove(label)
            reconcileProxy()   // the last account stops the proxy
        }
        notice = failure ?? (itemDeleted ? "Removed \(label)."
            : "Removed \(label), but its Keychain item could not be deleted; it stays in the Keychain, listed nowhere.")
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
    /// QA #751 INFO-1: a Refresh reads each token by id before its probe, so one in flight across a
    /// Replace would put the old token's verdict (and benches) on the new one. The two never overlap:
    /// Refresh waits while an import runs, and an import waits while a Refresh runs.
    @discardableResult
    func refreshUsage() -> Task<Void, Never>? {
        guard !importRunning else { return nil }
        refreshing = true
        checkVault()
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

    /// "Restart proxy": a listener restart off the main actor, with the brief bind retry. With a
    /// life cycle it restarts only while the proxy should run (and stops it otherwise).
    @discardableResult
    func restartProxy() -> Task<Void, Never> { proxyTask(restart: true) }

    /// "Start proxy". With a life cycle: start if the extension is live and the pool lists an account.
    @discardableResult
    func startProxy() -> Task<Void, Never> { proxyTask(restart: false) }

    /// P2b-1: re-evaluate the life cycle after an event (the extension turned on or off, an account
    /// added or removed, an import). nil without a life cycle.
    @discardableResult
    func reconcileProxy() -> Task<Void, Never>? {
        lifecycle == nil ? nil : proxyTask(restart: false)
    }

    /// start() blocks on the port probe and the bind (P1 review INFO d): never on main. The work
    /// runs in a detached task and, with a life cycle, on its serial queue.
    private func proxyTask(restart: Bool) -> Task<Void, Never> {
        proxyJobs += 1
        let service = service, lifecycle = lifecycle
        return Task.detached { [weak self] in
            if let lifecycle {
                await lifecycle.settle(restart: restart)
            } else if restart {
                service.restart()
            } else {
                service.start(bindRetry: 3)
            }
            await self?.finishProxy()
        }
    }

    private func finishProxy() { proxyJobs -= 1 }

    // MARK: Actions: import (spec 3.7)

    /// Shown only while there is an old vault, or an import in progress.
    var importVisible: Bool { importPhase != .idle || vaultExists }

    /// One stat of the vault path: on appearance, on Refresh, after the Trash and on Done.
    func checkVault() {
        let exists = FileManager.default.fileExists(atPath: vaultURL.path)
        if exists != vaultExists { vaultExists = exists }
    }

    /// An import is writing the pool (Refresh waits for it, INFO-1).
    var importRunning: Bool {
        if case .review = importPhase { return busy }
        return false
    }

    var canRunImport: Bool {
        guard case .review(let plan) = importPhase, !busy, !refreshing else { return false }
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
        case .success(let o):
            // QA #739 F2: a replaced token is not the old one: its verdict goes (its usage went in run).
            for label in o.imported + o.replaced {
                rejected.remove(label)
                unverified.remove(label)
            }
            importPhase = .imported(o)
            reconcileProxy()   // an import into an empty pool starts the proxy
        case .failure(let e):
            importPhase = .idle
            notice = e.description
        }
    }

    /// Why "Move the old vault to the Trash" is not offered after this import, or nil when it is.
    /// B1: a link is never trashed (that would leave the plaintext it points to); the pane names
    /// the target. B2: an import with failures, or a kept label holding another token, keeps it.
    var trashBlockedReason: String? {
        guard case .imported(let o) = importPhase else { return nil }
        // QA #751 INFO-6 (c): a link with accounts left behind says both.
        let reasons = [o.allHeld ? nil : "Not every account in the old vault is in the pool, so it stays where it is.",
                       o.vaultLink.map(Self.linkReason)].compactMap { $0 }
        return reasons.isEmpty ? nil : reasons.joined(separator: " ")
    }

    /// B1: why a vault that is a link stays. The target is an outside string: shown only after
    /// CCPoolStore.shown drops invisible characters and caps its length (review INFO 2).
    nonisolated static func linkReason(_ target: String) -> String {
        "The old vault is a link to \(CCPoolStore.shown(target)). Prosper moves nothing: delete that file yourself once you no longer need it."
    }

    /// The last step: "Move the old vault to the Trash" (the default) or "Keep it". The Trash runs
    /// off main (QA #739 INFO-8); nil when nothing is left to wait for.
    @discardableResult
    func finishImport(trash moveToTrash: Bool) -> Task<Void, Never>? {
        guard case .imported = importPhase, !busy else { return nil }
        if moveToTrash, let why = trashBlockedReason {
            importPhase = .finished(why)
            return nil
        }
        guard moveToTrash else {
            importPhase = .finished("Kept the old vault. The Homebrew ccpool keeps using it; it and Prosper never share state.")
            return nil
        }
        busy = true
        let vault = vaultURL, trash = trash, store = store, secrets = secrets
        return Task.detached { [weak self] in
            let text = Self.trashVault(vault, store: store, secrets: secrets, trash: trash)
            await self?.finishTrash(text)
        }
    }

    nonisolated static let trashChangedReason = "The old vault changed after the import, so Prosper moved nothing; it stays where it is."

    /// Review INFO 1 + QA #751 INFO-6: decided again at the click, since the vault may have changed
    /// since the import read it. Only a regular file (not a link) with one name (a hard link would
    /// keep the plaintext under the other) whose every account the pool holds goes to the Trash.
    /// Blocking file I/O and Keychain reads: off main.
    nonisolated static func trashVault(_ vault: URL, store: CCPoolStore, secrets: CCPoolSecrets,
                                       trash: CCPoolMigration.Trash) -> String {
        var st = stat()
        guard lstat(vault.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_nlink == 1,
              CCPoolMigration.allHeld(vault: vault, store: store, secrets: secrets) else { return trashChangedReason }
        do {
            try trash(vault)
            return "Moved the old vault to the Trash."
        } catch {
            return "The old vault could not be moved to the Trash; it is still in place."
        }
    }

    private func finishTrash(_ text: String) {
        busy = false
        importPhase = .finished(text)
        checkVault()
    }

    func dismissImport() {
        importPhase = .idle
        checkVault()
    }

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
