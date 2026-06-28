// The compact view hosted inside each menu-bar NSStatusItem button, plus the
// Canvas/ring primitives it draws with. Mirrors exelban/Stats: a small label
// stacked above the value, the value coloured by the module's threshold ramp,
// honouring the user's left/center/right alignment. Monospaced digits + a hidden
// width-reservation keep the item from resizing (and shoving its neighbours) as
// the reading changes.

import SwiftUI
import StatsCore

/// One menu-bar item's content: a stacked label + value and/or a sparkline,
/// coloured by the module's threshold ramp. Network renders two rate channels;
/// battery renders a glyph.
struct StatsMenuWidget: View {
    let module: StatsModule
    @ObservedObject var store: StatsStore

    private var thickness: CGFloat { NSStatusBar.system.thickness }
    private var alignment: StatsWidgetAlignment { store.style.alignment }

    private var hAlign: HorizontalAlignment {
        switch alignment { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }
    private var cellAlign: Alignment {
        switch alignment { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }

    var body: some View {
        let cfg = store.style.config(module)
        content(cfg)
            .padding(.horizontal, sz(3))
            .frame(height: thickness)
            .fixedSize()
    }

    @ViewBuilder
    private func content(_ cfg: ModuleWidgetConfig) -> some View {
        switch module {
        case .network:
            networkChannels(cfg)
        case .battery:
            MenuBattery(charge: store.snapshot.battery?.charge ?? 0,
                        charging: store.snapshot.battery?.isCharging ?? false,
                        color: cfg.rampColor(module.rampValue(store.snapshot) ?? 0),
                        height: thickness)
        default:
            let ramp = module.rampValue(store.snapshot) ?? 0
            HStack(spacing: sz(4)) {
                if cfg.mode != .textOnly, let key = module.historyKey {
                    Sparkline(values: store.history(key), color: cfg.rampColor(ramp),
                              normalizeToMax: key == "power")
                        .frame(width: sz(24), height: thickness - sz(10))
                }
                if cfg.mode != .graph { valueStack(cfg, ramp) }
            }
        }
    }

    /// Label stacked above value. Alignment positions the (usually narrower) value
    /// under the label — this is what makes left/center/right visibly differ.
    private func valueStack(_ cfg: ModuleWidgetConfig, _ ramp: Double) -> some View {
        VStack(alignment: hAlign, spacing: -2) {
            if cfg.showLabel {
                Text(module.shortLabel)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            ZStack(alignment: cellAlign) {
                Text(module.primaryWidthSample()).hidden()
                Text(module.primaryText(store.snapshot, showUnit: cfg.showUnit))
                    .foregroundStyle(cfg.rampColor(ramp))
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
        }
    }

    private func networkChannels(_ cfg: ModuleWidgetConfig) -> some View {
        let n = store.snapshot.network
        // Upload on top, download below, the ↑/↓ arrow trailing each rate — and each
        // line reserves the widest string so megabyte rates can't widen the item.
        return VStack(alignment: .trailing, spacing: -2) {
            channelLine(StatsFormat.rateMenu(n?.uploadBytesPerSec ?? 0), "↑", cfg.up.color)
            channelLine(StatsFormat.rateMenu(n?.downloadBytesPerSec ?? 0), "↓", cfg.down.color)
        }
        .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
    }

    private func channelLine(_ rate: String, _ arrow: String, _ color: Color) -> some View {
        ZStack(alignment: .trailing) {
            // Reserve a realistic worst-case ("99.9 MB/s" ≈ 800 Mbps) so the channel
            // stays fixed-width without the dead space a 3-digit MB/s sample left. A
            // rarer >100 MB/s burst can grow the item a hair — acceptable over the gap.
            Text("99.9 MB/s\(arrow)").hidden()
            HStack(spacing: sz(2)) {
                Text(rate)
                Text(arrow)
            }
            .foregroundStyle(color)
        }
    }
}

/// Filled line chart of a small value window. `normalizeToMax` rescales to the
/// window's own max (for unbounded metrics like power/net); otherwise 0…1.
struct Sparkline: View {
    let values: [Double]
    let color: Color
    var normalizeToMax = false

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let maxV = normalizeToMax ? Swift.max(values.max() ?? 1, 0.0001) : 1.0
            let n = values.count
            func point(_ i: Int) -> CGPoint {
                let x = size.width * CGFloat(i) / CGFloat(n - 1)
                let y = size.height * (1 - CGFloat(min(1, max(0, values[i] / maxV))))
                return CGPoint(x: x, y: y)
            }
            var line = Path()
            line.move(to: point(0))
            for i in 1..<n { line.addLine(to: point(i)) }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(color.opacity(0.22)))
            ctx.stroke(line, with: .color(color), lineWidth: 1.5)
        }
        // No .drawingGroup(): Canvas already composites efficiently; an offscreen
        // Metal pass for a 24pt line would be steady wasted energy in a forever widget.
    }
}

/// A progress ring used in the popover. `value` 0…1.
struct StatsRing: View {
    let value: Double
    let color: Color
    var lineWidth: CGFloat = 8
    var label: String

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, max(0, value))))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label)
                .font(Neon.font(15, weight: .bold, design: .rounded))
                .foregroundStyle(Neon.textPrimary)
        }
    }
}

/// A ring split into sequential coloured arcs (e.g. CPU system + user) over a dim
/// track — exelban's multi-segment usage donut. Segment values are 0…1 fractions
/// of the full circle, drawn head-to-tail from 12 o'clock.
struct SegmentedRing: View {
    let segments: [(value: Double, color: Color)]
    var lineWidth: CGFloat = 8
    var label: String

    var body: some View {
        ZStack {
            Circle().stroke(Neon.textSecondary.opacity(0.18), lineWidth: lineWidth)
            ForEach(Array(cumulative.enumerated()), id: \.offset) { _, seg in
                Circle()
                    .trim(from: seg.start, to: seg.end)
                    .stroke(seg.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            Text(label)
                .font(Neon.font(17, weight: .bold, design: .rounded))
                .foregroundStyle(Neon.textPrimary)
        }
    }

    private var cumulative: [(start: CGFloat, end: CGFloat, color: Color)] {
        var acc: CGFloat = 0
        var out: [(CGFloat, CGFloat, Color)] = []
        for s in segments {
            let v = CGFloat(min(1, max(0, s.value)))
            guard v > 0, acc < 1 else { continue }
            let end = min(1, acc + v)
            out.append((acc, end, s.color))
            acc = end
        }
        return out
    }
}

/// A compact battery outline for the menu bar, filled to `charge` with a charging
/// bolt overlay — scaled to fit the bar thickness.
struct MenuBattery: View {
    let charge: Double
    let charging: Bool
    let color: Color
    let height: CGFloat

    var body: some View {
        let h = max(11, height - sz(11))
        let w = h * 1.9
        return HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: sz(3))
                    .stroke(Color.secondary, lineWidth: sz(1.4))
                    .frame(width: w, height: h)
                RoundedRectangle(cornerRadius: sz(1.5))
                    .fill(color)
                    .frame(width: max(sz(2), (w - sz(4)) * CGFloat(min(1, max(0, charge)))), height: h - sz(4))
                    .padding(.leading, sz(2))
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: h * 0.55, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: w, height: h)
                }
            }
            RoundedRectangle(cornerRadius: 0.5)
                .fill(Color.secondary)
                .frame(width: sz(2), height: h * 0.4)
        }
    }
}
