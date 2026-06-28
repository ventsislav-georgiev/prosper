import Foundation

/// Pure decision for the one-time legacy-label migration (`.lidhelper` → `.helper`).
/// The orchestration (SMAppService unregister/register, UserDefaults, the modal) is
/// I/O and lives in `LidSleepHelper`; THIS is the safety-critical branching that a
/// review pass found two bugs in (flag set before a successful re-pin → permanent
/// strand; cache not restored on success). Pure → unit-testable with no root/IPC.
public enum HelperMigration {
    /// Outcome of attempting to register the new-label daemon item.
    public enum RegisterResult: Equatable { case enabled, needsApproval, failed }

    /// What the caller must do after (optionally) re-pinning the new label.
    public struct Plan: Equatable {
        /// storeCache(this) if non-nil — keep the residency flag truthful post-migrate.
        public var cacheEnabled: Bool?
        /// Surface the Login-Items approval modal (new label needs re-approval).
        public var showApprovalModal: Bool
        /// Persist the one-shot migrated flag. FALSE on a failed re-pin so the next
        /// launch retries rather than stranding the user mid-migration.
        public var markMigrated: Bool
        public init(cacheEnabled: Bool?, showApprovalModal: Bool, markMigrated: Bool) {
            self.cacheEnabled = cacheEnabled
            self.showApprovalModal = showApprovalModal
            self.markMigrated = markMigrated
        }
    }

    /// `wasEnabled`: was lid-sleep on under the legacy label (snapshot BEFORE any
    /// refresh can clobber the cache). `result`: the new-label register outcome, or
    /// nil when no re-pin was attempted (because `wasEnabled` was false).
    public static func plan(wasEnabled: Bool, result: RegisterResult?) -> Plan {
        // Nothing was pinned → nothing to re-pin; migration is simply done.
        guard wasEnabled else {
            return Plan(cacheEnabled: nil, showApprovalModal: false, markMigrated: true)
        }
        switch result {
        case .enabled:
            return Plan(cacheEnabled: true, showApprovalModal: false, markMigrated: true)
        case .needsApproval:
            return Plan(cacheEnabled: false, showApprovalModal: true, markMigrated: true)
        case .failed, .none:
            // Re-pin failed (or wasn't attempted despite wasEnabled) → retry next launch.
            return Plan(cacheEnabled: nil, showApprovalModal: false, markMigrated: false)
        }
    }
}
