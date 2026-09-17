import Foundation

public struct TokenTotals: Equatable, Sendable {
    public var input: Int64 = 0
    public var cachedInput: Int64 = 0
    public var output: Int64 = 0
    public var total: Int64 = 0

    mutating func add(_ other: Self) {
        input = Self.sum(input, other.input); cachedInput = Self.sum(cachedInput, other.cachedInput)
        output = Self.sum(output, other.output); total = Self.sum(total, other.total)
    }
    private static func sum(_ a: Int64, _ b: Int64) -> Int64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int64.max : value
    }
}

public struct LocalUsageSnapshot: Sendable {
    public let dayStart: Date
    public let updatedAt: Date
    public let timeZone: String
    public let totals: TokenTotals
    public let requestCount: Int
    public let sessionCount: Int
    public let isAvailable: Bool
    public let isPartial: Bool
    public let usesLegacyEstimates: Bool
    public let lastEventAt: Date?
}

/// Reads numeric usage events only. Conversation bodies are neither decoded nor
/// retained. File tails are incremental; all indexing stays in memory.
public actor LocalUsageReader {
    private struct Entry {
        let timestamp: Date
        let thread: String
        let tokens: TokenTotals
    }
    private struct FileState {
        var offset: UInt64 = 0
        var tail = Data()
        var skippingLongLine = false
        var modified = Date.distantPast
        var thread = ""
        var previous: TokenTotals?
        var records: [String: Entry] = [:]
        var legacy: [String: Entry] = [:]
        var malformed = false
    }
    private struct Counters: Decodable {
        let input_tokens: Int64?
        let cached_input_tokens: Int64?
        let output_tokens: Int64?
        let total_tokens: Int64?
        var value: TokenTotals? {
            guard let input = input_tokens, let output = output_tokens,
                  input >= 0, output >= 0, (cached_input_tokens ?? 0) >= 0 else { return nil }
            var value = TokenTotals(input: input, cachedInput: min(input, cached_input_tokens ?? 0), output: output)
            value.total = total_tokens ?? TokenTotals.sumForDecode(input, output)
            return value.total >= 0 ? value : nil
        }
    }
    private struct Envelope: Decodable {
        let timestamp: String?
        let type: String
        let payload: Payload
        struct Payload: Decodable {
            let id: String?
            let thread_id: String?
            let response_id: String?
            let type: String?
            let usage: Counters?
            let info: Info?
            struct Info: Decodable {
                let total_token_usage: Counters?
                let last_token_usage: Counters?
            }
        }
    }

    private var files: [String: FileState] = [:]
    private var dayKey = ""
    private let fractional = ISO8601DateFormatter()
    private let plain = ISO8601DateFormatter()
    private let decoder = JSONDecoder()
    private let maxLineBytes = 2 * 1024 * 1024

    public init() { fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }

    public func scan(root: URL, now: Date = Date(), calendar: Calendar = .current) -> LocalUsageSnapshot {
        let start = calendar.startOfDay(for: now)
        let key = "\(root.path)|\(start.timeIntervalSince1970)|\(calendar.timeZone.identifier)"
        if key != dayKey { files.removeAll(); dayKey = key }
        let fm = FileManager.default
        var available = false, partial = false
        var present = Set<String>()
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        for name in ["sessions", "archived_sessions"] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: directory.path) else { continue }
            guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: resourceKeys,
                                            options: [.skipsHiddenFiles], errorHandler: { _, _ in partial = true; return true }) else {
                partial = true; continue
            }
            available = true
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                do {
                    let info = try url.resourceValues(forKeys: Set(resourceKeys))
                    guard info.isRegularFile == true, info.isSymbolicLink != true else { continue }
                    let modified = info.contentModificationDate ?? .distantPast
                    guard modified >= start else { continue }
                    let path = url.path
                    present.insert(path)
                    let size = UInt64(max(0, info.fileSize ?? 0))
                    var state = files[path] ?? FileState(thread: url.lastPathComponent)
                    // Detect truncation/replacement, as well as normal append-only writes.
                    if size < state.offset || (size == state.offset && modified != state.modified) {
                        state = FileState(thread: url.lastPathComponent)
                    }
                    if size > state.offset {
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        try handle.seek(toOffset: state.offset)
                        while state.offset < size {
                            let chunk = try handle.read(upToCount: min(256 * 1024, Int(size - state.offset))) ?? Data()
                            if chunk.isEmpty { break }
                            state.offset += UInt64(chunk.count)
                            consume(chunk, state: &state, start: start)
                        }
                    }
                    state.modified = modified
                    files[path] = state
                } catch { partial = true }
            }
        }
        files = files.filter { present.contains($0.key) }
        var records: [String: Entry] = [:], legacy: [String: Entry] = [:]
        var nativeThreads = Set<String>()
        for state in files.values {
            partial = partial || state.malformed
            for (id, entry) in state.records where entry.timestamp <= now {
                records[id] = entry; nativeThreads.insert(entry.thread)
            }
            if state.records.isEmpty {
                for (id, entry) in state.legacy where entry.timestamp <= now { legacy[id] = entry }
            }
        }
        // Modern files record the same response twice (numeric record + legacy
        // notification). Prefer response IDs, also deduplicating copied forks.
        let fallback = legacy.values.filter { !nativeThreads.contains($0.thread) }
        var totals = TokenTotals(), threads = Set<String>()
        var latest: Date?
        for entry in Array(records.values) + fallback {
            totals.add(entry.tokens); threads.insert(entry.thread)
            latest = max(latest ?? entry.timestamp, entry.timestamp)
        }
        return LocalUsageSnapshot(dayStart: start, updatedAt: now, timeZone: calendar.timeZone.identifier,
                                  totals: totals, requestCount: records.count + fallback.count, sessionCount: threads.count,
                                  isAvailable: available, isPartial: partial, usesLegacyEstimates: !fallback.isEmpty, lastEventAt: latest)
    }

    private func consume(_ chunk: Data, state: inout FileState, start: Date) {
        var index = chunk.startIndex
        while index < chunk.endIndex {
            let end = chunk[index...].firstIndex(of: 0x0A) ?? chunk.endIndex
            if !state.skippingLongLine {
                if state.tail.count + (end - index) <= maxLineBytes { state.tail.append(chunk[index..<end]) }
                else { state.tail.removeAll(keepingCapacity: true); state.skippingLongLine = true }
            }
            if end < chunk.endIndex {
                if !state.skippingLongLine { parse(state.tail, state: &state, start: start) }
                state.tail.removeAll(keepingCapacity: true); state.skippingLongLine = false
                index = end + 1
            } else { break }
        }
    }

    private func parse(_ line: Data, state: inout FileState, start: Date) {
        // Rollout envelopes put their type before payload. Reject other lines
        // before decoding so prompts, tool outputs and images stay opaque.
        let prefix = String(decoding: line.prefix(256), as: UTF8.self).filter { !$0.isWhitespace }
        let isRecord = prefix.contains("\"type\":\"token_usage_record\"")
        let isEvent = prefix.contains("\"type\":\"event_msg\"")
        let isMeta = prefix.contains("\"type\":\"session_meta\"")
        guard isRecord || isMeta || (isEvent && prefix.contains("\"type\":\"token_count\"")) else { return }
        guard let item = try? decoder.decode(Envelope.self, from: line) else {
            if isRecord { state.malformed = true }; return
        }
        if item.type == "session_meta" { state.thread = item.payload.id ?? state.thread; return }
        guard let text = item.timestamp, let date = fractional.date(from: text) ?? plain.date(from: text) else { return }
        if item.type == "token_usage_record" {
            guard date >= start, let id = item.payload.response_id, !id.isEmpty,
                  let usage = item.payload.usage?.value else { return }
            state.records[id] = Entry(timestamp: date, thread: item.payload.thread_id ?? state.thread, tokens: usage)
        } else if item.payload.type == "token_count", let total = item.payload.info?.total_token_usage?.value {
            let previous = state.previous
            state.previous = total
            guard date >= start, total != previous else { return }
            let delta: TokenTotals
            if let previous, total.total >= previous.total, total.input >= previous.input, total.output >= previous.output {
                delta = TokenTotals(input: total.input - previous.input, cachedInput: max(0, total.cachedInput - previous.cachedInput),
                                    output: total.output - previous.output, total: total.total - previous.total)
            } else { delta = item.payload.info?.last_token_usage?.value ?? TokenTotals() }
            guard delta.total > 0 else { return }
            state.legacy["\(state.thread)|\(text)|\(total.total)"] = Entry(timestamp: date, thread: state.thread, tokens: delta)
        }
    }
}

private extension TokenTotals {
    static func sumForDecode(_ a: Int64, _ b: Int64) -> Int64 { sum(a, b) }
}
