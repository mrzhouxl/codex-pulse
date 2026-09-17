import AppKit
import Combine
import CryptoKit
import PulseCore
import ServiceManagement
import UserNotifications

@MainActor
final class PulseStore: ObservableObject {
    @Published var limits: LimitsResponse?
    @Published var usage: UsageResponse?
    @Published var account: AccountResponse.Account?
    @Published var lastUpdated: Date?
    @Published var usageUpdated: Date?
    @Published var error: String?
    @Published var usageError: String?
    @Published var localUsage: LocalUsageSnapshot?
    @Published var isReadingLocalUsage = false
    @Published var isRefreshing = false
    @Published var isCached = false
    @Published var isLoggingIn = false
    @Published var selectedID = "codex"
    @Published var page = "overview"
    @Published var historyDays = 7
    @Published var now = Date()
    @Published var settingsMessage: String?
    @Published var railOnRight = true
    @Published var showRail: Bool { didSet { defaults.set(showRail, forKey: "showRail") } }
    @Published var railOpacity: Double { didSet { defaults.set(railOpacity, forKey: "railOpacity") } }
    @Published var refreshSeconds: Double { didSet { defaults.set(refreshSeconds, forKey: "refreshSeconds") } }
    @Published var showMenuPercent: Bool { didSet { defaults.set(showMenuPercent, forKey: "showMenuPercent") } }
    @Published var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") } }
    @Published var customExecutable: String { didSet { defaults.set(customExecutable, forKey: "customExecutable") } }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    let client = CodexClient()
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private let localReader = LocalUsageReader()
    private var localUsageTask: Task<Void, Never>?
    private var lastLocalRead = Date.distantPast
    private var lastAttempt = Date.distantPast
    private var identity = ""
    private var accountSignature: String?
    private var accountRevision = 0
    private var needsRefresh = false
    private var loginID: String?
    private var wakeObserver: NSObjectProtocol?
    private let dataURL: URL
    var testingExecutable: String?
    var onShowDashboard: (() -> Void)?
    var onShowDetails: (() -> Void)?
    var onHideDetails: (() -> Void)?
    var onResetRail: (() -> Void)?

    init() {
        showRail = defaults.object(forKey: "showRail") as? Bool ?? true
        railOpacity = defaults.object(forKey: "railOpacity") as? Double ?? 0.98
        refreshSeconds = defaults.object(forKey: "refreshSeconds") as? Double ?? 60
        showMenuPercent = defaults.object(forKey: "showMenuPercent") as? Bool ?? true
        notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        customExecutable = defaults.string(forKey: "customExecutable") ?? ""
        let args = CommandLine.arguments
        if args.contains("--smoke-test"), let index = args.firstIndex(of: "--test-codex"), args.indices.contains(index + 1) {
            testingExecutable = args[index + 1]
            dataURL = FileManager.default.temporaryDirectory.appendingPathComponent("PulseTest-" + UUID().uuidString)
        } else {
            dataURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Codex Pulse", isDirectory: true)
        }
    }
    var buckets: [QuotaBucket] { limits?.buckets ?? [] }
    var selected: QuotaBucket? { buckets.first { $0.id == selectedID } ?? buckets.first }
    var primary: QuotaBucket? { buckets.first { $0.id == "codex" } ?? buckets.first }
    var planLabel: String { account?.planType?.uppercased() ?? "未连接" }
    var statusLabel: String {
        if isRefreshing { return "正在同步" }
        if error != nil { return limits == nil ? "连接待恢复" : "显示上次数据" }
        if isCached { return "本地缓存" }
        guard let lastUpdated else { return "等待连接" }
        let seconds = now.timeIntervalSince(lastUpdated)
        if seconds < 60 { return "刚刚更新" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前更新" }
        return "\(Int(seconds / 3600)) 小时前更新"
    }
    var isStale: Bool { isCached || error != nil || (lastUpdated.map { now.timeIntervalSince($0) > max(180, refreshSeconds * 2) } ?? true) }
    var currentDays: [UsageDay] { usage?.days(historyDays, now: now) ?? [] }
    var periodTokens: Int64? {
        let values = currentDays.compactMap(\.tokens)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
    var latestUsage: DailyUsage? { usage?.dailyUsageBuckets?.max { $0.startDate < $1.startDate } }
    var todayUsage: LocalUsageSnapshot? {
        guard let localUsage, Calendar.current.isDate(localUsage.dayStart, inSameDayAs: now) else { return nil }
        return localUsage
    }
    var todayTokens: Int64? { todayUsage.flatMap { $0.isAvailable ? $0.totals.total : nil } }
    var todayNote: String {
        guard let snapshot = todayUsage else { return "正在读取本机记录…" }
        if !snapshot.isAvailable { return "未找到本机用量记录" }
        if snapshot.isPartial { return "部分记录暂未读取 · 含缓存" }
        if snapshot.usesLegacyEstimates { return "本机估算 · 含缓存输入" }
        return "本机 · 今日零点起 · 含缓存"
    }

    func start() {
        client.onNotification = { [weak self] method in
            guard let self else { return }
            if method == "account/login/completed" { self.isLoggingIn = false; self.loginID = nil; self.refresh() }
            if method == "account/updated" {
                self.accountRevision += 1
                self.clearAccountData(); self.refresh()
            }
            if method == "account/rateLimits/updated", Date().timeIntervalSince(self.lastAttempt) > 3 { self.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }; self.now = Date()
                if self.now.timeIntervalSince(self.lastLocalRead) >= 10 { self.refreshLocalUsage() }
                if self.now.timeIntervalSince(self.lastAttempt) >= self.refreshSeconds { self.refresh() }
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }
    func refresh() {
        refreshLocalUsage()
        guard !isRefreshing else { needsRefresh = true; return }
        isRefreshing = true; lastAttempt = Date()
        refreshTask = Task { await load() }
    }
    private func refreshLocalUsage() {
        guard !isReadingLocalUsage else { return }
        isReadingLocalUsage = true; lastLocalRead = Date()
        let args = CommandLine.arguments
        let testRoot = args.contains("--smoke-test") ? args.firstIndex(of: "--test-usage-root").flatMap {
            args.indices.contains($0 + 1) ? args[$0 + 1] : nil
        } : nil
        let root: URL
        if let testRoot { root = URL(fileURLWithPath: testRoot, isDirectory: true) }
        else if testingExecutable != nil { root = dataURL.appendingPathComponent("test-codex-home") }
        else if let path = ProcessInfo.processInfo.environment["CODEX_HOME"], !path.isEmpty {
            root = URL(fileURLWithPath: path, isDirectory: true)
        } else { root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex") }
        localUsageTask = Task {
            let result = await localReader.scan(root: root)
            guard !Task.isCancelled else { return }
            localUsage = result; isReadingLocalUsage = false
        }
    }
    private func load() async {
        let revision = accountRevision
        defer {
            isRefreshing = false
            if needsRefresh { needsRefresh = false; refresh() }
        }
        do {
            try await client.connect(custom: testingExecutable ?? customExecutable)
            let response: AccountResponse = try await client.request("account/read", params: ["refreshToken": false])
            guard revision == accountRevision else { return }
            guard let account = response.account else { clearAccountData(); throw PulseError.notSignedIn }
            guard ["chatgpt", "chatgptAuthTokens", "agentIdentity", "personalAccessToken"].contains(account.type) else {
                clearAccountData(); throw PulseError.unsupportedAccount
            }
            let signature = account.email.map { Self.hash($0.lowercased()) }
            if let accountSignature, accountSignature != signature { clearAccountData() }
            accountSignature = signature
            self.account = account
            let responseLimits: LimitsResponse = try await client.request("account/rateLimits/read")
            guard revision == accountRevision else { return }
            // Scope caches by the authoritative workspace account, never just an email.
            // Cold-start caches are read only after the server confirms this identity.
            let key = responseLimits.accountId.map(Self.hash) ?? signature
            guard let key else { throw PulseError.invalidResponse }
            if identity != key {
                clearAccountData(); identity = key; accountSignature = signature; self.account = account
                restoreCache()
            }
            limits = responseLimits; lastUpdated = Date(); now = Date(); isCached = false; error = nil
            if !buckets.contains(where: { $0.id == selectedID }) { selectedID = buckets.first?.id ?? "codex" }
            checkAlerts(); saveCache()
            do {
                let responseUsage: UsageResponse = try await client.request("account/usage/read")
                guard revision == accountRevision else { return }
                usage = responseUsage; usageUpdated = Date(); usageError = nil; saveCache()
            } catch { if revision == accountRevision { usageError = error.localizedDescription } }
        } catch { if revision == accountRevision { self.error = error.localizedDescription } }
    }
    private func clearAccountData() {
        limits = nil; usage = nil; lastUpdated = nil; usageUpdated = nil; account = nil
        identity = ""; accountSignature = nil; isCached = false; usageError = nil
    }
    private static func hash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private var cacheURL: URL { dataURL.appendingPathComponent("snapshot-\(identity).json") }
    private func restoreCache() {
        guard let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(CachedSnapshot.self, from: data), cache.identity == identity else { return }
        limits = cache.limits; lastUpdated = cache.limitsUpdatedAt; usage = cache.usage; usageUpdated = cache.usageUpdatedAt; isCached = true
    }
    private func saveCache() {
        guard let limits, let lastUpdated, !identity.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let snapshot = CachedSnapshot(identity: identity, limits: limits, limitsUpdatedAt: lastUpdated, usage: usage, usageUpdatedAt: usageUpdated)
            try JSONEncoder().encode(snapshot).write(to: cacheURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        } catch { settingsMessage = "数据已同步，但本地缓存暂时无法保存。" }
    }
    func setNotifications(_ enabled: Bool) {
        guard enabled else { notificationsEnabled = false; return }
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                notificationsEnabled = granted
                if !granted { settingsMessage = "请在系统设置 → 通知 → Codex Pulse 中允许通知。" }
            } catch { settingsMessage = "通知权限暂不可用：\(error.localizedDescription)" }
        }
    }
    private func checkAlerts() {
        guard notificationsEnabled, !isCached, let limits, limits.ordinaryUsageAllowed != nil else { return }
        var sent = Set(defaults.stringArray(forKey: "sentAlerts") ?? [])
        for bucket in buckets {
            let keys = QuotaAlerts.keys(identity: identity, bucket: bucket)
            let fresh = keys.filter { !sent.contains($0) }
            guard !fresh.isEmpty else { continue }
            let remaining = bucket.limitingWindow?.remaining
            let content = UNMutableNotificationContent()
            content.title = "\(bucket.title) 额度提醒"
            content.body = "剩余 \(PulseFormat.percent(remaining))。\(bucket.limitingWindow?.countdown(at: now) ?? "")"
            content.sound = .default
            let request = UNNotificationRequest(identifier: Self.hash(fresh.joined()), content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
            sent.formUnion(keys)
        }
        defaults.set(Array(sent.sorted().suffix(1000)), forKey: "sentAlerts")
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                settingsMessage = "请在系统设置 → 通用 → 登录项中允许 Codex Pulse。"
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { settingsMessage = "无法更改开机启动：\(error.localizedDescription)"; launchAtLogin = SMAppService.mainApp.status == .enabled }
    }
    func chooseExecutable() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "选择 Codex 可执行程序"; panel.message = "可选择 Codex 应用内 Contents/Resources/codex。"
        if panel.runModal() == .OK, let url = panel.url, FileManager.default.isExecutableFile(atPath: url.path) {
            customExecutable = url.path; client.stop(); refresh()
        }
    }
    func login() {
        guard !isLoggingIn else { return }
        isLoggingIn = true
        Task {
            do {
                try await client.connect(custom: testingExecutable ?? customExecutable)
                struct Login: Decodable { let authUrl: String?; let loginId: String? }
                let result: Login = try await client.request("account/login/start", params: ["type": "chatgpt"])
                guard let text = result.authUrl, let url = URL(string: text), url.scheme == "https",
                    let host = url.host, host == "auth.openai.com" || host.hasSuffix(".openai.com") || host == "chatgpt.com" else { throw PulseError.invalidResponse }
                loginID = result.loginId; NSWorkspace.shared.open(url)
            } catch { isLoggingIn = false; self.error = error.localizedDescription }
        }
    }
    func cancelLogin() {
        guard let loginID else { isLoggingIn = false; return }
        Task {
            struct Empty: Decodable {}
            let _: Empty? = try? await client.request("account/login/cancel", params: ["loginId": loginID])
            self.loginID = nil; isLoggingIn = false
        }
    }
    func exportCSV() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Codex-Pulse-用量.csv"
        panel.title = "导出官方用量记录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rows = (usage?.dailyUsageBuckets ?? []).sorted { $0.startDate < $1.startDate }
        let csv = "\u{FEFF}日期,Token 用量\n" + rows.map { "\($0.startDate),\($0.tokens)" }.joined(separator: "\n")
        do { try csv.write(to: url, atomically: true, encoding: .utf8); settingsMessage = "用量记录已导出。" }
        catch { settingsMessage = "导出失败：\(error.localizedDescription)" }
    }
    func stop() {
        timer?.invalidate(); refreshTask?.cancel(); localUsageTask?.cancel(); client.stop()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
}
