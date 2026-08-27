import SwiftUI

/// "Open Settings at this section" channel: a caller posts a `SettingsAnchor`,
/// the `NeonScroll` of the matching pane scrolls to it and `NeonSection` flashes.
/// Idea (env key + overlay + reduce-motion consumption) from vorssaint-utils
/// `UI/Settings/SettingsSectionFocus.swift`; restructured, nothing copied.
@MainActor
final class SettingsFocusRouter: ObservableObject {
    static let shared = SettingsFocusRouter()

    /// Requested but not yet delivered. It is held until the pane that owns it
    /// mounts, which is the whole point: the first request after the window opens
    /// arrives BEFORE any `NeonScroll` exists, so a fire-and-forget signal would be
    /// dropped and the first click would do nothing. `NeonScroll` consumes on
    /// `.onAppear` as well as on change, so a late-mounting pane still gets it.
    @Published private(set) var pending: SettingsAnchor?

    /// Alignment `NeonScroll` should pass to `scrollTo` for `pending` — `.top`
    /// for an explicit jump-to-section request (search result click: always
    /// land the target at the top, even if it was already visible); `nil` for
    /// a minimal-movement request (#078 round 4: arrow-key theme navigation),
    /// which SwiftUI only moves the viewport for when the target isn't already
    /// fully visible.
    private(set) var pendingScrollAnchor: UnitPoint?

    /// The section currently glowing. Cleared after a beat, or by the next request.
    @Published private(set) var focused: SettingsAnchor?

    private var clearTask: Task<Void, Never>?

    func request(_ anchor: SettingsAnchor, scrollAnchor: UnitPoint? = .top) {
        clearTask?.cancel()
        focused = nil
        pendingScrollAnchor = scrollAnchor
        pending = anchor
    }

    /// Takes the pending request if it targets `pane`. A request for a different
    /// pane stays pending — the user may still be switching to it.
    func take(pane: String) -> (anchor: SettingsAnchor, scrollAnchor: UnitPoint?)? {
        guard let pending, pending.pane == pane else { return nil }
        self.pending = nil
        return (pending, pendingScrollAnchor)
    }

    /// Lights the anchor up, then fades it out.
    func highlight(_ anchor: SettingsAnchor, seconds: Double = 2.0) {
        focused = anchor
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.focused = nil
        }
    }
}

private struct SettingsPaneIDKey: EnvironmentKey { static let defaultValue = "" }

extension EnvironmentValues {
    /// Sidebar id of the pane being rendered. Empty outside the Settings window,
    /// which makes the whole focus machinery inert there (no anchors, no `.id`).
    var settingsPaneID: String {
        get { self[SettingsPaneIDKey.self] }
        set { self[SettingsPaneIDKey.self] = newValue }
    }
}
