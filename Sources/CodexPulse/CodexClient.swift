import AppKit
import Foundation
import PulseCore

enum PulseError: LocalizedError {
    case notInstalled, disconnected, timeout, notSignedIn, unsupportedAccount, invalidResponse, remote(String)
    var errorDescription: String? {
        switch self {
        case .notInstalled: return "未找到 Codex。请安装 Codex 桌面应用，或在设置中选择 Codex 程序。"
        case .disconnected: return "与 Codex 的连接已断开，请重新刷新。"
        case .timeout: return "连接超时，请检查网络后重试。"
        case .notSignedIn: return "请登录 ChatGPT，以读取订阅额度。"
        case .unsupportedAccount: return "当前使用 API 密钥登录。订阅额度需要 ChatGPT 账号登录。"
        case .invalidResponse: return "Codex 返回了无法识别的数据，请更新 Codex 后重试。"
        case .remote(let text):
            let lower = text.lowercased()
            if lower.contains("unauthorized") || lower.contains("401") || lower.contains("auth") { return "登录状态已失效，请在 Codex 中重新登录。" }
            if lower.contains("method") { return "当前 Codex 版本暂不支持此统计，请更新 Codex。" }
            return "暂时无法读取官方数据，请检查网络后刷新。"
        }
    }
}

@MainActor
final class CodexClient {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var ready = false
    private var generation = UUID()
    var onNotification: ((String) -> Void)?
    private(set) var executablePath: String?

    static func locate(custom: String = "") -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [custom,
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            home + "/Applications/Codex.app/Contents/Resources/codex",
            home + "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        for path in candidates where !path.isEmpty && fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        let nvm = URL(fileURLWithPath: home + "/.nvm/versions/node")
        let versions = (try? fm.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil)) ?? []
        for version in versions.sorted(by: { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }) {
            let cli = version.appendingPathComponent("bin/codex")
            if fm.isExecutableFile(atPath: cli.path) { return cli }
        }
        return nil
    }

    func connect(custom: String = "") async throws {
        if ready, process?.isRunning == true { return }
        stop()
        guard let executable = Self.locate(custom: custom) else { throw PulseError.notInstalled }
        executablePath = executable.path
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = executable
        child.arguments = ["app-server", "--listen", "stdio://"]
        child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        // Identification only. Authentication remains entirely with the official Codex process.
        child.environment = environment
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        let token = UUID(); generation = token
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                if data.isEmpty {
                    self.output?.readabilityHandler = nil
                    self.failPending(PulseError.disconnected); self.ready = false
                }
                else { self.receive(data) }
            }
        }
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.ready = false; self.failPending(PulseError.disconnected)
            }
        }
        process = child
        do {
            try child.run()
            let _: InitResult = try await request("initialize", params: [
                "clientInfo": ["name": "codex_pulse", "title": "Codex Pulse", "version": "1.5.0"],
                "capabilities": ["experimentalApi": true]
            ])
            try send(["method": "initialized"])
            ready = true
        } catch { stop(); throw error }
    }

    func request<T: Decodable>(_ method: String, params: [String: Any]? = nil) async throws -> T {
        guard process?.isRunning == true else { throw PulseError.disconnected }
        nextID += 1; let id = nextID
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
                guard let self else { return }
                self.timeouts.removeValue(forKey: id)
                self.pending.removeValue(forKey: id)?.resume(throwing: PulseError.timeout)
            }
            do { try send(message) } catch {
                timeouts.removeValue(forKey: id)?.cancel()
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw PulseError.invalidResponse }
    }

    private func send(_ message: [String: Any]) throws {
        guard let input, process?.isRunning == true else { throw PulseError.disconnected }
        var data = try JSONSerialization.data(withJSONObject: message); data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        guard buffer.count < 16_000_000 else { stop(); return }
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
                timeouts.removeValue(forKey: id)?.cancel()
                if let error = object["error"] as? [String: Any] {
                    continuation.resume(throwing: PulseError.remote(error["message"] as? String ?? ""))
                } else if let result = object["result"], let resultData = try? JSONSerialization.data(withJSONObject: result) {
                    continuation.resume(returning: resultData)
                } else { continuation.resume(throwing: PulseError.invalidResponse) }
            } else if let method = object["method"] as? String {
                if let requestID = object["id"] {
                    // This monitor cannot execute approval, attestation, or agent requests.
                    try? send(["id": requestID, "error": ["code": -32601, "message": "Read-only monitor: method unsupported"]])
                } else { onNotification?(method) }
            }
        }
    }

    private func failPending(_ error: Error) {
        let continuations = Array(pending.values); pending.removeAll()
        timeouts.values.forEach { $0.cancel() }; timeouts.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }

    func stop() {
        generation = UUID(); ready = false
        output?.readabilityHandler = nil; output = nil
        try? input?.close(); input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil; buffer.removeAll(); failPending(PulseError.disconnected)
    }
    private struct InitResult: Decodable { let userAgent: String }
}
