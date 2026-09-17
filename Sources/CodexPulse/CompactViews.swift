import SwiftUI
import PulseCore

enum RailMetrics {
    static let width: CGFloat = 54
    static let cellHeight: CGFloat = 53
    static func height(for count: Int) -> CGFloat { CGFloat(max(1, min(4, count))) * 60 + 54 }
}

struct RailView: View {
    @ObservedObject var store: PulseStore
    private var outline: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: store.railOnRight ? 18 : 0,
            bottomLeadingRadius: store.railOnRight ? 18 : 0,
            bottomTrailingRadius: store.railOnRight ? 0 : 18,
            topTrailingRadius: store.railOnRight ? 0 : 18
        )
    }
    var body: some View {
        VStack(spacing: 7) {
            DragHandle().frame(height: 10).help("拖动到屏幕边缘")
            if store.buckets.isEmpty {
                Button { store.onShowDashboard?() } label: {
                    VStack(spacing: 6) {
                        QuotaRing(remaining: nil, size: 32, line: 3, symbol: "terminal")
                        Text("连接").font(.system(size: 10)).foregroundStyle(Palette.dim)
                    }.frame(width: RailMetrics.width, height: RailMetrics.cellHeight)
                }.buttonStyle(.plain)
            }
            ForEach(store.buckets.prefix(4)) { bucket in
                Button {
                    store.selectedID = bucket.id; store.onShowDetails?()
                } label: {
                    VStack(spacing: 6) {
                        QuotaRing(remaining: bucket.limitingWindow?.remaining, size: 32, line: 3, symbol: bucket.symbol, muted: store.isStale)
                        Text(PulseFormat.percent(bucket.limitingWindow?.remaining))
                            .font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(Palette.white)
                    }.frame(width: RailMetrics.width, height: RailMetrics.cellHeight).contentShape(Rectangle())
                }.buttonStyle(.plain).help("\(bucket.title) · 剩余 \(PulseFormat.percent(bucket.limitingWindow?.remaining))\n\(bucket.limitingWindow?.countdown(at: store.now) ?? "")")
                    .accessibilityLabel("\(bucket.title)，剩余 \(PulseFormat.percent(bucket.limitingWindow?.remaining))，查看详情")
            }
            Rectangle().fill(Palette.line).frame(width: 18, height: 1)
            Button { store.onShowDashboard?() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10)).foregroundStyle(Palette.dim).frame(width: 32, height: 16)
            }.buttonStyle(.plain).help("打开完整面板")
        }.padding(.top, 5).padding(.bottom, 8)
            .frame(width: RailMetrics.width, height: RailMetrics.height(for: store.buckets.count))
            .background(Color(red: 0.025, green: 0.028, blue: 0.035), in: outline)
            .overlay(outline.strokeBorder(Color.white.opacity(0.1)))
            .preferredColorScheme(.dark)
            .contextMenu {
                Button("打开主面板") { store.onShowDashboard?() }
                Button("刷新数据") { store.refresh() }
                Divider()
                Button("隐藏悬浮条") { store.showRail = false }
                Button("退出 Codex Pulse") { NSApp.terminate(nil) }
            }
    }
}

struct CompactDetailView: View {
    @ObservedObject var store: PulseStore
    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack(spacing: 9) {
                PulseMark(size: 25)
                Text("Codex Pulse").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 12)).frame(width: 25, height: 25) }
                    .buttonStyle(.plain).foregroundStyle(Palette.dim).disabled(store.isRefreshing).help("刷新额度")
                Button { store.onHideDetails?() } label: { Image(systemName: "xmark").font(.system(size: 11)).frame(width: 22, height: 25) }
                    .buttonStyle(.plain).foregroundStyle(Palette.dim).help("关闭详情")
            }
            if !store.buckets.isEmpty {
                HStack(spacing: 6) {
                    ForEach(store.buckets) { bucket in
                        Button { store.selectedID = bucket.id } label: {
                            Text(bucket.title).font(.system(size: 10, weight: .medium)).padding(.horizontal, 11).padding(.vertical, 7)
                                .foregroundStyle(store.selected?.id == bucket.id ? Palette.accent : Palette.dim)
                                .background(store.selected?.id == bucket.id ? Palette.accent.opacity(0.1) : .clear, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
            if let bucket = store.selected {
                HStack(spacing: 18) {
                    QuotaRing(remaining: bucket.limitingWindow?.remaining, size: 82, line: 5, muted: store.isStale)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(bucket.title + " 额度").font(.system(size: 17, weight: .semibold))
                        Text(bucket.isRestricted || store.limits?.ordinaryUsageAllowed == false ? "当前账号额度受限" : "\(bucket.windows.count > 1 ? "多个周期，统一掌握" : bucket.subtitle)")
                            .font(.system(size: 10)).foregroundStyle(bucket.isRestricted ? Palette.amber : Palette.dim)
                        if bucket.windows.count > 1 { Text("圆环显示剩余最少的周期").font(.system(size: 9)).foregroundStyle(Palette.dim) }
                    }
                }.padding(.vertical, 3)
                Rectangle().fill(Palette.line).frame(height: 1)
                ForEach(Array(bucket.windows.enumerated()), id: \.offset) { _, window in
                    VStack(alignment: .leading, spacing: 7) {
                        QuotaBar(window: window, now: store.now, compact: true)
                        if let date = window.resetDate {
                            Text("重置于 " + date.formatted(.dateTime.month().day().hour().minute())).font(.system(size: 9)).foregroundStyle(Palette.dim.opacity(0.8))
                        }
                    }
                }
                if bucket.windows.isEmpty { Text("暂未提供百分比额度").font(.system(size: 12)).foregroundStyle(Palette.dim) }
            } else {
                Text(store.isRefreshing ? "正在读取 Codex 额度…" : "连接 Codex 后查看真实额度。")
                    .font(.system(size: 13)).foregroundStyle(Palette.dim).frame(maxWidth: .infinity, minHeight: 100)
            }
            if let error = store.error {
                Text(error).font(.system(size: 10)).foregroundStyle(Palette.amber).lineLimit(3)
            }
            HStack {
                StatusDot(store: store); Spacer()
                Button { store.onShowDashboard?() } label: {
                    HStack(spacing: 5) { Text("完整面板"); Image(systemName: "arrow.up.right") }.font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.accent)
                }.buttonStyle(.plain)
            }
        }.padding(23).frame(width: 370).background(Palette.bg).foregroundStyle(Palette.white).preferredColorScheme(.dark)
    }
}

struct DragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> HandleView { HandleView() }
    func updateNSView(_ nsView: HandleView, context: Context) {}
    final class HandleView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.withAlphaComponent(0.19).setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 8, y: bounds.midY - 1, width: 16, height: 2), xRadius: 1, yRadius: 1).fill()
        }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
            NotificationCenter.default.post(name: .pulseRailDragged, object: window)
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
}
extension Notification.Name { static let pulseRailDragged = Notification.Name("pulseRailDragged") }
