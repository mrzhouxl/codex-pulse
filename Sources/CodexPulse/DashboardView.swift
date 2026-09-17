import SwiftUI
import Charts
import PulseCore

struct DashboardView: View {
    @ObservedObject var store: PulseStore
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 198)
            Rectangle().fill(Palette.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 18)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let error = store.error { errorBanner(error) }
                        switch store.page {
                        case "history": HistoryView(store: store)
                        case "settings": SettingsView(store: store)
                        default:
                            if store.selected == nil { TodayUsageDetail(store: store) }
                            overview
                        }
                    }.padding(.horizontal, 28).padding(.bottom, 24)
                }.scrollIndicators(.hidden)
                footer
            }
        }.background(Palette.bg).foregroundStyle(Palette.white).preferredColorScheme(.dark)
            .frame(minWidth: 940, minHeight: 690)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                PulseMark(size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex Pulse").font(.system(size: 15, weight: .semibold))
                    Text("让每一份额度，都有数。").font(.system(size: 9)).foregroundStyle(Palette.dim)
                }
            }.padding(.top, 50).padding(.bottom, 38)
            Text("工作空间").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.dim).padding(.leading, 10).padding(.bottom, 12)
            nav("overview", "额度概览", "square.grid.2x2")
            nav("history", "用量统计", "chart.bar.xaxis")
            nav("settings", "偏好设置", "slider.horizontal.3")
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "lock.shield").font(.system(size: 12))
                    Text("只属于你的用量记录").font(.system(size: 10, weight: .medium))
                }.foregroundStyle(Palette.accent.opacity(0.8))
                Text("官方数据 · 本地保存\n随时了解你的创作节奏")
                    .font(.system(size: 10)).foregroundStyle(Palette.dim).lineSpacing(5)
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 9) {
                ZStack { Circle().fill(Palette.raised); Image(systemName: "person.crop.circle").foregroundStyle(Palette.dim) }.frame(width: 29, height: 29)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.account == nil ? "连接你的账号" : "ChatGPT 账号").font(.system(size: 11, weight: .medium))
                    Text(store.planLabel).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(Palette.dim)
                }
            }.padding(.top, 23).padding(.bottom, 22)
        }.padding(.horizontal, 18).background(Color.white.opacity(0.012))
    }
    private func nav(_ id: String, _ title: String, _ symbol: String) -> some View {
        Button { store.page = id } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 13)).frame(width: 16)
                Text(title).font(.system(size: 12, weight: store.page == id ? .semibold : .regular))
                Spacer()
                if store.page == id { Circle().fill(Palette.accent).frame(width: 4, height: 4) }
            }.foregroundStyle(store.page == id ? Palette.accent : Palette.dim)
                .padding(.horizontal, 12).padding(.vertical, 12)
                .background(store.page == id ? Palette.accent.opacity(0.085) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).padding(.bottom, 5)
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(store.page == "history" ? "USAGE ANALYTICS" : store.page == "settings" ? "MAKE IT YOURS" : "YOUR CODING COMPANION")
                    .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(Palette.dim)
                Text(store.page == "history" ? "每一份投入，都看得见。" : store.page == "settings" ? "按照你的习惯。" : "心中有数，专注创造。")
                    .font(.system(size: 24, weight: .semibold))
            }
            Spacer()
            ActionButton(title: store.isRefreshing ? "同步中" : "刷新数据", symbol: "arrow.clockwise") { store.refresh() }.disabled(store.isRefreshing)
        }
    }
    @ViewBuilder private var overview: some View {
        if let bucket = store.selected {
            HStack(spacing: 8) {
                ForEach(store.buckets) { item in
                    Button { store.selectedID = item.id } label: {
                        HStack(spacing: 6) { Image(systemName: item.symbol); Text(item.title) }
                            .font(.system(size: 11, weight: .medium)).padding(.horizontal, 13).padding(.vertical, 8)
                            .foregroundStyle(bucket.id == item.id ? Palette.bg : Palette.dim)
                            .background(bucket.id == item.id ? Palette.accent : Palette.panel, in: Capsule())
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("账户级额度").font(.system(size: 10)).foregroundStyle(Palette.dim)
            }
            hero(bucket)
            HStack(spacing: 12) {
                TodayUsageMetric(store: store)
                MetricCard(label: "累计 Token 用量", value: PulseFormat.tokens(store.usage?.summary.lifetimeTokens), note: "官方累计统计", symbol: "square.stack.3d.up")
                MetricCard(label: "连续活跃", value: store.usage?.summary.currentStreakDays.map { "\($0)" } ?? "—", note: "天 · 保持创作节奏", symbol: "flame")
            }
            UsageChartCard(store: store, compact: true)
        } else if store.isRefreshing {
            VStack(spacing: 18) {
                ProgressView().controlSize(.large).tint(Palette.accent)
                Text("正在连接你的 Codex").font(.system(size: 17, weight: .medium))
                Text("读取账号额度与用量记录…").font(.system(size: 12)).foregroundStyle(Palette.dim)
            }.frame(maxWidth: .infinity, minHeight: 380).pulseCard()
        } else {
            VStack(spacing: 18) {
                PulseMark(size: 56)
                Text("连接 Codex，开始掌握用量。").font(.system(size: 20, weight: .medium))
                Text("使用本机已登录的 ChatGPT 账号，\n自动同步额度、重置时间与历史记录。")
                    .font(.system(size: 12)).foregroundStyle(Palette.dim).multilineTextAlignment(.center).lineSpacing(6)
                ActionButton(title: store.isLoggingIn ? "取消登录" : "登录 ChatGPT", symbol: "arrow.up.right", primary: true) {
                    if store.isLoggingIn { store.cancelLogin() } else { store.login() }
                }
                if store.isLoggingIn { Text("请在浏览器中完成官方登录。").font(.system(size: 11)).foregroundStyle(Palette.dim) }
            }.frame(maxWidth: .infinity, minHeight: 380).pulseCard()
        }
    }
    private func hero(_ bucket: QuotaBucket) -> some View {
        HStack(spacing: 30) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: bucket.symbol).font(.system(size: 20, weight: .medium))
                    Text(bucket.title).font(.system(size: 20, weight: .semibold))
                    Text(bucket.isRestricted || store.limits?.ordinaryUsageAllowed == false ? "额度受限" : store.isStale ? "待同步" : "已同步")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(bucket.isRestricted ? Palette.amber : Palette.accent)
                        .padding(.horizontal, 8).padding(.vertical, 4).background(Palette.accent.opacity(0.09), in: Capsule())
                    Spacer()
                }
                if bucket.windows.isEmpty {
                    Text("官方暂未提供此额度组的百分比").font(.system(size: 12)).foregroundStyle(Palette.dim)
                }
                ForEach(Array(bucket.windows.enumerated()), id: \.offset) { _, window in
                    QuotaBar(window: window, now: store.now)
                }
                HStack(spacing: 5) {
                    Image(systemName: "clock").font(.system(size: 10))
                    Text(bucket.limitingWindow?.resetDate.map { "下次重置  " + $0.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()) } ?? "重置时间由官方提供")
                        .font(.system(size: 10))
                }.foregroundStyle(Palette.dim)
            }
            VStack(spacing: 12) {
                QuotaRing(remaining: bucket.limitingWindow?.remaining, size: 124, line: 7, muted: store.isStale)
                Text(bucket.windows.count > 1 ? "以剩余最少的周期为准" : bucket.subtitle)
                    .font(.system(size: 9)).foregroundStyle(Palette.dim).lineLimit(1)
            }.frame(width: 150)
        }.padding(22)
            .background {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 20).fill(Palette.panel)
                    RadialGradient(colors: [Palette.accent.opacity(0.07), .clear], center: .topTrailing, startRadius: 0, endRadius: 310)
                }.clipShape(RoundedRectangle(cornerRadius: 20))
            }.overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Palette.accent.opacity(0.16)))
    }
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.circle")
            Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if store.limits == nil { Button("登录") { store.login() }.buttonStyle(.plain) }
        }.foregroundStyle(Palette.amber).padding(12).background(Palette.amber.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
    private var footer: some View {
        HStack {
            StatusDot(store: store)
            Spacer()
            Text("Codex 官方数据  ·  Token 统计与订阅额度分别计量").font(.system(size: 9)).foregroundStyle(Palette.dim)
        }.padding(.horizontal, 28).padding(.vertical, 13).overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

struct MetricCard: View {
    let label: String
    let value: String
    let note: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { Text(label).font(.system(size: 10)); Spacer(); Image(systemName: symbol).font(.system(size: 12)) }.foregroundStyle(Palette.dim)
            Text(value).font(.system(size: 27, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(note).font(.system(size: 9)).foregroundStyle(Palette.dim).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).pulseCard(padding: 17)
    }
}

struct UsageChartCard: View {
    @ObservedObject var store: PulseStore
    var compact = false
    @State private var hovered: UsageDay?
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("官方历史趋势").font(.system(size: 13, weight: .semibold))
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(hovered.map { PulseFormat.tokens($0.tokens) } ?? PulseFormat.tokens(store.periodTokens))
                            .font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit()
                        Text(hovered.map { "Tokens · \($0.shortLabel)" } ?? "Tokens · 近 \(store.historyDays) 天")
                            .font(.system(size: 10)).foregroundStyle(Palette.dim)
                    }
                }
                Spacer()
                HStack(spacing: 2) {
                    ForEach([7, 30], id: \.self) { days in
                        Button { store.historyDays = days; hovered = nil } label: {
                            Text("\(days) 天").font(.system(size: 10, weight: .medium)).padding(.horizontal, 11).padding(.vertical, 6)
                                .foregroundStyle(store.historyDays == days ? Palette.white : Palette.dim)
                                .background(store.historyDays == days ? Palette.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                }.padding(3).background(Palette.bg, in: RoundedRectangle(cornerRadius: 8))
            }
            if store.currentDays.contains(where: { $0.tokens != nil }) {
                Chart(store.currentDays) { day in
                    if let tokens = day.tokens {
                        BarMark(x: .value("日期", day.shortLabel), y: .value("Tokens", Double(tokens)), width: .ratio(0.45))
                            .foregroundStyle(LinearGradient(colors: [Palette.accent.opacity(0.9), Palette.accent.opacity(0.32)], startPoint: .top, endPoint: .bottom))
                            .cornerRadius(3)
                            .opacity(hovered == nil || hovered?.id == day.id ? 1 : 0.4)
                            .accessibilityLabel("\(day.key)，\(tokens) Tokens")
                    } else {
                        PointMark(x: .value("日期", day.shortLabel), y: .value("Tokens", 0)).symbolSize(9).foregroundStyle(Palette.dim.opacity(0.4))
                            .accessibilityLabel("\(day.key)，暂无记录")
                    }
                }
                .chartXAxis {
                    AxisMarks(values: store.currentDays.enumerated().filter { store.historyDays == 7 || $0.offset % 5 == 0 || $0.offset == store.historyDays - 1 }.map { $0.element.shortLabel }) { _ in
                        AxisValueLabel().font(.system(size: 9)).foregroundStyle(Palette.dim)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4])).foregroundStyle(Palette.line)
                        AxisValueLabel { if let n = value.as(Double.self) { Text(PulseFormat.tokens(Int64(n))).font(.system(size: 8)).foregroundStyle(Palette.dim) } }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let point):
                                    guard let frame = proxy.plotFrame else { return }
                                    let x = point.x - geometry[frame].origin.x
                                    if let label: String = proxy.value(atX: x) { hovered = store.currentDays.first { $0.shortLabel == label } }
                                case .ended: hovered = nil
                                }
                            }
                    }
                }.frame(height: compact ? 88 : 215)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 25)).foregroundStyle(Palette.dim)
                    Text(store.isRefreshing ? "正在同步用量…" : "这个时段暂无官方记录").font(.system(size: 12)).foregroundStyle(Palette.dim)
                }.frame(maxWidth: .infinity, minHeight: compact ? 100 : 215)
            }
            HStack {
                Circle().fill(Palette.accent).frame(width: 4, height: 4)
                Text("官方每日 Token 记录").font(.system(size: 9))
                Spacer()
                Text(store.usageError != nil ? "同步未成功 · 保留上次记录" : "按服务返回日期 · 无记录不代表零用量").font(.system(size: 9))
            }.foregroundStyle(store.usageError != nil ? Palette.amber : Palette.dim)
        }.pulseCard(padding: compact ? 18 : 20)
    }
}

struct HistoryView: View {
    @ObservedObject var store: PulseStore
    var body: some View {
        VStack(spacing: 20) {
            TodayUsageDetail(store: store)
            HStack(spacing: 12) {
                MetricCard(label: "累计 Token 用量", value: PulseFormat.tokens(store.usage?.summary.lifetimeTokens), note: "账号官方累计记录", symbol: "square.stack.3d.up")
                MetricCard(label: "单日最高用量", value: PulseFormat.tokens(store.usage?.summary.peakDailyTokens), note: "Tokens / 天", symbol: "chart.line.uptrend.xyaxis")
                MetricCard(label: "最长连续活跃", value: store.usage?.summary.longestStreakDays.map { "\($0) 天" } ?? "—", note: "每天积累一点", symbol: "flame")
            }
            UsageChartCard(store: store)
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("每日明细").font(.system(size: 13, weight: .semibold)); Spacer()
                    ActionButton(title: "导出 CSV", symbol: "square.and.arrow.up") { store.exportCSV() }.disabled(store.usage?.dailyUsageBuckets == nil)
                }
                ForEach(store.currentDays.reversed()) { day in
                    HStack {
                        Text(day.key).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.dim)
                        Spacer()
                        Text(day.tokens.map { $0.formatted() + " Tokens" } ?? "暂无记录").font(.system(size: 11)).monospacedDigit()
                    }.padding(.vertical, 5)
                }
                if store.currentDays.isEmpty { Text("连接账号后，这里会展示官方返回的用量记录。").font(.system(size: 12)).foregroundStyle(Palette.dim) }
            }.pulseCard()
        }
    }
}
