import XCTest
@testable import PulseCore

final class LocalUsageTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-17T07:00:00Z")!
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return value
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PulseUsageTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("sessions/2026/09/01"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func write(_ text: String, _ url: URL, modified: Date? = nil) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified ?? now], ofItemAtPath: url.path)
    }
    private func append(_ text: String, _ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    }
    private func record(_ id: String, at date: String = "2026-09-17T06:00:00Z", thread: String = "thread-a", input: Int = 100, cached: Int = 60, output: Int = 20) -> String {
        "{\"timestamp\":\"\(date)\",\"type\":\"token_usage_record\",\"payload\":{\"response_id\":\"\(id)\",\"thread_id\":\"\(thread)\",\"usage\":{\"input_tokens\":\(input),\"cached_input_tokens\":\(cached),\"output_tokens\":\(output),\"reasoning_output_tokens\":10,\"total_tokens\":\(input + output)}}}\n"
    }
    private func meta(_ id: String) -> String {
        "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\"}}\n"
    }
    private func legacy(total: Int, last: Int, at date: String = "2026-09-17T06:00:00Z") -> String {
        "{\"timestamp\":\"\(date)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(total),\"output_tokens\":0,\"total_tokens\":\(total)},\"last_token_usage\":{\"input_tokens\":\(last),\"output_tokens\":0,\"total_tokens\":\(last)}}}}\n"
    }

    func testLocalMidnightCountsCachedAndReasoningOnlyOnce() async throws {
        let root = try root(), file = root.appendingPathComponent("sessions/usage.jsonl")
        try write(record("before", at: "2026-09-16T15:59:59Z") + record("midnight", at: "2026-09-16T16:00:00Z")
                  + record("today") + record("future", at: "2026-09-17T16:00:00Z"), file)
        let snapshot = await LocalUsageReader().scan(root: root, now: now, calendar: calendar)
        XCTAssertEqual(snapshot.totals.total, 240)
        XCTAssertEqual(snapshot.totals.input, 200)
        XCTAssertEqual(snapshot.totals.cachedInput, 120)
        XCTAssertEqual(snapshot.totals.output, 40)
        XCTAssertEqual(snapshot.requestCount, 2)
        XCTAssertEqual(snapshot.dayStart, ISO8601DateFormatter().date(from: "2026-09-16T16:00:00Z"))
    }

    func testRepeatedEventsAndCopiedForksAreDeduplicatedAcrossArchives() async throws {
        let root = try root(), archive = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let events = record("same") + record("same") + legacy(total: 120, last: 120)
        try write(meta("thread-a") + events, root.appendingPathComponent("sessions/usage.jsonl"))
        try write(meta("fork") + events, archive.appendingPathComponent("copy.jsonl"))
        let snapshot = await LocalUsageReader().scan(root: root, now: now, calendar: calendar)
        XCTAssertEqual(snapshot.totals.total, 120)
        XCTAssertEqual(snapshot.requestCount, 1)
        XCTAssertFalse(snapshot.usesLegacyEstimates)
    }

    func testIncrementalReadsWaitForCompleteLinesAndSurviveTruncation() async throws {
        let root = try root(), file = root.appendingPathComponent("sessions/usage.jsonl"), reader = LocalUsageReader()
        try write(record("one"), file)
        let first = await reader.scan(root: root, now: now, calendar: calendar)
        XCTAssertEqual(first.totals.total, 120)
        let half = record("two"); let index = half.index(half.startIndex, offsetBy: half.count / 2)
        try append(String(half[..<index]), file)
        let partial = await reader.scan(root: root, now: now, calendar: calendar)
        XCTAssertEqual(partial.totals.total, 120)
        try append(String(half[index...]), file)
        let complete = await reader.scan(root: root, now: now, calendar: calendar)
        let unchanged = await reader.scan(root: root, now: now, calendar: calendar)
        XCTAssertEqual(complete.totals.total, 240)
        XCTAssertEqual(unchanged.totals.total, 240)
        try write(record("replacement", input: 5, cached: 0, output: 2), file)
        let replaced = await reader.scan(root: root, now: now, calendar: calendar)
        XCTAssertEqual(replaced.totals.total, 7)
    }

    func testOlderSessionPathsAndRolloverUseEventTime() async throws {
        let root = try root(), file = root.appendingPathComponent("sessions/2026/09/01/old.jsonl"), reader = LocalUsageReader()
        let tomorrow = now.addingTimeInterval(86400)
        try write(record("today") + record("tomorrow", at: "2026-09-17T16:00:00Z", input: 200), file, modified: tomorrow)
        let today = await reader.scan(root: root, now: now, calendar: calendar)
        let next = await reader.scan(root: root, now: tomorrow, calendar: calendar)
        XCTAssertEqual(today.totals.total, 120)
        XCTAssertEqual(next.totals.total, 220)
    }

    func testLegacyDeltasExcludeYesterdayRepeatedSnapshotsAndResetTotals() async throws {
        let root = try root(), file = root.appendingPathComponent("sessions/usage.jsonl")
        let events = legacy(total: 1000, last: 1000, at: "2026-09-16T15:59:59Z")
            + legacy(total: 1150, last: 150) + legacy(total: 1150, last: 150)
            + legacy(total: 25, last: 25, at: "2026-09-17T06:01:00Z")
        try write(meta("old-version") + events, file)
        let snapshot = await LocalUsageReader().scan(root: root, now: now, calendar: calendar)
        XCTAssertEqual(snapshot.totals.total, 175)
        XCTAssertEqual(snapshot.requestCount, 2)
        XCTAssertTrue(snapshot.usesLegacyEstimates)
    }

    func testMissingRecordsDifferFromAnEmptyDayAndIgnoreConversationBodies() async throws {
        let root = try root(), reader = LocalUsageReader()
        let absent = await reader.scan(root: root.appendingPathComponent("missing"), now: now, calendar: calendar)
        XCTAssertFalse(absent.isAvailable)
        let file = root.appendingPathComponent("sessions/usage.jsonl")
        let body: [String: Any] = ["type": "response_item", "payload": ["text": record("not-real")]]
        let data = try JSONSerialization.data(withJSONObject: body)
        try write(String(decoding: data, as: UTF8.self) + "\n", file)
        let empty = await reader.scan(root: root, now: now, calendar: calendar)
        XCTAssertTrue(empty.isAvailable)
        XCTAssertEqual(empty.totals.total, 0)
        XCTAssertEqual(empty.requestCount, 0)
    }

    func testMalformedUsageIsReportedAndOversizeUnrelatedLinesDoNotBlockFollowingEvents() async throws {
        let root = try root(), file = root.appendingPathComponent("sessions/usage.jsonl")
        try write(String(repeating: "x", count: 2_200_000) + "\n{\"type\":\"token_usage_record\",broken}\n" + record("good"), file)
        let snapshot = await LocalUsageReader().scan(root: root, now: now, calendar: calendar)
        XCTAssertEqual(snapshot.totals.total, 120)
        XCTAssertTrue(snapshot.isPartial)
    }
}
