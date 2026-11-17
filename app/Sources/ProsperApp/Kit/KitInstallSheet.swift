import SwiftUI

/// #918 S4: the install selection of a never-applied kit: one checkbox per piece (all on until unchecked, the model's
/// installOff), the pieces the closure leaves out with an unchecked one ("dependents note"), the preview's refusals,
/// and (#1421 carry) a market kit over the market byte cap named BEFORE Apply is offered: Apply is then not offered.
/// The view content only; S5 decides how it is presented. Every control comes from `controls(_:)`.
struct KitInstallSheet: View {
    @ObservedObject var model: KitPaneModel

    static let capNote = "This market kit is over the market size cap (256 KiB): Apply would refuse it."

    static func capText(_ why: String) -> String { capNote + " (" + why + ")" }

    var body: some View {
        let plan = Self.controls(model)
        VStack(alignment: .leading, spacing: sz(8)) {
            ForEach(plan.filter { $0.kind == .checkbox }, id: \.id) { c in
                let piece = String(c.id.dropFirst("install:".count))
                Toggle(c.title, isOn: Binding(get: { !model.installOff.contains(piece) },
                                              set: { on in if on { model.installOff.remove(piece) } else { model.installOff.insert(piece) } }))
                    .toggleStyle(.checkbox).disabled(!c.enabled).accessibilityLabel(c.label)
            }
            ForEach(Self.lines(model), id: \.self) {
                Text($0).font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if let c = plan.first(where: { $0.id == "install" }) {
                Button(c.title) { _ = model.apply() }.buttonStyle(.neon).fixedSize().disabled(!c.enabled).accessibilityLabel(c.label)
            }
        }
    }

    /// The validated kit, when the preview passed.
    private static func validated(_ m: KitPaneModel) -> KitValidated? {
        if case .ok(let v)? = m.facts?.preview { return v }
        return nil
    }

    /// The pieces the closure switches off with the unchecked ones (not themselves unchecked), sorted; or why the
    /// selection is refused.
    static func dependents(_ m: KitPaneModel) -> (also: [String], refused: KitRefusal?) {
        guard let v = validated(m) else { return ([], nil) }
        switch KitPieceSelection(v).closure(off: m.installOff) {
        case .closed(let off, _): return (off.subtracting(m.installOff).sorted(), nil)
        case .refused(let why): return ([], why)
        }
    }

    /// The sheet's plain lines: the preview refusals, the cap, the dependents note, the A9 line.
    static func lines(_ m: KitPaneModel) -> [String] {
        var out: [String] = []
        if case .refused(let why)? = m.facts?.preview {
            out.append("The kit is refused:")
            out += why.map { OutsideText.shown($0.description, max: 400) }
        }
        if let c = m.facts?.sourceRefusal { out.append(capText(OutsideText.shown(c, max: 200))) }
        let d = dependents(m)
        if let why = d.refused { out.append(OutsideText.shown(why.description, max: 400)) }
        if !d.also.isEmpty { out.append("Also not installed, they need an unchecked piece: " + d.also.joined(separator: ", ")) }
        out.append(KitPaneView.applyNote)
        return out
    }

    /// One checkbox per piece; Apply only for a trusted kit whose preview passed, under the cap, with a selection
    /// that closes. Busy: every control disabled while the model runs a call.
    static func controls(_ m: KitPaneModel) -> [KitPaneControl] {
        guard let v = validated(m) else { return [] }
        var out = v.kit.pieces.map { p in
            KitPaneControl(id: "install:\(p.id)", kind: .checkbox, title: "\(p.id) (\(p.kind.rawValue))",
                           label: "Install piece \(p.id)", enabled: m.canAct)
        }
        if m.trusted, m.facts?.sourceRefusal == nil, dependents(m).refused == nil {
            out.append(KitPaneControl(id: "install", kind: .button, title: "Apply", label: "Apply " + OutsideText.shown(m.title, max: 64)
                                      + " with the checked pieces", enabled: m.canAct))
        }
        return out
    }
}
