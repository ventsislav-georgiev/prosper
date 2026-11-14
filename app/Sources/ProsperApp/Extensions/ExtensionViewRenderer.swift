import AppKit
import SwiftUI

/// Renders an `ExtensionViewNode` tree as native SwiftUI. The extension supplies
/// structure only; every pixel here is the host's, so all extensions share one
/// consistent, fast, native look (ADR-002 §D7). Actions bubble out through
/// `onAction`, which the host routes back into the extension's action handler.
struct ExtensionRenderedView: View {
    let node: ExtensionViewNode
    /// (actionID, value, formValues) → host dispatches to the extension.
    let onAction: (_ id: String, _ value: String?, _ formValues: [String: String]) -> Void
    /// (fnName, input) → output transform, used by `converter` panes for live
    /// bidirectional conversion. Supplied for `host.window.open` windows; nil
    /// elsewhere (the inline runner never hosts a converter).
    var transform: ConverterPanes.Transform? = nil

    var body: some View {
        content
            // Same neon backdrop as Settings / the floating panels so every
            // extension window shares the design system.
            .background(SettingsBackground().ignoresSafeArea())
            .tint(Neon.blue)
    }

    @ViewBuilder
    private var content: some View {
        // Loading is full-bleed and centered (its title sits with the spinner),
        // so it skips the leading headline the other components share. Converter
        // is also full-bleed (it owns its own header row + split layout).
        switch node {
        case .loading(let n):
            LoadingRender(node: n)
        case .converter(let n):
            ConverterRender(node: n, transform: transform ?? { _, s in s })
        default:
            VStack(alignment: .leading, spacing: 0) {
                if let title = node.title {
                    Text(title)
                        .font(Neon.font(11, weight: .bold))
                        .textCase(.uppercase)
                        .tracking(1.2)
                        .foregroundColor(Neon.textSecondary)
                        .padding(.horizontal, sz(16))
                        .padding(.top, sz(14))
                }
                switch node {
                case .list(let n):   ListRender(node: n, onAction: onAction)
                case .detail(let n): DetailRender(node: n, onAction: onAction)
                case .form(let n):   FormRender(node: n, onAction: onAction)
                case .grid(let n):   GridRender(node: n, onAction: onAction)
                case .loading, .converter: EmptyView()  // handled above
                }
            }
        }
    }
}

// MARK: - Loading (Apple-style: infinite spinner or progressive bar)

private struct LoadingRender: View {
    let node: LoadingNode

    var body: some View {
        VStack(spacing: sz(14)) {
            if let p = node.clampedProgress {
                // Progressive / determinate.
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                    .tint(Neon.blue)
                    .frame(width: sz(240))
                    .animation(.easeInOut(duration: 0.25), value: p)
                Text("\(Int((p * 100).rounded()))%")
                    .font(Neon.font(.caption, design: .rounded).monospacedDigit())
                    .foregroundColor(Neon.textSecondary)
            } else {
                // Infinite / indeterminate.
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                    .tint(Neon.blue)
            }
            if let title = node.title {
                Text(title).font(Neon.font(.headline)).foregroundColor(Neon.textPrimary)
            }
            if let sub = node.subtitle {
                Text(sub)
                    .font(Neon.font(.subheadline))
                    .foregroundColor(Neon.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(sz(32))
        .transition(.opacity)
    }
}

// MARK: - List

private struct ListRender: View {
    let node: ListNode
    let onAction: (String, String?, [String: String]) -> Void
    @State private var query = ""

    private var items: [ListItem] {
        guard node.isSearchable, !query.isEmpty else { return node.items }
        let q = query.lowercased()
        return node.items.filter {
            $0.title.lowercased().contains(q) || ($0.subtitle?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if node.isSearchable {
                HStack(spacing: sz(8)) {
                    Image(systemName: "magnifyingglass")
                        .font(Neon.font(12))
                        .foregroundColor(Neon.blue)
                    TextField("Search…", text: $query)
                        .textFieldStyle(.plain)
                        .foregroundColor(Neon.textPrimary)
                }
                .padding(.horizontal, sz(10))
                .padding(.vertical, sz(7))
                .background(
                    RoundedRectangle(cornerRadius: sz(8), style: .continuous)
                        .fill(Neon.card)
                        .overlay(
                            RoundedRectangle(cornerRadius: sz(8), style: .continuous)
                                .strokeBorder(Neon.stroke, lineWidth: 1)))
                .padding(sz(12))
            }
            List(items) { item in
                HStack(spacing: sz(8)) {
                    if let icon = item.icon { Image(systemName: icon).foregroundColor(Neon.blue) }
                    VStack(alignment: .leading, spacing: sz(2)) {
                        Text(item.title).foregroundColor(Neon.textPrimary)
                        if let sub = item.subtitle {
                            Text(sub).font(Neon.font(.caption)).foregroundColor(Neon.textSecondary)
                        }
                    }
                    Spacer()
                    if let acc = item.accessory {
                        Text(acc).font(Neon.font(.caption)).foregroundColor(Neon.textSecondary)
                    }
                    ForEach(item.allActions) { action in
                        Button(action.title) { onAction(action.id, action.value ?? item.id, [:]) }
                            .buttonStyle(.borderless)
                            .foregroundColor(Neon.blueBright)
                    }
                }
                .listRowBackground(Color.clear)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let primary = item.allActions.first {
                        onAction(primary.id, primary.value ?? item.id, [:])
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}

// MARK: - Detail

private struct DetailRender: View {
    let node: DetailNode
    let onAction: (String, String?, [String: String]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: sz(12)) {
            ScrollView {
                Text(markdown)
                    .foregroundColor(Neon.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(sz(12))
            }
            if !node.allActions.isEmpty {
                ActionBar(actions: node.allActions) { id, value in onAction(id, value, [:]) }
            }
        }
    }

    /// Native markdown rendering (falls back to plain text on parse failure).
    private var markdown: AttributedString {
        (try? AttributedString(
            markdown: node.markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(node.markdown)
    }
}

// MARK: - Grid

private struct GridRender: View {
    let node: GridNode
    let onAction: (String, String?, [String: String]) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: node.columnCount), spacing: sz(12)) {
                ForEach(node.items) { item in
                    VStack(spacing: sz(6)) {
                        if let icon = item.icon {
                            Image(systemName: icon)
                                .font(Neon.font(28))
                                .foregroundColor(Neon.blue)
                                .shadow(color: Neon.blue.opacity(0.5), radius: sz(6))
                        }
                        Text(item.title)
                            .font(Neon.font(.caption))
                            .foregroundColor(Neon.textPrimary)
                            .multilineTextAlignment(.center)
                        if let sub = item.subtitle {
                            Text(sub).font(Neon.font(.caption2)).foregroundColor(Neon.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(sz(8))
                    .background(
                        RoundedRectangle(cornerRadius: sz(8), style: .continuous)
                            .fill(Neon.card)
                            .overlay(
                                RoundedRectangle(cornerRadius: sz(8), style: .continuous)
                                    .strokeBorder(Neon.stroke, lineWidth: 1)))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let primary = item.allActions.first {
                            onAction(primary.id, primary.value ?? item.id, [:])
                        }
                    }
                }
            }
            .padding(sz(12))
        }
    }
}

// MARK: - Form

private struct FormRender: View {
    let node: FormNode
    let onAction: (String, String?, [String: String]) -> Void
    @State private var values: [String: String] = [:]
    @FocusState private var focusedField: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: sz(14)) {
                    ForEach(node.fields) { field in
                        fieldView(field)
                    }
                }
                .padding(sz(16))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Return anywhere in the form submits via the first (primary) action.
            .onSubmit {
                if let primary = node.allActions.first {
                    onAction(primary.id, primary.value, values)
                }
            }
            if !node.allActions.isEmpty {
                ActionBar(actions: node.allActions) { id, value in onAction(id, value, values) }
            }
        }
        .onAppear {
            for f in node.fields where values[f.id] == nil { values[f.id] = f.defaultValue }
            assertInitialFocus()
        }
    }

    /// Focus the first field so the form is immediately typeable; Tab then
    /// walks the fields. The focus system isn't ready synchronously on first
    /// appearance — and on a cold start the window may not even be key on the
    /// first try, which silently drops the assignment (the wrapped value stays
    /// nil). Re-assert until it sticks, but never steal focus the user (or a
    /// previous successful attempt) already placed.
    private func assertInitialFocus(attempt: Int = 0) {
        guard attempt < 10 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard focusedField == nil else { return }
            focusedField = node.fields.first?.id
            assertInitialFocus(attempt: attempt + 1)
        }
    }

    @ViewBuilder
    private func fieldView(_ field: FormField) -> some View {
        let binding = Binding<String>(
            get: { values[field.id] ?? field.defaultValue },
            set: { values[field.id] = $0 })
        switch field.kind {
        case .text, .number:
            labeledField(field.label) {
                TextField("", text: binding, prompt: prompt(field))
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: field.id)
                    .foregroundColor(Neon.textPrimary)
                    .neonFieldChrome()
            }
        case .textarea:
            labeledField(field.label) {
                TextEditor(text: binding)
                    .scrollContentBackground(.hidden)
                    .font(Neon.font(13, design: .monospaced))
                    .frame(minHeight: sz(84))
                    .focused($focusedField, equals: field.id)
                    .foregroundColor(Neon.textPrimary)
                    .neonFieldChrome()
            }
        case .password:
            labeledField(field.label) {
                SecureField("", text: binding, prompt: prompt(field))
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: field.id)
                    .foregroundColor(Neon.textPrimary)
                    .neonFieldChrome()
            }
        case .toggle:
            HStack {
                Text(field.label)
                    .font(Neon.font(13))
                    .foregroundColor(Neon.textPrimary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { (values[field.id] ?? field.defaultValue) == "true" },
                    set: { values[field.id] = $0 ? "true" : "false" }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Neon.blue)
            }
            .neonFieldChrome()
        case .dropdown:
            labeledField(field.label) {
                Picker("", selection: binding) {
                    ForEach(field.allOptions, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(Neon.blue)
                .neonFieldChrome()
            }
        }
    }

    private func prompt(_ field: FormField) -> Text? {
        field.placeholder.map {
            Text($0).foregroundColor(Neon.textSecondary.opacity(0.55))
        }
    }

    /// Converter-style uppercase tracked label above the input control.
    private func labeledField<C: View>(_ label: String, @ViewBuilder control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: sz(6)) {
            Text(label.uppercased())
                .font(Neon.font(10, weight: .semibold, design: .rounded))
                .tracking(0.8)
                .foregroundColor(Neon.blueBright.opacity(0.85))
            control()
        }
    }
}

/// Shared input chrome for extension form controls: dark card fill + neon
/// hairline, matching the Settings inputs.
private struct NeonFieldChrome: ViewModifier {
    // Same #089 defect as `NeonCardModifier`: a property-less ViewModifier's body
    // is memoized on its (unchanging) value, so these `Neon.*` reads froze at the
    // palette that was live when the field first rendered. Observe the store.
    @ObservedObject private var theme = ThemeStore.shared
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, sz(10))
            .padding(.vertical, sz(8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: sz(8), style: .continuous)
                    .fill(Neon.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: sz(8), style: .continuous)
                            .strokeBorder(Neon.stroke, lineWidth: 1)))
    }
}

private extension View {
    func neonFieldChrome() -> some View { modifier(NeonFieldChrome()) }
}

// MARK: - Converter (live bidirectional two-pane transform)

/// #1146: the converter's two panes and its ordering rule, apart from SwiftUI so rows drive it. Main actor: the
/// view reads and edits it on main, and each answer is applied on main after its transform returns.
@MainActor
final class ConverterPanes: ObservableObject {
    /// (fnName, input) → output, called on the main actor; the live one awaits the extension's background lane.
    typealias Transform = @MainActor (_ fnName: String, _ input: String) async -> String

    @Published private(set) var left: String
    @Published private(set) var right: String
    private let forward: String, backward: String
    private let transform: Transform
    /// Number of the newest edit (either side); an answer to an older one is dropped.
    private var latest = 0
    private var seeded = false

    init(node: ConverterNode, transform: @escaping Transform) {
        left = node.left.value ?? ""
        right = node.right.value ?? ""
        forward = node.forward
        backward = node.backward
        self.transform = transform
    }

    /// Once, on appear: derive the right pane when only the left is given, so the window opens converted.
    @discardableResult
    func seed() -> Task<Void, Never>? {
        guard !seeded else { return nil }
        seeded = true
        return right.isEmpty && !left.isEmpty ? convert(fromLeft: true) : nil
    }

    /// A user edit (the pane's binding). An answer is written past this, and a set to the text a pane already
    /// holds is no edit, so writing the answer into the other pane does not echo back.
    @discardableResult
    func edit(left isLeft: Bool, _ text: String) -> Task<Void, Never>? {
        guard text != (isLeft ? left : right) else { return nil }
        if isLeft { left = text } else { right = text }
        return convert(fromLeft: isLeft)
    }

    /// Latest edit wins: the answer lands only if no edit on either side came after the one it answers. A cut
    /// or failed transform answers "" (the other pane empties).
    private func convert(fromLeft: Bool) -> Task<Void, Never> {
        latest += 1
        let mine = latest, input = fromLeft ? left : right, fn = fromLeft ? forward : backward
        return Task { @MainActor in   // main actor: reads and writes the panes
            let out = await transform(fn, input)
            guard mine == latest else { return }
            if fromLeft { right = out } else { left = out }
        }
    }
}

private struct ConverterRender: View {
    let node: ConverterNode
    @StateObject private var panes: ConverterPanes

    init(node: ConverterNode, transform: @escaping ConverterPanes.Transform) {
        self.node = node
        _panes = StateObject(wrappedValue: ConverterPanes(node: node, transform: transform))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            pane(label: node.left.label ?? "Input",
                 placeholder: node.left.placeholder,
                 text: Binding(get: { panes.left }, set: { panes.edit(left: true, $0) }))
            Rectangle()
                .fill(Neon.stroke)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
            pane(label: node.right.label ?? "Output",
                 placeholder: node.right.placeholder,
                 text: Binding(get: { panes.right }, set: { panes.edit(left: false, $0) }))
        }
        .frame(minWidth: sz(480), maxWidth: .infinity, minHeight: sz(280), maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Neon.bgTop, Neon.bgBottom],
                           startPoint: .top, endPoint: .bottom))
        .onAppear { panes.seed() }
    }

    @ViewBuilder
    private func pane(label: String, placeholder: String?, text: Binding<String>) -> some View {
        let editorFont: Font = node.isMonospaced ? .system(.body, design: .monospaced) : .body
        VStack(alignment: .leading, spacing: sz(6)) {
            Text(label.uppercased())
                .font(Neon.font(10, weight: .semibold, design: .rounded))
                .tracking(0.8)
                .foregroundColor(Neon.blueBright.opacity(0.85))
                .padding(.horizontal, sz(14))
                .padding(.top, sz(12))
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty, let placeholder {
                    Text(placeholder)
                        .font(editorFont)
                        .foregroundColor(Neon.textSecondary.opacity(0.55))
                        // Match the TextEditor's text origin: its own 8/10 padding
                        // PLUS the NSTextView's ~5pt internal text-container inset,
                        // so the placeholder sits exactly under the caret.
                        .padding(.vertical, sz(8))
                        .padding(.horizontal, sz(10))
                        .padding(.leading, sz(5))
                        .allowsHitTesting(false)
                }
                TextEditor(text: text)
                    .font(editorFont)
                    .foregroundColor(Neon.textPrimary)
                    .tint(Neon.blue)
                    .scrollContentBackground(.hidden)
                    .padding(.vertical, sz(8))
                    .padding(.horizontal, sz(10))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Shared action bar

private struct ActionBar: View {
    let actions: [ExtensionAction]
    let fire: (String, String?) -> Void

    var body: some View {
        HStack {
            Spacer()
            ForEach(actions) { action in
                Button {
                    fire(action.id, action.value)
                } label: {
                    if let icon = action.icon { Label(action.title, systemImage: icon) }
                    else { Text(action.title) }
                }
                .buttonStyle(.neon)
            }
        }
        .padding(sz(12))
        .background(Neon.bgBottom.opacity(0.55))
        .overlay(alignment: .top) {
            Rectangle().fill(Neon.stroke).frame(height: 1)
        }
    }
}

/// NSWindow for extension-hosted UI that closes on ⌘W and Escape. As a menu-bar
/// agent (LSUIElement) Prosper has no File ▸ Close menu, so ⌘W never reaches the
/// window — we handle it ourselves; Escape closes the window like a sheet/dialog.
/// `performClose` honors `isReleasedWhenClosed = false`, so the window is reused.
private final class ExtensionWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Match ⌘W by keycode (kVK_ANSI_W = 13), layout-independent: under a non-Latin
        // layout charactersIgnoringModifiers is the layout glyph, not "w".
        if event.modifierFlags.contains(.command),
           event.keyCode == 13 || event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }
}

/// Floating panel that hosts a rendered extension view for `mode = "view"`
/// commands. Action dispatch is supplied by the registry.
@MainActor
final class ExtensionViewPanel {
    private(set) var window: NSWindow?
    /// #1113: the extension whose view the window holds, nil once it closes (either way: the close
    /// button or host.window.close). A hotkey on that extension's window command toggles the window.
    private(set) var owner: String?
    /// #1123: what a shortcut asked for: the extension, the command and the text its handler got, compared whole.
    struct Identity: Equatable, Sendable {
        let extensionID: String
        let commandID: String
        let text: String
    }
    /// #1123: the shortcut press whose view the window holds; nil when nothing named it (the runner, or the
    /// extension opening a window by itself), cleared with the owner.
    private(set) var identity: Identity?
    /// #1123: set by ExtensionShortcuts.toggleWindow right before it fires; the next present takes it when its
    /// extension matches (the handler presents during the invoke the fire starts) and drops it either way; pressEnded drops one no present took once that invoke has ended.
    var pending: Identity?
    private var closeObserver: NSObjectProtocol?

    /// #1123: the invoke a press started has ended (main actor, from the press's fire Task after its await). The
    /// handler presents during that invoke, so a pending identity still equal to this press's was taken by no
    /// present and goes: a view the extension opens after this is the extension acting by itself and is named
    /// after no press (the 1113 rule applies to it; a re-present into its own open window keeps that view's
    /// identity). A later press's pending, another identity, stays. shortcut: two presses of ONE shortcut in
    /// flight share one value, so the first to end clears both; a press number would tell them apart.
    func pressEnded(_ pressed: Identity?) {
        if let pressed, pending == pressed { pending = nil }
    }

    /// The on-screen calls, a seam (#1113): a test must not order the window front or make it key.
    var onScreen: (NSWindow) -> Void = { win in
        DockPolicy.windowDidShow(win)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func present(
        owner: String? = nil,
        node: ExtensionViewNode,
        transform: ConverterPanes.Transform? = nil,
        onAction: @escaping (_ id: String, _ value: String?, _ formValues: [String: String]) async -> ExtensionViewNode?
    ) {
        let controller = ExtensionViewHostController(node: node, transform: transform, onAction: onAction)
        let win = window ?? ExtensionWindow(contentViewController: controller)
        // Set the content controller BEFORE sizing. On a reused window, assigning
        // contentViewController re-fits the frame to the hosting view's intrinsic
        // size — doing it after setContentSize collapsed the window to its minimum.
        win.contentViewController = controller
        win.title = node.title ?? "Extension"
        win.styleMask = [.titled, .closable, .resizable]
        // Same neon-console titlebar treatment as the Settings window: hide the
        // title, make the titlebar transparent, and paint the frame in the backdrop's
        // top color so the bar dissolves into the UI.
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.backgroundColor = NSColor(Neon.bgTop)
        // Inherit the app appearance (set by ThemeStore from the active theme)
        // instead of hardcoding dark — so a light theme gets light chrome and a
        // live switch flips this window for free via NSApp.appearance.
        // A converter is a side-by-side split, so it wants a wider canvas than the
        // single-column list / detail / form views.
        let size: NSSize = {
            if case .converter = node { return NSSize(width: 720, height: 420) }
            if case .form(let n) = node {
                // Title + action bar plus ~52pt per field, clamped so a long
                // form scrolls rather than producing a screen-tall dialog.
                return NSSize(width: 520, height: min(520, 200 + 52 * n.fields.count))
            }
            return NSSize(width: 520, height: 460)
        }()
        win.minSize = NSSize(width: 520, height: 300)
        win.setContentSize(size)
        win.isReleasedWhenClosed = false
        win.centerOnScreen()
        if window == nil {
            window = win
            // Closes via the title-bar button (willClose); show the Dock icon while
            // the extension window is up and hide it again when it's dismissed.
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: win, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.owner = nil
                    self?.identity = nil
                    DockPolicy.windowDidHide(win)
                }
            }
        }
        // #1123: the press that fired names the view; the same extension re-presenting into its open window keeps it.
        identity = pending?.extensionID == owner ? pending : (owner == self.owner ? identity : nil)
        pending = nil
        self.owner = owner
        onScreen(win)
    }

    /// #1113: WindowToggle's focus: the window back in front with the view the user left, no re-render.
    func focus() {
        if let window { onScreen(window) }
    }

    /// Dismiss the open window (host.window.close). Posts willClose, so the Dock
    /// policy observer hides the icon; the window is reused on the next present().
    func close() {
        window?.close()
    }
}

/// Hosts the SwiftUI tree and re-renders when an action returns a new node
/// (intra-extension navigation: list → detail, form → result, …).
@MainActor
final class ExtensionViewHostController: NSHostingController<AnyView> {
    private var current: ExtensionViewNode
    private let onAction: (String, String?, [String: String]) async -> ExtensionViewNode?
    /// Internal (not private) so a row calls the transform the presenter handed in.
    let transform: ConverterPanes.Transform?
    private var pending: Task<Void, Never>?

    init(
        node: ExtensionViewNode,
        transform: ConverterPanes.Transform? = nil,
        onAction: @escaping (String, String?, [String: String]) async -> ExtensionViewNode?
    ) {
        self.current = node
        self.transform = transform
        self.onAction = onAction
        super.init(rootView: AnyView(EmptyView()))
        // Don't let the hosting controller drive the window size from the SwiftUI
        // intrinsic content size — the host owns the frame (setContentSize). Without
        // this the window snaps to the view's minimum and "collapses".
        sizingOptions = []
        rebuild()
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    private func rebuild() {
        // Copy into locals so the stored rootView closure captures no strong self
        // (only the onAction weakly) — otherwise controller → rootView → closure →
        // self is a retain cycle. Themed{} re-skins the rendered UI on a live switch.
        let node = current
        let transform = transform
        rootView = AnyView(Themed {
            ExtensionRenderedView(
                node: node,
                onAction: { [weak self] id, value, form in self?.fire(id, value, form) },
                transform: transform)
        })
    }

    /// Run an action: show a built-in spinner immediately (so any async work —
    /// http, llm, shell — gets a beautiful loading state for free), then swap in
    /// the node the handler returns. A newer action cancels an in-flight one.
    private func fire(_ id: String, _ value: String?, _ form: [String: String]) {
        pending?.cancel()
        let keepTitle = current.title
        withAnimation(.easeInOut(duration: 0.15)) {
            current = .spinner(keepTitle, subtitle: "Working…")
        }
        rebuild()
        pending = Task { @MainActor [weak self] in
            guard let self else { return }
            let next = await self.onAction(id, value, form)
            if Task.isCancelled { return }
            if let next {
                withAnimation(.easeInOut(duration: 0.2)) { self.current = next }
                self.rebuild()
            }
        }
    }
}
