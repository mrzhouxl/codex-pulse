import AppKit
import SwiftUI
import Combine
import UserNotifications
import PulseCore
import Darwin

@main
enum CodexPulseApp {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        var instanceLock: SingleInstanceLock?
        if !CommandLine.arguments.contains("--smoke-test") {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Codex Pulse", isDirectory: true)
            do {
                guard let lock = try SingleInstanceLock.acquire(at: directory.appendingPathComponent("instance.lock")) else {
                    DistributedNotificationCenter.default().postNotificationName(.pulseShowExisting, object: "app.codexpulse.mac", userInfo: nil, deliverImmediately: true)
                    print("PULSE_ALREADY_RUNNING")
                    return
                }
                instanceLock = lock
            } catch {
                let alert = NSAlert()
                alert.messageText = "Codex Pulse 暂时无法启动"
                alert.informativeText = "无法访问应用数据目录，请检查权限后重试。\n\(error.localizedDescription)"
                alert.runModal()
                return
            }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
        withExtendedLifetime(instanceLock) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let store = PulseStore()
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var rail: NSPanel!
    private var detail: NSPanel!
    private let popover = NSPopover()
    private var observations = Set<AnyCancellable>()
    private var globalMouseMonitor: Any?
    private var localEventMonitor: Any?
    private var railCount = -1
    private var lastMenuValue = ""
    private var railOrderCount = 0
    private var smokeMode = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        smokeMode = CommandLine.arguments.contains("--smoke-test")
        makeMenu(); makeStatusItem(); makeWindows()
        UNUserNotificationCenter.current().delegate = self
        store.onShowDashboard = { [weak self] in self?.showDashboard() }
        store.onShowDetails = { [weak self] in self?.showRailDetail() }
        store.onHideDetails = { [weak self] in self?.hideDetails() }
        store.onResetRail = { [weak self] in self?.placeRail(reset: true) }
        store.objectWillChange.debounce(for: .milliseconds(60), scheduler: RunLoop.main).sink { [weak self] _ in
            self?.updateChrome()
        }.store(in: &observations)
        NotificationCenter.default.addObserver(self, selector: #selector(railDragged), name: .pulseRailDragged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showExistingInstance(_:)), name: .pulseShowExisting, object: "app.codexpulse.mac")
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hideDetails() }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53, self.detail.isVisible {
                self.hideDetails(); return nil
            }
            if event.type != .keyDown, event.window !== self.detail, event.window !== self.rail {
                self.detail.orderOut(nil)
            }
            return event
        }
        updateChrome()
        store.start()
        let firstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunched")
        UserDefaults.standard.set(true, forKey: "hasLaunched")
        if firstLaunch || CommandLine.arguments.contains("--show") || smokeMode { showDashboard() }
        if smokeMode { runSmokeTest() }
    }
    private func makeMenu() {
        let menu = NSMenu(), appMenu = NSMenu(), fileMenu = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = appMenu; menu.addItem(appItem)
        appMenu.addItem(withTitle: "关于 Codex Pulse", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "偏好设置…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Codex Pulse", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 Codex Pulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem(title: "文件", action: nil, keyEquivalent: ""); fileItem.submenu = fileMenu; menu.addItem(fileItem)
        fileMenu.addItem(withTitle: "打开主面板", action: #selector(showDashboard), keyEquivalent: "0")
        fileMenu.addItem(withTitle: "刷新数据", action: #selector(refresh), keyEquivalent: "r")
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""), editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu; menu.addItem(editItem)
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu
    }
    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statusItem.button?.imagePosition = .imageLeading
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: CompactDetailView(store: store))
    }
    private func makeWindows() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Codex Pulse"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(Palette.bg)
        window.minSize = NSSize(width: 960, height: 710); window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DashboardView(store: store))
        window.delegate = self; window.setFrameAutosaveName("PulseDashboard"); window.center()
        rail = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: RailMetrics.width, height: RailMetrics.height(for: 1)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configurePanel(rail); rail.contentView = NSHostingView(rootView: RailView(store: store))
        detail = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 370, height: 370), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configurePanel(detail); detail.contentView = NSHostingView(rootView: CompactDetailView(store: store))
        detail.contentView?.wantsLayer = true; detail.contentView?.layer?.cornerRadius = 22; detail.contentView?.layer?.masksToBounds = true
        placeRail()
    }
    private func configurePanel(_ panel: NSPanel) {
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
    }
    private func updateChrome() {
        guard statusItem != nil else { return }
        let remaining = store.primary?.limitingWindow?.remaining
        let value = "\(remaining ?? -1)-\(store.isStale)-\(store.showMenuPercent)"
        if value != lastMenuValue {
            lastMenuValue = value
            statusItem.button?.image = menuImage(remaining: remaining, stale: store.isStale)
            statusItem.button?.title = store.showMenuPercent ? " " + PulseFormat.percent(remaining) : ""
        }
        statusItem.button?.toolTip = "Codex Pulse · 剩余 \(PulseFormat.percent(remaining)) · \(store.statusLabel)"
        statusItem.button?.setAccessibilityLabel("Codex Pulse，剩余 \(PulseFormat.percent(remaining))，\(store.statusLabel)")
        let count = max(1, min(4, store.buckets.count))
        if count != railCount {
            railCount = count
            let height = RailMetrics.height(for: count)
            rail.setFrame(NSRect(x: rail.frame.minX, y: rail.frame.midY - height / 2, width: RailMetrics.width, height: height), display: true)
            placeRail()
        }
        if rail.alphaValue != store.railOpacity { rail.alphaValue = store.railOpacity }
        // Data/countdown updates must never reorder visible windows.
        if store.showRail {
            if !rail.isVisible { rail.orderFrontRegardless(); railOrderCount += 1 }
        } else {
            if rail.isVisible { rail.orderOut(nil) }
            if detail.isVisible { detail.orderOut(nil) }
        }
        if detail.isVisible { positionDetail() }
    }
    private func menuImage(remaining: Double?, stale: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)); circle.lineWidth = 2
            NSColor.labelColor.withAlphaComponent(0.2).setStroke(); circle.stroke()
            if let remaining, remaining > 0 {
                let arc = NSBezierPath(); arc.lineWidth = 2; arc.lineCapStyle = .round
                arc.appendArc(withCenter: NSPoint(x: 10, y: 10), radius: 7, startAngle: 90, endAngle: 90 - CGFloat(remaining / 100) * 360, clockwise: true)
                NSColor.labelColor.withAlphaComponent(stale ? 0.45 : 1).setStroke(); arc.stroke()
            }
            NSColor.labelColor.setFill(); NSBezierPath(ovalIn: NSRect(x: 8.5, y: 8.5, width: 3, height: 3)).fill()
            return true
        }
        image.isTemplate = true; return image
    }
    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "打开主面板", action: #selector(showDashboard), keyEquivalent: "")
            menu.addItem(withTitle: "刷新数据", action: #selector(refresh), keyEquivalent: "")
            menu.addItem(withTitle: store.showRail ? "隐藏悬浮条" : "显示悬浮条", action: #selector(toggleRail), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 Codex Pulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            menu.items.forEach { $0.target = self }
            menu.items.last?.target = NSApp
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
        } else if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem.button { detail.orderOut(nil); popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
    @objc func showDashboard() {
        hideDetails(); NSApp.setActivationPolicy(.regular); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func showExistingInstance(_ notification: Notification) { showDashboard() }
    @objc private func showSettings() { store.page = "settings"; showDashboard() }
    @objc private func refresh() { store.refresh() }
    @objc private func toggleRail() { store.showRail.toggle() }
    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Codex Pulse", .applicationVersion: "1.4", .credits: NSAttributedString(string: "你的 Codex 用量，心中有数。\n独立的本地用量查看工具。")])
    }
    private func showRailDetail() {
        popover.performClose(nil); positionDetail(); detail.makeKeyAndOrderFront(nil)
    }
    private func positionDetail() {
        let screen = rail.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let size = detail.contentView?.fittingSize ?? NSSize(width: 370, height: 380)
        let height = min(visible.height - 30, max(260, size.height))
        let onRight = rail.frame.midX > visible.midX
        let x = onRight ? rail.frame.minX - 384 : rail.frame.maxX + 14
        let y = min(visible.maxY - height - 12, max(visible.minY + 12, rail.frame.midY - height / 2))
        let target = NSRect(x: min(visible.maxX - 382, max(visible.minX + 12, x)), y: y, width: 370, height: height)
        if detail.frame != target { detail.setFrame(target, display: true) }
    }
    private func hideDetails() { popover.performClose(nil); detail.orderOut(nil) }
    @objc private func railDragged() {
        guard let screen = rail.screen ?? NSScreen.main else { return }
        attachRail(to: screen, onRight: rail.frame.midX >= screen.frame.midX, y: rail.frame.minY)
        UserDefaults.standard.set(NSStringFromPoint(rail.frame.origin), forKey: "railOrigin")
        if detail.isVisible { positionDetail() }
    }
    @objc private func screenChanged() { placeRail(); if detail.isVisible { positionDetail() } }
    private func placeRail(reset: Bool = false) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        var targetScreen = screen
        var onRight = true
        var y = screen.visibleFrame.midY - rail.frame.height / 2
        if !reset, let saved = UserDefaults.standard.string(forKey: "railOrigin") {
            let candidate = NSPointFromString(saved)
            if let target = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: candidate.x + RailMetrics.width / 2, y: candidate.y + 10)) }) {
                targetScreen = target
                onRight = candidate.x + RailMetrics.width / 2 >= target.frame.midX
                y = candidate.y
            }
        }
        attachRail(to: targetScreen, onRight: onRight, y: y)
        if reset { UserDefaults.standard.removeObject(forKey: "railOrigin") }
    }
    private func attachRail(to screen: NSScreen, onRight: Bool, y: CGFloat) {
        // Horizontal docking follows the physical screen edge, not the Dock's work area.
        // Vertical clamping still leaves menu-bar and bottom-Dock room.
        let x = onRight ? screen.frame.maxX - RailMetrics.width : screen.frame.minX
        let safeY = max(screen.visibleFrame.minY + 8, min(screen.visibleFrame.maxY - rail.frame.height - 8, y))
        if store.railOnRight != onRight { store.railOnRight = onRight }
        let origin = NSPoint(x: x, y: safeY)
        if rail.frame.origin != origin { rail.setFrameOrigin(origin) }
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === window { NSApp.setActivationPolicy(.accessory) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showDashboard(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        store.stop(); if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        DistributedNotificationCenter.default().removeObserver(self)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor [weak self] in self?.showDashboard() }; completionHandler()
    }

    private func runSmokeTest() {
        Task {
            let deadline = Date().addingTimeInterval(85)
            while (store.isRefreshing || store.isReadingLocalUsage) && Date() < deadline { try? await Task.sleep(nanoseconds: 250_000_000) }
            if CommandLine.arguments.contains("--refresh-again") {
                store.refresh()
                while store.isRefreshing && Date() < deadline { try? await Task.sleep(nanoseconds: 250_000_000) }
            }
            var idleReorders = 0
            if CommandLine.arguments.contains("--verify-window-stability") {
                // Keep the regular one-second clock ticking, with quota data already loaded.
                try? await Task.sleep(nanoseconds: 300_000_000)
                let before = railOrderCount
                try? await Task.sleep(nanoseconds: 5_200_000_000)
                idleReorders = railOrderCount - before
            }
            let output = CommandLine.arguments.firstIndex(of: "--output").flatMap { index in CommandLine.arguments.indices.contains(index + 1) ? CommandLine.arguments[index + 1] : nil }
            var ringReport: [String: Any] = [:]
            if CommandLine.arguments.contains("--verify-ring-animation") {
                let originalSelection = store.selectedID
                showRailDetail()
                ringReport = await RingAnimationDiagnostics.verify(
                    roots: [window.contentView, rail.contentView, detail.contentView].compactMap { $0 },
                    select: { self.store.selectedID = $0 },
                    bucketIDs: store.buckets.map(\.id))
                store.selectedID = originalSelection
            }
            if let output {
                let directory = URL(fileURLWithPath: output, isDirectory: true)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? await Task.sleep(nanoseconds: 700_000_000)
                capture(window.contentView, to: directory.appendingPathComponent("overview.png"))
                store.page = "history"
                try? await Task.sleep(nanoseconds: 300_000_000)
                capture(window.contentView, to: directory.appendingPathComponent("history.png"))
                store.page = "settings"
                try? await Task.sleep(nanoseconds: 300_000_000)
                capture(window.contentView, to: directory.appendingPathComponent("settings.png"))
                store.page = "overview"
                showRailDetail()
                try? await Task.sleep(nanoseconds: 300_000_000)
                capture(rail.contentView, to: directory.appendingPathComponent("rail.png"))
                capture(detail.contentView, to: directory.appendingPathComponent("detail.png"))
                if store.buckets.contains(where: { $0.id == "codex_bengalfox" }) {
                    store.selectedID = "codex_bengalfox"
                    try? await Task.sleep(nanoseconds: 850_000_000)
                    positionDetail()
                    capture(detail.contentView, to: directory.appendingPathComponent("spark-detail.png"))
                }
            }
            var edgeGaps: [String: CGFloat] = [:]
            if let screen = rail.screen ?? NSScreen.main {
                let originalSide = store.railOnRight, originalY = rail.frame.minY
                attachRail(to: screen, onRight: false, y: originalY)
                edgeGaps["left"] = rail.frame.minX - screen.frame.minX
                attachRail(to: screen, onRight: true, y: originalY)
                edgeGaps["right"] = screen.frame.maxX - rail.frame.maxX
                attachRail(to: screen, onRight: originalSide, y: originalY)
            }
            let report: [String: Any] = ["connected": store.limits != nil, "bucketCount": store.buckets.count,
                "railWidth": rail.frame.width, "railHeight": rail.frame.height, "edgeGaps": edgeGaps,
                "idleWindowReorders": idleReorders,
                "ringAnimation": ringReport,
                "dailyRecordCount": store.usage?.dailyUsageBuckets?.count ?? 0,
                "remaining": store.primary?.limitingWindow?.remaining ?? NSNull(),
                "todayLocalTokens": store.todayTokens ?? NSNull(),
                "todayLocalRequests": store.todayUsage?.requestCount ?? 0,
                "todayLocalPartial": store.todayUsage?.isPartial ?? false,
                "todayLocalLegacy": store.todayUsage?.usesLegacyEstimates ?? false,
                "todayLocalInput": store.todayUsage?.totals.input ?? 0,
                "todayLocalCachedInput": store.todayUsage?.totals.cachedInput ?? 0,
                "todayLocalOutput": store.todayUsage?.totals.output ?? 0,
                "todayLocalUpdatedAt": store.todayUsage?.updatedAt.timeIntervalSince1970 ?? 0,
                "latestOfficialDate": store.latestUsage?.startDate ?? "",
                "stale": store.isStale,
                "error": store.error ?? NSNull(), "usageError": store.usageError ?? NSNull()]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys), let text = String(data: data, encoding: .utf8) { print("PULSE_SMOKE " + text) }
            NSApp.terminate(nil)
        }
    }
    private func capture(_ view: NSView?, to url: URL) {
        guard let view else { return }; view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension Notification.Name {
    static let pulseShowExisting = Notification.Name("app.codexpulse.mac.showExisting")
}
