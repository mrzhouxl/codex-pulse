import SwiftUI
import PulseCore
import AppKit
import QuartzCore

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum Palette {
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    private static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    static let bg = adaptive(light: color(0.957, 0.969, 0.984), dark: color(0.035, 0.051, 0.078))
    static let panel = adaptive(light: color(1.000, 1.000, 1.000), dark: color(0.063, 0.090, 0.133))
    static let raised = adaptive(light: color(0.918, 0.941, 0.969), dark: color(0.094, 0.137, 0.204))
    static let sidebar = adaptive(light: color(0.925, 0.949, 0.973), dark: color(0.031, 0.047, 0.075))
    static let accent = adaptive(light: color(0.118, 0.388, 0.914), dark: color(0.357, 0.561, 1.000))
    static let accentAlt = adaptive(light: color(0.294, 0.549, 1.000), dark: color(0.482, 0.702, 1.000))
    static let dim = adaptive(light: color(0.337, 0.384, 0.455), dark: color(0.537, 0.588, 0.667))
    static let white = adaptive(light: color(0.067, 0.094, 0.153), dark: color(0.945, 0.961, 0.984))
    static let onAccent = adaptive(light: color(1, 1, 1), dark: color(0.027, 0.063, 0.122))
    static let line = adaptive(light: color(0.045, 0.118, 0.220, 0.10), dark: color(1, 1, 1, 0.085))
    static let track = adaptive(light: color(0.045, 0.118, 0.220, 0.10), dark: color(1, 1, 1, 0.105))
    static let amber = adaptive(light: color(0.710, 0.365, 0.015), dark: color(1, 0.745, 0.405))
    static let coral = adaptive(light: color(0.770, 0.155, 0.265), dark: color(1, 0.405, 0.500))
    static let brandGradient = LinearGradient(colors: [accent, accentAlt], startPoint: .topLeading, endPoint: .bottomTrailing)
    static func quota(_ remaining: Double?) -> Color {
        guard let remaining else { return dim }
        return remaining <= 10 ? coral : remaining <= 30 ? amber : accent
    }
}

struct PulseMark: View {
    var size: CGFloat = 28
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Palette.brandGradient)
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
            Text(">_")
                .font(.system(size: size * 0.40, weight: .bold, design: .monospaced))
                .tracking(-size * 0.055)
                .foregroundStyle(Palette.onAccent)
                .offset(x: -size * 0.015, y: -size * 0.015)
        }
        .frame(width: size, height: size)
        .shadow(color: Palette.accent.opacity(0.20), radius: size * 0.20, y: size * 0.08)
    }
}

struct QuotaRing: View {
    let remaining: Double?
    var size: CGFloat = 66
    var line: CGFloat = 5
    var symbol: String? = nil
    var muted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            RingDrawing(remaining: remaining, lineWidth: line, muted: muted, reduceMotion: reduceMotion)
                .frame(width: size, height: size)
            if let symbol {
                Image(systemName: symbol).font(.system(size: size * 0.28, weight: .medium)).foregroundStyle(Palette.white)
            } else {
                VStack(spacing: 2) {
                    Text(remaining.map { String(format: "%.0f", $0) } ?? "—")
                        .font(.system(size: size * 0.30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("% 剩余").font(.system(size: size * 0.08, weight: .medium)).foregroundStyle(Palette.dim)
                }
            }
        }.frame(width: size, height: size).opacity(muted ? 0.5 : 1)
            // Geometry and text must follow layout immediately. Only the native
            // strokeEnd property below animates; no layout transaction is inherited.
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("剩余额度 \(PulseFormat.percent(remaining))\(muted ? "，数据待更新" : "")")
    }
}

private struct RingDrawing: NSViewRepresentable {
    let remaining: Double?
    let lineWidth: CGFloat
    let muted: Bool
    let reduceMotion: Bool

    func makeNSView(context: Context) -> RingDrawingView { RingDrawingView() }
    func updateNSView(_ view: RingDrawingView, context: Context) {
        view.update(remaining: remaining, lineWidth: lineWidth, muted: muted, reduceMotion: reduceMotion)
    }
}

final class RingDrawingView: NSView {
    let trackLayer = CAShapeLayer()
    let progressLayer = CAShapeLayer()
    private var target: CGFloat?
    private var lineWidth: CGFloat = 5
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for shape in [trackLayer, progressLayer] {
            shape.fillColor = nil
            shape.lineCap = .round
            shape.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(),
                             "lineWidth": NSNull(), "strokeColor": NSNull(), "strokeEnd": NSNull()]
            layer?.addSublayer(shape)
        }
        progressLayer.strokeEnd = 0
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func update(remaining: Double?, lineWidth: CGFloat, muted: Bool, reduceMotion: Bool) {
        let next = remaining.flatMap { $0.isFinite ? CGFloat(min(100, max(0, $0)) / 100) : nil }
        let previous = target
        let displayed = progressLayer.presentation()?.strokeEnd ?? progressLayer.strokeEnd
        self.lineWidth = lineWidth
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.strokeColor = NSColor(Palette.track).cgColor
        progressLayer.strokeColor = NSColor(Palette.quota(remaining)).cgColor
        progressLayer.shadowColor = progressLayer.strokeColor
        progressLayer.shadowOpacity = muted ? 0 : 0.12
        progressLayer.shadowRadius = 5
        progressLayer.shadowOffset = .zero
        progressLayer.strokeEnd = next ?? 0
        updateGeometry()
        CATransaction.commit()

        if reduceMotion || next == nil {
            progressLayer.removeAnimation(forKey: "quotaProgress")
        } else if next != previous {
            progressLayer.removeAnimation(forKey: "quotaProgress")
            // Do not animate an initial/unknown value into a made-up percentage.
            if previous != nil, let next, abs(displayed - next) > 0.0001 {
                let animation = CABasicAnimation(keyPath: "strokeEnd")
                animation.fromValue = displayed
                animation.toValue = next
                animation.duration = 0.35
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                progressLayer.add(animation, forKey: "quotaProgress")
            }
        }
        target = next
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateGeometry()
        CATransaction.commit()
    }

    private func updateGeometry() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let radius = max(0, (min(bounds.width, bounds.height) - lineWidth) / 2)
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius,
                    startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: false)
        for shape in [trackLayer, progressLayer] {
            shape.frame = bounds
            shape.path = path
            shape.lineWidth = lineWidth
        }
    }
}

struct QuotaBar: View {
    let window: QuotaWindow
    let now: Date
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 9 : 12) {
            HStack {
                Text(window.label).font(.system(size: compact ? 12 : 13, weight: .medium))
                Spacer()
                Text("剩余 \(PulseFormat.percent(window.remaining))").font(.system(size: compact ? 12 : 13, weight: .semibold)).foregroundStyle(Palette.quota(window.remaining))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.track)
                    Capsule().fill(Palette.quota(window.remaining))
                        .frame(width: max(0, proxy.size.width * window.remaining / 100))
                }
            }.frame(height: compact ? 5 : 6)
            HStack {
                Text("已用 \(PulseFormat.percent(window.used))")
                Spacer()
                Text(window.countdown(at: now))
            }.font(.system(size: compact ? 10 : 11)).foregroundStyle(Palette.dim)
        }.help(window.resetDate.map { "下次重置：\($0.formatted(date: .abbreviated, time: .shortened))" } ?? "官方暂未提供重置时间")
    }
}

struct ActionButton: View {
    let title: String
    let symbol: String
    var primary = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
            }.padding(.horizontal, 13).padding(.vertical, 9)
                .foregroundStyle(primary ? Palette.onAccent : Palette.white)
                .background(primary ? AnyShapeStyle(Palette.brandGradient) : AnyShapeStyle(Palette.raised), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(primary ? Color.clear : Palette.line))
        }.buttonStyle(.plain)
    }
}

struct StatusDot: View {
    @ObservedObject var store: PulseStore
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(store.isStale ? Palette.amber : Palette.accent).frame(width: 5, height: 5)
            Text(store.statusLabel).font(.system(size: 10))
        }.foregroundStyle(Palette.dim)
    }
}

extension View {
    func pulseCard(padding: CGFloat = 20) -> some View {
        self.padding(padding).background(Palette.panel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.line))
    }
}
