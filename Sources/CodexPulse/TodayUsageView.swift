import SwiftUI
import PulseCore

struct TodayUsageMetric: View {
    @ObservedObject var store: PulseStore
    var body: some View {
        Button { store.page = "history" } label: {
            MetricCard(label: "今日 Token 用量", value: PulseFormat.tokens(store.todayTokens),
                       note: store.todayNote, symbol: "bolt")
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "arrow.up.right").font(.system(size: 8))
                        .foregroundStyle(Palette.accent).padding(.trailing, 35).padding(.top, 18)
                }
        }.buttonStyle(.plain)
            .help(store.todayTokens.map { "今日 \($0.formatted()) Tokens（含缓存输入）。点击查看明细。" } ?? store.todayNote)
            .accessibilityLabel("今日本机用量，\(store.todayTokens.map { $0.formatted() + " Tokens" } ?? store.todayNote)，查看明细")
    }
}

struct TodayUsageDetail: View {
    @ObservedObject var store: PulseStore
    private var snapshot: LocalUsageSnapshot? { store.todayUsage }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("今日 Token 用量", systemImage: "bolt").font(.system(size: 14, weight: .semibold))
                Text("本机统计").font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.accent)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Palette.accent.opacity(0.09), in: Capsule())
                Spacer()
                Text(store.now.formatted(.dateTime.month(.twoDigits).day(.twoDigits)) + " · 00:00 至今")
                    .font(.system(size: 10)).foregroundStyle(Palette.dim)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(PulseFormat.tokens(store.todayTokens)).font(.system(size: 32, weight: .medium, design: .rounded)).monospacedDigit()
                Text("Tokens").font(.system(size: 12)).foregroundStyle(Palette.dim)
                Spacer()
                if let value = store.todayTokens {
                    Text(value.formatted() + " Tokens").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.dim).textSelection(.enabled)
                }
            }
            HStack(spacing: 20) {
                item("输入（含缓存）", value: snapshot?.totals.input)
                item("其中缓存输入", value: snapshot?.totals.cachedInput)
                item("输出", value: snapshot?.totals.output)
                item("请求次数", value: snapshot.map { Int64($0.requestCount) }, tokens: false)
            }
            Rectangle().fill(Palette.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("按本机时区统计 · 每 10 秒更新")
                    Spacer()
                    Text(snapshot.map { "更新于 " + $0.updatedAt.formatted(.dateTime.hour().minute().second()) } ?? "正在读取…")
                }
                Text("包含这台 Mac 的 Codex 本地记录（所有账号）；不含其他设备或未保存在本机的云端任务。")
                Text("总用量 = 输入 + 输出，缓存输入已包含在输入中。Token 数不等于订阅额度扣减。")
                if snapshot?.isAvailable == false || snapshot?.isPartial == true || snapshot?.usesLegacyEstimates == true {
                    Text(store.todayNote).foregroundStyle(Palette.amber)
                }
            }.font(.system(size: 9)).foregroundStyle(Palette.dim)
        }.pulseCard(padding: 20)
    }
    private func item(_ title: String, value: Int64?, tokens: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10)).foregroundStyle(Palette.dim)
            Text(snapshot?.isAvailable == true ? (tokens ? PulseFormat.tokens(value) : value.map { $0.formatted() } ?? "—") : "—")
                .font(.system(size: 17, weight: .medium, design: .rounded)).monospacedDigit()
                .help(value.map { $0.formatted() + (tokens ? " Tokens" : " 次") } ?? "暂无记录")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
