import SwiftUI
import PulseCore

struct CompactDetailView: View {
    @ObservedObject var store: PulseStore
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 11) {
                PulseMark(size: 34)
                Text("Codex Pulse").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium)).frame(width: 29, height: 29) }
                    .buttonStyle(.plain).foregroundStyle(Palette.dim).disabled(store.isRefreshing).help("刷新额度")
                Button { store.onClosePopover?() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).frame(width: 27, height: 29) }
                    .buttonStyle(.plain).foregroundStyle(Palette.dim).help("关闭详情")
            }
            if !store.buckets.isEmpty {
                HStack(spacing: 6) {
                    ForEach(store.buckets) { bucket in
                        Button { store.selectedID = bucket.id } label: {
                            Text(bucket.title).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 7)
                                .foregroundStyle(store.selected?.id == bucket.id ? Palette.accent : Palette.dim)
                                .background(store.selected?.id == bucket.id ? Palette.accent.opacity(0.1) : .clear, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
            if let bucket = store.selected {
                HStack(spacing: 18) {
                    QuotaRing(remaining: bucket.limitingWindow?.remaining, size: 86, line: 5, muted: store.isStale)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(bucket.title + " 额度").font(.system(size: 16, weight: .semibold))
                        Text(bucket.isRestricted || store.limits?.ordinaryUsageAllowed == false ? "当前账号额度受限" : "\(bucket.windows.count > 1 ? "多个周期，统一掌握" : bucket.subtitle)")
                            .font(.system(size: 11)).foregroundStyle(bucket.isRestricted ? Palette.amber : Palette.dim)
                        if bucket.windows.count > 1 { Text("圆环显示剩余最少的周期").font(.system(size: 10)).foregroundStyle(Palette.dim) }
                    }
                }.padding(.vertical, 3)
                Rectangle().fill(Palette.line).frame(height: 1)
                ForEach(Array(bucket.windows.enumerated()), id: \.offset) { _, window in
                    VStack(alignment: .leading, spacing: 7) {
                        QuotaBar(window: window, now: store.now, compact: true)
                        if let date = window.resetDate {
                            Text("重置于 " + date.formatted(.dateTime.month().day().hour().minute())).font(.system(size: 10)).foregroundStyle(Palette.dim.opacity(0.8))
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
                    HStack(spacing: 5) { Text("完整面板"); Image(systemName: "arrow.up.right") }.font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accent)
                }.buttonStyle(.plain)
            }
        }.padding(23).frame(width: 380).background(Palette.bg).foregroundStyle(Palette.white)
    }
}
