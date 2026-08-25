// Native settings footer for the Mouse extension (merged below the manifest's
// Permissions section, same pattern as CalendarPane/MenuBarPane). One exception
// list per `MouseScope`: the extension manifest's TOML control kinds have no
// app-list kind, so this editor is native. Every edit writes through to
// Preferences and reloads `MouseExceptions` so the live taps see it at once.

import SwiftUI

struct MousePane: View {
    @State private var lists: [MouseScope: [String]] = [:]
    @State private var invertV = Preferences.mouseScrollInvertVertical
    @State private var invertH = Preferences.mouseScrollInvertHorizontal
    @State private var sideButtons = Preferences.mouseSideButtonNavigation

    var body: some View {
        Group {
            NeonSection("Scroll direction",
                        footer: "Mouse wheels only \u{2014} a trackpad keeps whatever direction System Settings gives it.") {
                Toggle("Invert vertical scrolling", isOn: $invertV)
                    .onChange(of: invertV) { _, v in
                        Preferences.mouseScrollInvertVertical = v
                        ScrollInvertController.shared.reconcile()
                    }
                NeonDivider()
                Toggle("Invert horizontal scrolling", isOn: $invertH)
                    .onChange(of: invertH) { _, v in
                        Preferences.mouseScrollInvertHorizontal = v
                        ScrollInvertController.shared.reconcile()
                    }
            }
            NeonSection("Side buttons",
                        footer: "The thumb buttons send \u{2318}[ and \u{2318}] to the frontmost app \u{2014} Back and Forward in browsers, and in anything else that takes those shortcuts.") {
                Toggle("Back / Forward on the side buttons", isOn: $sideButtons)
                    .onChange(of: sideButtons) { _, v in
                        Preferences.mouseSideButtonNavigation = v
                        MouseNavigationController.shared.reconcile()
                    }
            }
            ForEach(MouseScope.allCases, id: \.self) { scope in
                NeonSection("\(scope.title) exceptions", footer: footer(scope)) {
                    bundleList(lists[scope] ?? []) { remove($0, from: scope) }
                    NeonDivider()
                    AppPickerMenu(
                        selected: Set(lists[scope] ?? []),
                        multiSelect: true,
                        label: "Add App\u{2026}",
                        help: "Leave these apps alone",
                        onPick: { id, _ in toggle(id, in: scope) },
                        onClear: { write([], to: scope) })
                }
            }
        }
        .onAppear(perform: load)
    }

    private func footer(_ scope: MouseScope) -> String {
        switch scope {
        case .scrollInvert:
            return "Scrolling in these apps is left exactly as macOS delivers it \u{2014} the window under the pointer decides."
        case .navigation:
            return "The side buttons keep their normal behavior in these apps \u{2014} whichever app is frontmost decides."
        }
    }

    private func load() {
        for scope in MouseScope.allCases { lists[scope] = Preferences.mouseExceptions(scope) }
    }

    private func toggle(_ id: String, in scope: MouseScope) {
        var ids = lists[scope] ?? []
        if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) }
        write(ids, to: scope)
    }

    private func remove(_ id: String, from scope: MouseScope) {
        write((lists[scope] ?? []).filter { $0 != id }, to: scope)
    }

    private func write(_ ids: [String], to scope: MouseScope) {
        let sorted = ids.sorted()
        lists[scope] = sorted
        Preferences.setMouseExceptions(sorted, for: scope)
        MouseExceptions.shared.reload()
    }
}
