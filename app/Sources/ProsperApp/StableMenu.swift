import SwiftUI

/// #1540 (#1466 made general): a SwiftUI Menu whose parent redraws on a periodic publish (the agent store about every
/// second, the stats sampler, a download's progress) rebuilds its content on each redraw, and that closes an open
/// submenu about a second after it opens. A StableMenu draws from an Equatable snapshot (`entries`) held in a model
/// that publishes only on a real change, so a parent's equal redraw leaves the open menu alone.
/// The rules for a caller: everything the menu and its label draw comes from `entries`; every action goes through the
/// `run` handed to `content` (it calls the newest `run` the parent passed, never one kept from an older draw).
/// StableMenuGuardTests fails on a SwiftUI Menu built anywhere else that is not on its literal allow-list.
struct StableMenu<Entries: Equatable, Verb, Content: View, MenuLabel: View>: View {
    let entries: Entries
    let run: (Verb) -> Void
    @StateObject private var model: StableMenuModel<Entries, Verb, Content, MenuLabel>
    private let content: (Entries, @escaping (Verb) -> Void) -> Content
    private let label: (Entries) -> MenuLabel

    /// `id`: the menu's name for the StableMenuProbe.bodies test seam.
    init(_ id: String, entries: Entries, run: @escaping (Verb) -> Void,
         @ViewBuilder content: @escaping (Entries, @escaping (Verb) -> Void) -> Content,
         @ViewBuilder label: @escaping (Entries) -> MenuLabel) {
        self.entries = entries
        self.run = run
        self.content = content
        self.label = label
        _model = StateObject(wrappedValue: StableMenuModel(id, entries, content: content, label: label))
    }

    var body: some View {
        // Not published: the newest closures, no redraw.
        let _ = model.take(run: run, content: content, label: label)
        StableMenuBody(model: model)
            .onChange(of: entries) { _, e in model.show(e) }
    }
}

/// What a StableMenu draws; publishes only on a real change of its entries.
@MainActor
final class StableMenuModel<Entries: Equatable, Verb, Content: View, MenuLabel: View>: ObservableObject {
    let id: String
    private(set) var entries: Entries
    private var run: (Verb) -> Void = { _ in }
    private(set) var content: (Entries, @escaping (Verb) -> Void) -> Content
    private(set) var label: (Entries) -> MenuLabel

    init(_ id: String, _ entries: Entries, content: @escaping (Entries, @escaping (Verb) -> Void) -> Content,
         label: @escaping (Entries) -> MenuLabel) {
        self.id = id
        self.entries = entries
        self.content = content
        self.label = label
    }

    func take(run: @escaping (Verb) -> Void, content: @escaping (Entries, @escaping (Verb) -> Void) -> Content,
              label: @escaping (Entries) -> MenuLabel) {
        self.run = run
        self.content = content
        self.label = label
    }

    func show(_ e: Entries) {
        guard e != entries else { return }
        objectWillChange.send()
        entries = e
    }

    /// What a menu item calls: the newest `run`.
    func send(_ v: Verb) { run(v) }
}

/// The Menu itself. It holds only its model, so a parent's redraw (a poll tick) leaves it alone.
struct StableMenuBody<Entries: Equatable, Verb, Content: View, MenuLabel: View>: View {
    @ObservedObject var model: StableMenuModel<Entries, Verb, Content, MenuLabel>

    var body: some View {
        let _ = StableMenuProbe.bodies[model.id, default: 0] += 1
        let m = model
        Menu {
            m.content(m.entries, { m.send($0) })
        } label: {
            m.label(m.entries)
        }
    }
}

/// Test seam: how many times each StableMenu's Menu body ran, by its id.
enum StableMenuProbe {
    @MainActor static var bodies: [String: Int] = [:]
}
