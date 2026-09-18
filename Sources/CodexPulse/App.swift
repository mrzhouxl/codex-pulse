import AppKit
import SwiftUI
import Combine
import CoreImage
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
    private let popover = NSPopover()
    private var observations = Set<AnyCancellable>()
    private var globalMouseMonitor: Any?
    private var localEventMonitor: Any?
    private var lastMenuValue = ""
    private var smokeMode = false
    private lazy var darkMenuLogo = loadMenuLogo(named: "CodexMenuIconDark")
    private lazy var lightMenuLogo = loadMenuLogo(named: "CodexMenuIconLight")

    private func loadMenuLogo(named name: String) -> (color: NSImage, muted: NSImage)? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let sourceImage = NSImage(contentsOf: url),
              let source = CIImage(contentsOf: url) else { return nil }
        let blue = source.applyingFilter("CIHueAdjust", parameters: [
            kCIInputAngleKey: -0.38
        ]).applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1.08,
            kCIInputContrastKey: 1.03
        ])
        let color = NSImage(size: sourceImage.size)
        color.addRepresentation(NSCIImageRep(ciImage: blue))
        let grayscale = blue.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputBrightnessKey: 0.04
        ])
        let muted = NSImage(size: sourceImage.size)
        muted.addRepresentation(NSCIImageRep(ciImage: grayscale))
        return (color, muted)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store.onAppearanceChanged = { [weak self] mode in self?.applyAppearance(mode) }
        applyAppearance(store.appearanceMode)
        smokeMode = CommandLine.arguments.contains("--smoke-test")
        makeMenu(); makeStatusItem(); makeWindows()
        installPopoverDismissalMonitors()
        UNUserNotificationCenter.current().delegate = self
        store.onShowDashboard = { [weak self] in self?.showDashboard() }
        store.onClosePopover = { [weak self] in self?.popover.performClose(nil) }
        store.objectWillChange.debounce(for: .milliseconds(60), scheduler: RunLoop.main).sink { [weak self] _ in
            self?.updateChrome()
        }.store(in: &observations)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showExistingInstance(_:)), name: .pulseShowExisting, object: "app.codexpulse.mac")
        updateChrome()
        store.start()
        let firstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunched")
        UserDefaults.standard.set(true, forKey: "hasLaunched")
        if firstLaunch || CommandLine.arguments.contains("--show") || smokeMode { showDashboard() }
        if smokeMode { runSmokeTest() }
    }
    private func applyAppearance(_ mode: AppAppearanceMode) {
        let appearance = mode.appKitAppearance
        NSApp.appearance = appearance
        window?.appearance = appearance
        popover.contentViewController?.view.appearance = appearance
        window?.backgroundColor = NSColor(Palette.bg)
        lastMenuValue = ""
        if statusItem != nil { updateChrome() }
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
    }
    private func installPopoverDismissalMonitors() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.popover.isShown else { return }
                self.popover.performClose(nil)
            }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.popover.performClose(nil)
                return nil
            }
            guard event.type != .keyDown else { return event }
            let popoverWindow = self.popover.contentViewController?.view.window
            let statusWindow = self.statusItem.button?.window
            if event.window !== popoverWindow, event.window !== statusWindow {
                self.popover.performClose(nil)
            }
            return event
        }
    }
    func applicationDidResignActive(_ notification: Notification) {
        if popover.isShown { popover.performClose(nil) }
    }
    private func updateChrome() {
        guard statusItem != nil else { return }
        let remaining = store.primary?.limitingWindow?.remaining
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let value = "\(remaining ?? -1)-\(store.isStale)-\(store.showMenuPercent)-\(dark)"
        if value != lastMenuValue {
            lastMenuValue = value
            statusItem.button?.image = menuImage(remaining: remaining, stale: store.isStale)
            statusItem.button?.title = store.showMenuPercent ? " " + PulseFormat.percent(remaining) : ""
        }
        statusItem.button?.toolTip = "Codex Pulse · 剩余 \(PulseFormat.percent(remaining)) · \(store.statusLabel)"
        statusItem.button?.setAccessibilityLabel("Codex Pulse，剩余 \(PulseFormat.percent(remaining))，\(store.statusLabel)")
    }
    private func menuImage(remaining: Double?, stale: Bool) -> NSImage {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let menuLogo = dark ? darkMenuLogo : lightMenuLogo
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
            let iconRect = rect.insetBy(dx: 0.25, dy: 0.25)
            if let logo = menuLogo {
                logo.muted.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: stale ? 0.45 : 0.72)
                if let remaining {
                    let ratio = CGFloat(min(100, max(0, remaining)) / 100)
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(rect: NSRect(x: iconRect.minX, y: iconRect.minY,
                                              width: iconRect.width, height: iconRect.height * ratio)).addClip()
                    logo.color.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: stale ? 0.35 : 1)
                    NSGraphicsContext.restoreGraphicsState()
                }
            } else {
                let fallback = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: nil)
                fallback?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: stale ? 0.45 : 1)
            }
            return true
        }
        image.isTemplate = false; return image
    }
    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "打开主面板", action: #selector(showDashboard), keyEquivalent: "")
            menu.addItem(withTitle: "刷新数据", action: #selector(refresh), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 Codex Pulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            menu.items.forEach { $0.target = self }
            menu.items.last?.target = NSApp
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
        } else if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem.button { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
    @objc func showDashboard() {
        popover.performClose(nil); NSApp.setActivationPolicy(.regular); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func showExistingInstance(_ notification: Notification) { showDashboard() }
    @objc private func showSettings() { store.page = "settings"; showDashboard() }
    @objc private func refresh() { store.refresh() }
    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Codex Pulse", .applicationVersion: "1.5.0", .credits: NSAttributedString(string: "你的 Codex 用量，心中有数。\n独立的本地用量查看工具。")])
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === window { NSApp.setActivationPolicy(.accessory) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showDashboard(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
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
            let output = CommandLine.arguments.firstIndex(of: "--output").flatMap { index in CommandLine.arguments.indices.contains(index + 1) ? CommandLine.arguments[index + 1] : nil }
            if let output {
                let directory = URL(fileURLWithPath: output, isDirectory: true)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? await Task.sleep(nanoseconds: 700_000_000)
                capture(statusItem.button, to: directory.appendingPathComponent("menu-status.png"))
                if let detailView = popover.contentViewController?.view {
                    detailView.frame = NSRect(origin: .zero, size: detailView.fittingSize)
                    capture(detailView, to: directory.appendingPathComponent("detail.png"))
                }
                capture(window.contentView, to: directory.appendingPathComponent("overview.png"))
                store.page = "history"
                try? await Task.sleep(nanoseconds: 300_000_000)
                capture(window.contentView, to: directory.appendingPathComponent("history.png"))
                store.page = "settings"
                try? await Task.sleep(nanoseconds: 300_000_000)
                capture(window.contentView, to: directory.appendingPathComponent("settings.png"))
                store.page = "overview"
            }
            let report: [String: Any] = ["connected": store.limits != nil, "bucketCount": store.buckets.count,
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

extension Notification.Name {
    static let pulseShowExisting = Notification.Name("app.codexpulse.mac.showExisting")
}
