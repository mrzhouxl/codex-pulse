import SwiftUI
import PulseCore
import AppKit
import QuartzCore

enum Palette {
    static let bg = Color(red: 0.050, green: 0.054, blue: 0.063)
    static let panel = Color(red: 0.082, green: 0.088, blue: 0.101)
    static let raised = Color(red: 0.112, green: 0.121, blue: 0.140)
    static let accent = Color(red: 0.57, green: 0.72, blue: 1.0)
    static let dim = Color(red: 0.57, green: 0.59, blue: 0.63)
    static let white = Color(red: 0.94, green: 0.95, blue: 0.98)
    static let line = Color.white.opacity(0.075)
    static let amber = Color(red: 1, green: 0.77, blue: 0.39)
    static let coral = Color(red: 1, green: 0.44, blue: 0.38)
    static func quota(_ remaining: Double?) -> Color {
        guard let remaining else { return dim }
        return remaining <= 10 ? coral : remaining <= 30 ? amber : accent
    }
}

struct PulseMark: View {
    var size: CGFloat = 28
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29).fill(Palette.accent)
            Image(systemName: "waveform.path").font(.system(size: size * 0.60, weight: .semibold)).foregroundStyle(Palette.bg)
        }.frame(width: size, height: size)
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
                VStack(spacing: 1) {
                    Text(remaining.map { String(format: "%.0f", $0) } ?? "—")
                        .font(.system(size: size * 0.27, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("% 剩余").font(.system(size: size * 0.07, weight: .medium)).foregroundStyle(Palette.dim)
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
        trackLayer.strokeColor = NSColor.white.withAlphaComponent(0.10).cgColor
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
                    Capsule().fill(Color.white.opacity(0.085))
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
                .foregroundStyle(primary ? Palette.bg : Palette.white)
                .background(primary ? Palette.accent : Palette.raised, in: RoundedRectangle(cornerRadius: 9))
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
