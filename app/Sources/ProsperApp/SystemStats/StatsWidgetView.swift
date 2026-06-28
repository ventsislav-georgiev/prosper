// The compact view hosted inside each menu-bar NSStatusItem button, plus the
// Canvas primitives (sparkline, ring) it draws with. Monospaced digits keep the
// width stable tick-to-tick so the item doesn't jitter the whole menu bar.

import SwiftUI
import StatsCore

/// One menu-bar item's content: optional label + text and/or a sparkline,
/// coloured by the module's threshold ramp. Network renders two channels.
struct StatsMenuWidget: View {
    let module: StatsModule
    @ObservedObject var store: StatsStore

    private var thickness: CGFloat { NSStatusBar.system.thickness }

    var body: some View {
        let cfg = store.style.config(module)
        HStack(spacing: sz(3)) {
            if cfg.showLabel, module != .network {
                Text(module.shortLabel)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            content(cfg)
        }
        .padding(.horizontal, sz(5))
        .frame(height: thickness)
        .fixedSize()
    }

    @ViewBuilder
    private func content(_ cfg: ModuleWidgetConfig) -> some View {
        if module == .network {
            networkChannels(cfg)
        } else {
            let ramp = module.rampValue(store.snapshot) ?? 0
            HStack(spacing: sz(3)) {
                if cfg.mode != .textOnly, let key = module.historyKey {
                    Sparkline(values: store.history(key), color: cfg.rampColor(ramp),
                              normalizeToMax: key == "power")
                        .frame(width: sz(26), height: thickness - sz(8))
                }
                if cfg.mode != .graph {
                    // Reserve the widest possible string (hidden) so the item width is
                    // FIXED — the visible value trails inside it and never resizes the
                    // menu bar as digits come and go.
                    ZStack(alignment: .trailing) {
                        Text(module.primaryWidthSample()).hidden()
                        Text(module.primaryText(store.snapshot, showUnit: cfg.showUnit))
                            .foregroundStyle(cfg.rampColor(ramp))
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                }
            }
        }
    }

    private func networkChannels(_ cfg: ModuleWidgetConfig) -> some View {
        let n = store.snapshot.network
        // Each channel reserves a fixed width ("↓ 999.9M") so the two-line readout
        // can't widen the item as rates climb into the megabytes.
        return VStack(alignment: .trailing, spacing: -1) {
            channelLine("↓ ", StatsFormat.rate(n?.downloadBytesPerSec ?? 0), cfg.down.color)
            channelLine("↑ ", StatsFormat.rate(n?.uploadBytesPerSec ?? 0), cfg.up.color)
        }
        .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
    }

    private func channelLine(_ arrow: String, _ rate: String, _ color: Color) -> some View {
        ZStack(alignment: .trailing) {
            Text(arrow + "999.9M").hidden()
            Text(arrow + rate).foregroundStyle(color)
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
        // Metal pass for a 26pt line would be steady wasted energy in a forever widget.
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
