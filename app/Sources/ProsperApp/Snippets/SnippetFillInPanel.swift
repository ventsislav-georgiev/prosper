import AppKit
import SwiftUI

/// #842: the `{argument}` fill-in form's state: one value per field, prefilled with
/// its default. Finishes once: submit hands back the values by name, cancel nil.
@MainActor
final class SnippetFillInModel: ObservableObject {
    let title: String
    let fields: [ArgumentSpec]
    @Published var values: [String]
    private var finish: (@MainActor ([String: String]?) -> Void)?

    init(title: String, fields: [ArgumentSpec], finish: @escaping @MainActor ([String: String]?) -> Void) {
        self.title = title
        self.fields = fields
        self.values = fields.map { $0.defaultValue ?? "" }
        self.finish = finish
    }

    /// A required (default-less) field left empty holds the submit back.
    var canSubmit: Bool {
        !zip(fields, values).contains { field, value in field.required && value.isEmpty }
    }

    func submit() {
        guard canSubmit else { return }
        done(Dictionary(zip(fields.map(\.name), values), uniquingKeysWith: { first, _ in first }))
    }

    func cancel() { done(nil) }

    private func done(_ result: [String: String]?) {
        let finish = self.finish
        self.finish = nil
        finish?(result)
    }
}

/// One text field per argument; Return submits, Escape cancels, Tab moves on.
struct SnippetFillInView: View {
    @ObservedObject var model: SnippetFillInModel
    @FocusState private var focused: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.title).font(.headline).lineLimit(1)
            ForEach(model.fields.indices, id: \.self) { i in
                HStack {
                    Text(model.fields[i].name)
                        .frame(width: 100, alignment: .trailing)
                        .lineLimit(1)
                    TextField(model.fields[i].name, text: $model.values[i],
                              prompt: Text(model.fields[i].required ? "Required" : ""))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: i)
                        .onSubmit { model.submit() }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Insert") { model.submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSubmit)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { focused = 0 }
    }
}

/// The one fill-in panel. A newer prompt cancels an open one.
@MainActor
final class SnippetFillInPanel {
    static let shared = SnippetFillInPanel()
    private var panel: NSPanel?
    private var model: SnippetFillInModel?

    func present(title: String, fields: [ArgumentSpec], done: @escaping @MainActor ([String: String]?) -> Void) {
        model?.cancel()
        let model = SnippetFillInModel(title: title, fields: fields) { [weak self] values in
            self?.close()
            done(values)
        }
        let panel = Self.makePanel(model)
        self.model = model
        self.panel = panel
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Built apart from `present` so tests get the panel without ordering it front.
    static func makePanel(_ model: SnippetFillInModel) -> KeyablePanel {
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Snippet"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SnippetFillInView(model: model))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        return panel
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }
}
