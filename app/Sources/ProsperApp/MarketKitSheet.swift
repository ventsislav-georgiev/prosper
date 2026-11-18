import AppKit
import SwiftUI

// #919 S4: a kit's Install in the Marketplace opens this sheet instead of installing: the download is prepared (S3:
// fetched, bound, rechecked against its listing), its README and generated summary are shown, and only the sheet's
// Install installs it. Every text here comes from the kit's publisher: drawn through OutsideText, verbatim.

/// What the Marketplace window reaches: the S3 prepare/install/discard seams, the one-click install and the link opener.
/// Rows pass fakes; `live` is the window's.
@MainActor
struct MarketInstallSeams {
    typealias Prepared = ExtensionRegistry.PreparedMarketInstall
    var prepare: @MainActor (_ id: String, _ version: String, _ listedKind: String?) async throws -> Prepared
    var install: @MainActor (Prepared) throws -> Void
    var discard: @MainActor (Prepared) -> Void
    var installDirect: @MainActor (_ id: String, _ version: String) async throws -> Void
    var contents: @MainActor (Prepared) -> MarketKitContents
    var openURL: @MainActor (URL) -> Void

    static func live(_ r: ExtensionRegistry) -> MarketInstallSeams {
        MarketInstallSeams(prepare: { try await r.prepareFromMarket(id: $0, version: $1, listedKind: $2) },
                           install: { _ = try r.install($0) },
                           discard: { r.discard($0) },
                           installDirect: { _ = try await r.installFromMarket(id: $0, version: $1) },
                           contents: { p in
                               MarketKitContents.read(p.directory, manifest: (try? r.bindMarketIdentity(
                                   extDir: p.directory, expected: p.id, expectedVersion: p.version))?.manifest)
                           },
                           openURL: { NSWorkspace.shared.open($0) })
    }
}

/// Publisher lines as the Kits row and the sheet draw them: at most `max` lines, each through OutsideText (unseen
/// scalars such as direction controls dropped, marks capped, cut).
enum MarketKitText {
    static let lineMax = 300, rowSummaryLines = 3, sheetSummaryLines = 200, readmeLines = 400
    static let unreviewed = "Unreviewed \u{2014} runs shell commands in your Claude Code sessions"
    static let untrustedNote = "Installs untrusted: nothing runs until you trust it and Apply it in its Settings page."
    static let badge = "KIT", badgeLabel = "Agent kit, unreviewed"

    static func lines(_ lines: [String], max: Int) -> [String] {
        lines.prefix(max).map { OutsideText.shown($0, max: lineMax) }
    }
}

/// The downloaded kit's own README and its "What will change" lines, read from the prepared folder (authoritative:
/// the recheck already found them equal to the listing's).
struct MarketKitContents: Equatable {
    var readme: [String]
    var summary: [String]

    /// `manifest`: the prepared folder's own (nil: no summary).
    static func read(_ dir: URL, manifest: ExtensionManifest?) -> MarketKitContents {
        let text = (try? BoundedFileRead.data(dir.appendingPathComponent("README.md"), maxBytes: KitValidator.maxTextBytes))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var summary: [String] = []
        // slugs taken by other kits do not change the summary; the recheck already ran the validator with them
        if let manifest,
           case .ok(let v) = KitValidator.validate(kitDir: dir, manifest: manifest, source: .market, otherKitSlugs: []) {
            summary = KitListingPreview.make(v, readme: "").summary
        }
        return MarketKitContents(readme: MarketKitText.lines(text.components(separatedBy: "\n"), max: MarketKitText.readmeLines),
                                 summary: MarketKitText.lines(summary, max: MarketKitText.sheetSummaryLines))
    }
}

/// One kit's pre-install sheet: prepare on start, Install once, discard on every close (installed or not).
@MainActor
final class MarketKitSheetModel: ObservableObject, Identifiable {
    enum Phase: Equatable { case preparing, ready, refused(String), installing, installed, failed(String) }

    let pkg: MarketClient.Package
    @Published private(set) var phase = Phase.preparing
    @Published private(set) var contents = MarketKitContents(readme: [], summary: [])
    private var prepared: MarketInstallSeams.Prepared?
    private var closed = false
    private let seams: MarketInstallSeams
    private(set) var task: Task<Void, Never>?

    init(pkg: MarketClient.Package, seams: MarketInstallSeams) { self.pkg = pkg; self.seams = seams }

    var title: String { ExtensionRowText.title(pkg.title, id: pkg.id) }
    var canInstall: Bool { phase == .ready }

    func start() {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // listedKind: a listing "kit" over an archive that is not a kit is refused here too (#1495 review)
                let p = try await seams.prepare(pkg.id, pkg.latestVersion, pkg.kind)
                if closed { seams.discard(p); return }   // closed while it downloaded
                prepared = p
                contents = seams.contents(p)
                phase = .ready
            } catch {
                if !closed { phase = .refused(MarketplaceRootView.installErrorText(error)) }
            }
        }
    }

    func install() {
        guard phase == .ready, let p = prepared else { return }
        phase = .installing
        do {
            try seams.install(p)
            phase = .installed
        } catch {
            phase = .failed(MarketplaceRootView.installErrorText(error))
        }
    }

    /// Removes the work folder once; a prepare still running discards its own result when it ends.
    func close() {
        guard !closed else { return }
        closed = true
        if let p = prepared { prepared = nil; seams.discard(p) }
    }

    /// README links: http and https only, asked of LinkPolicy, opened through the seam.
    func follow(_ url: URL) {
        guard case .open(let u) = LinkPolicy.action(url, document: URL(fileURLWithPath: "/README.md")),
              ["http", "https"].contains(u.scheme.map(LinkPolicy.asciiLowercased) ?? "") else { return }
        seams.openURL(u)
    }

    /// Q3 (supervisor to confirm): the public repo's issue form, the kit id in the title.
    var reportURL: URL? {
        var c = URLComponents(string: "https://github.com/ventsislav-georgiev/prosper/issues/new")
        c?.queryItems = [URLQueryItem(name: "title", value: "Report kit: " + OutsideText.shown(pkg.id, max: 120))]
        return c?.url
    }
}

/// The Marketplace window's install state: the one-click install of themes and extensions, and the open kit sheet.
@MainActor
final class MarketInstaller: ObservableObject {
    @Published private(set) var installingID: String?
    @Published var installError: String?
    @Published private(set) var kitSheet: MarketKitSheetModel?
    let seams: MarketInstallSeams

    init(seams: MarketInstallSeams) { self.seams = seams }

    func install(_ pkg: MarketClient.Package) {
        installError = nil
        if pkg.isKit {
            closeSheet()
            let m = MarketKitSheetModel(pkg: pkg, seams: seams)
            kitSheet = m
            m.start()
            return
        }
        installingID = pkg.id
        Task {
            do {
                try await seams.installDirect(pkg.id, pkg.latestVersion)
                installingID = nil
            } catch {
                installingID = nil
                installError = MarketplaceRootView.installErrorText(error)
            }
        }
    }

    /// The sheet's Install: closes the sheet once installed (the close removes the work folder, as installFromMarket does).
    func installFromSheet() {
        guard let m = kitSheet else { return }
        m.install()
        if m.phase == .installed { closeSheet() }
    }

    /// Cancel, the sheet's dismissal and the window's close.
    func closeSheet() {
        kitSheet?.close()
        kitSheet = nil
    }
}

struct MarketKitSheetView: View {
    @ObservedObject var model: MarketKitSheetModel
    let onInstall: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: sz(10)) {
            HStack(spacing: sz(6)) {
                ExtensionRowTitle(text: model.title)
                MarketKitBadge()
            }
            Text(MarketKitText.unreviewed).font(Neon.font(.caption)).foregroundStyle(Neon.magenta)
            ScrollView {
                VStack(alignment: .leading, spacing: sz(8)) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: sz(160), maxHeight: sz(420))
            Text(MarketKitText.untrustedNote).font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
            HStack {
                if let report = model.reportURL {
                    Button("Report kit") { model.follow(report) }.buttonStyle(.link)
                }
                Spacer()
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
                if model.canInstall { Button("Install") { onInstall() }.buttonStyle(.neon) }
            }
        }
        .padding(sz(16))
        .frame(width: sz(520))
        .foregroundStyle(Neon.textPrimary)
        .environment(\.openURL, OpenURLAction { url in model.follow(url); return .handled })
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .preparing, .installing:
            ProgressView().controlSize(.small)
        case .refused(let why), .failed(let why):
            Text(verbatim: OutsideText.shown(why, max: 600)).font(Neon.font(.caption)).foregroundStyle(Neon.magenta)
        case .ready, .installed:
            Text("What will change").font(Neon.font(.caption)).bold()
            ForEach(Array(model.contents.summary.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line).font(Neon.font(.caption)).lineLimit(1).clipped()
            }
            Divider()
            ForEach(Array(model.contents.readme.enumerated()), id: \.offset) { _, line in
                Self.readmeLine(line).lineLimit(nil).clipped()
            }
        }
    }

    /// One README line as inline Markdown (links, emphasis, code); a heading line drawn bold without its marks.
    static func readmeLine(_ line: String) -> Text {
        let heading = line.hasPrefix("#")
        let body = heading ? String(line.drop { $0 == "#" }.drop { $0 == " " }) : line
        let md = (try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(body)
        return Text(md).font(Neon.font(heading ? .body : .caption)).bold(heading)
    }
}

/// The KIT badge beside a kit's title, with its own VoiceOver label.
struct MarketKitBadge: View {
    var body: some View {
        Text(MarketKitText.badge).font(Neon.font(.caption2)).bold()
            .padding(.horizontal, sz(5)).padding(.vertical, sz(1))
            .background(Neon.magenta.opacity(0.25))
            .clipShape(Capsule())
            .accessibilityLabel(MarketKitText.badgeLabel)
    }
}
