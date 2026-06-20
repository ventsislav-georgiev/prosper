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
    /// Synchronous (fnName, input) → output transform, used by `converter` panes
    /// for live bidirectional conversion. Supplied for `host.window.open` windows;
    /// nil elsewhere (the inline runner never hosts a converter).
    var transform: ((_ fnName: String, _ input: String) -> String)? = nil

    var body: some View {
        content
            // Same neon backdrop as Settings / the floating panels so every
            // extension window shares the design system.
            .background(SettingsBackground().ignoresSafeArea())
            .preferredColorScheme(.dark)
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
                        .font(.system(size: 11, weight: .bold))
                        .textCase(.uppercase)
                        .tracking(1.2)
                        .foregroundColor(Neon.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
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
        VStack(spacing: 14) {
            if let p = node.clampedProgress {
                // Progressive / determinate.
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                    .tint(Neon.blue)
                    .frame(width: 240)
                    .animation(.easeInOut(duration: 0.25), value: p)
                Text("\(Int((p * 100).rounded()))%")
                    .font(.system(.caption, design: .rounded).monospacedDigit())
                    .foregroundColor(Neon.textSecondary)
            } else {
                // Infinite / indeterminate.
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                    .tint(Neon.blue)
            }
            if let title = node.title {
                Text(title).font(.headline).foregroundColor(Neon.textPrimary)
            }
            if let sub = node.subtitle {
                Text(sub)
                    .font(.subheadline)
                    .foregroundColor(Neon.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
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
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(Neon.blue)
                    TextField("Search…", text: $query)
                        .textFieldStyle(.plain)
                        .foregroundColor(Neon.textPrimary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Neon.card)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Neon.stroke, lineWidth: 1)))
                .padding(12)
            }
            List(items) { item in
                HStack(spacing: 8) {
                    if let icon = item.icon { Image(systemName: icon).foregroundColor(Neon.blue) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).foregroundColor(Neon.textPrimary)
                        if let sub = item.subtitle {
                            Text(sub).font(.caption).foregroundColor(Neon.textSecondary)
                        }
                    }
                    Spacer()
                    if let acc = item.accessory {
                        Text(acc).font(.caption).foregroundColor(Neon.textSecondary)
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
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                Text(markdown)
                    .foregroundColor(Neon.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
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
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: node.columnCount), spacing: 12) {
                ForEach(node.items) { item in
                    VStack(spacing: 6) {
                        if let icon = item.icon {
                            Image(systemName: icon)
                                .font(.system(size: 28))
                                .foregroundColor(Neon.blue)
                                .shadow(color: Neon.blue.opacity(0.5), radius: 6)
                        }
                        Text(item.title)
                            .font(.caption)
                            .foregroundColor(Neon.textPrimary)
                            .multilineTextAlignment(.center)
                        if let sub = item.subtitle {
                            Text(sub).font(.caption2).foregroundColor(Neon.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Neon.card)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Neon.stroke, lineWidth: 1)))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let primary = item.allActions.first {
                            onAction(primary.id, primary.value ?? item.id, [:])
                        }
                    }
                }
            }
            .padding(12)
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
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(node.fields) { field in
                        fieldView(field)
                    }
                }
                .padding(16)
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
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 84)
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
                    .font(.system(size: 13))
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
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(0.8)
                .foregroundColor(Neon.blueBright.opacity(0.85))
            control()
        }
    }
}

/// Shared input chrome for extension form controls: dark card fill + neon
/// hairline, matching the Settings inputs.
private struct NeonFieldChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Neon.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Neon.stroke, lineWidth: 1)))
    }
}

private extension View {
    func neonFieldChrome() -> some View { modifier(NeonFieldChrome()) }
}

// MARK: - Converter (live bidirectional two-pane transform)

private struct ConverterRender: View {
    let node: ConverterNode
    /// (fnName, input) → output, evaluated synchronously in the extension VM.
    let transform: (String, String) -> String

    @State private var leftText: String = ""
    @State private var rightText: String = ""
    /// Guards against the change → set-sibling → change feedback loop: while one
    /// side is writing the other, the other side's onChange is a no-op.
    @State private var updating = false
    @State private var seeded = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            pane(label: node.left.label ?? "Input",
                 placeholder: node.left.placeholder,
                 text: $leftText)
            Rectangle()
                .fill(Neon.stroke)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
            pane(label: node.right.label ?? "Output",
                 placeholder: node.right.placeholder,
                 text: $rightText)
        }
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Neon.bgTop, Neon.bgBottom],
                           startPoint: .top, endPoint: .bottom))
        .onChange(of: leftText) { _, new in
            guard !updating else { return }
            updating = true
            rightText = transform(node.forward, new)
            updating = false
        }
        .onChange(of: rightText) { _, new in
            guard !updating else { return }
            updating = true
            leftText = transform(node.backward, new)
            updating = false
        }
        .onAppear {
            guard !seeded else { return }
            seeded = true
            // Seed from declared values; derive the opposite pane when only the
            // left is provided so the window opens already converted.
            updating = true
            leftText = node.left.value ?? ""
            if let rv = node.right.value, !rv.isEmpty {
                rightText = rv
            } else if !leftText.isEmpty {
                rightText = transform(node.forward, leftText)
            }
            updating = false
        }
    }

    @ViewBuilder
    private func pane(label: String, placeholder: String?, text: Binding<String>) -> some View {
        let editorFont: Font = node.isMonospaced ? .system(.body, design: .monospaced) : .body
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(0.8)
                .foregroundColor(Neon.blueBright.opacity(0.85))
                .padding(.horizontal, 14)
                .padding(.top, 12)
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty, let placeholder {
                    Text(placeholder)
                        .font(editorFont)
                        .foregroundColor(Neon.textSecondary.opacity(0.55))
                        // Match the TextEditor's text origin: its own 8/10 padding
                        // PLUS the NSTextView's ~5pt internal text-container inset,
                        // so the placeholder sits exactly under the caret.
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: text)
                    .font(editorFont)
                    .foregroundColor(Neon.textPrimary)
                    .tint(Neon.blue)
                    .scrollContentBackground(.hidden)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
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
        .padding(12)
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
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func present(
        node: ExtensionViewNode,
        transform: ((_ fnName: String, _ input: String) -> String)? = nil,
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
        // top color so the bar dissolves into the UI. Dark aqua for system controls.
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
            ) { _ in
                MainActor.assumeIsolated { DockPolicy.windowDidHide(win) }
            }
        }
        DockPolicy.windowDidShow(win)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
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
    private let transform: ((String, String) -> String)?
    private var pending: Task<Void, Never>?

    init(
        node: ExtensionViewNode,
        transform: ((String, String) -> String)? = nil,
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
