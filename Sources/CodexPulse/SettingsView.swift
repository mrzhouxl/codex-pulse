import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: PulseStore
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("外观与菜单栏", symbol: "circle.lefthalf.filled") {
                setting("外观模式", detail: "可跟随 macOS，也可以固定使用浅色或深色") {
                    Picker("外观模式", selection: $store.appearanceMode) {
                        ForEach(AppAppearanceMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 220)
                }
                Divider().overlay(Palette.line)
                setting("菜单栏显示百分比", detail: "显示 Codex 主要额度组的剩余比例") {
                    Toggle("菜单栏显示百分比", isOn: $store.showMenuPercent).labelsHidden().toggleStyle(.switch).tint(Palette.accent)
                }
            }
            section("同步与提醒", symbol: "arrow.triangle.2.circlepath") {
                setting("自动刷新", detail: "唤醒 Mac 后也会自动同步") {
                    Picker("刷新频率", selection: $store.refreshSeconds) {
                        Text("每 30 秒").tag(30.0); Text("每 60 秒").tag(60.0)
                        Text("每 2 分钟").tag(120.0); Text("每 5 分钟").tag(300.0)
                    }.labelsHidden().frame(width: 130)
                }
                Divider().overlay(Palette.line)
                setting("低额度提醒", detail: "剩余 20% 和 10% 时提醒，每个周期仅提醒一次") {
                    Toggle("低额度提醒", isOn: Binding(get: { store.notificationsEnabled }, set: { store.setNotifications($0) }))
                        .labelsHidden().toggleStyle(.switch).tint(Palette.accent)
                }
                Divider().overlay(Palette.line)
                setting("开机启动", detail: "登录 Mac 后，自动在菜单栏待命") {
                    Toggle("开机启动", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                        .labelsHidden().toggleStyle(.switch).tint(Palette.accent)
                }
            }
            section("连接与数据", symbol: "lock.shield") {
                setting("Codex 连接", detail: store.client.executablePath ?? "自动查找本机 Codex 程序") {
                    ActionButton(title: "选择程序", symbol: "folder") { store.chooseExecutable() }
                }
                Text("登录由官方 Codex 管理；本应用不保存密码或登录令牌。用量缓存仅保存在这台 Mac，切换账号后单独读取。")
                    .font(.system(size: 11)).foregroundStyle(Palette.dim).lineSpacing(5)
                Text("今日用量每 10 秒读取本机记录中的 Token 计数，不保存对话内容。它覆盖本机所有账号，与当前账号的官方历史记录分别展示。")
                    .font(.system(size: 11)).foregroundStyle(Palette.dim).lineSpacing(5)
                HStack {
                    ActionButton(title: "重新连接", symbol: "arrow.clockwise") { store.client.stop(); store.refresh() }.disabled(store.isRefreshing)
                    if !store.customExecutable.isEmpty {
                        Button("恢复自动查找") { store.customExecutable = ""; store.client.stop(); store.refresh() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.accent)
                    }
                    Spacer()
                    Text("Codex Pulse 1.5.0").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.dim)
                }
            }
            if let message = store.settingsMessage {
                HStack {
                    Text(message).font(.system(size: 11)).foregroundStyle(Palette.amber)
                    Spacer(); Button { store.settingsMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(12).background(Palette.raised, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.white)
            content()
        }.pulseCard()
    }
    private func setting<Control: View>(_ title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(Palette.dim).lineLimit(2).textSelection(.enabled)
            }
            Spacer(minLength: 10)
            control()
        }
    }
}
