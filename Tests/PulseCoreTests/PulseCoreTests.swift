import XCTest
@testable import PulseCore

final class PulseCoreTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONDecoder().decode(type, from: Data(text.utf8)) }

    func testRemainingClampsAndDoesNotFabricateAbsentWindows() throws {
        XCTAssertEqual(QuotaWindow(usedPercent: 73).remaining, 27)
        XCTAssertEqual(QuotaWindow(usedPercent: 120).remaining, 0)
        XCTAssertEqual(QuotaWindow(usedPercent: -12).remaining, 100)
        let bucket = try decode(QuotaBucket.self, "{}")
        XCTAssertNil(bucket.limitingWindow)
        XCTAssertEqual(PulseFormat.percent(bucket.limitingWindow?.remaining), "—")
        XCTAssertThrowsError(try decode(QuotaWindow.self, "{\"usedPercent\":null}"))
    }

    func testDynamicWindowLabelsAndTightestWindow() throws {
        let bucket = try decode(QuotaBucket.self, """
        {"primary":{"usedPercent":21,"windowDurationMins":300},"secondary":{"usedPercent":73,"windowDurationMins":10080}}
        """)
        XCTAssertEqual(bucket.primary?.label, "5 小时额度")
        XCTAssertEqual(bucket.secondary?.label, "每周额度")
        XCTAssertEqual(bucket.limitingWindow?.remaining, 27)
        XCTAssertEqual(QuotaWindow(usedPercent: 0, windowDurationMins: 15).label, "15 分钟额度")
        XCTAssertEqual(QuotaWindow(usedPercent: 0).label, "当前周期")
    }

    func testMultiBucketPreferredAndDictionaryKeysRemainStable() throws {
        let response = try decode(LimitsResponse.self, """
        {"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{
            "base_model_inference":{"limitName":"gpt-reserve","primary":{"usedPercent":0}},
            "codex":{"primary":{"usedPercent":25}},
            "codex_bengalfox":{"primary":{"usedPercent":10}}
        }}
        """)
        XCTAssertEqual(response.buckets.map(\.id), ["codex", "codex_bengalfox", "base_model_inference"])
        XCTAssertEqual(response.buckets.first?.limitingWindow?.remaining, 75)
    }

    func testLegacyAndEmptyMapFallback() throws {
        let response = try decode(LimitsResponse.self, "{\"rateLimits\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":6}},\"rateLimitsByLimitId\":{}}")
        XCTAssertEqual(response.buckets.count, 1)
        XCTAssertEqual(response.buckets[0].limitingWindow?.remaining, 94)
    }

    func testExpiredResetDoesNotPretendQuotaRecovered() {
        let window = QuotaWindow(usedPercent: 100, windowDurationMins: 300, resetsAt: 1000)
        XCTAssertEqual(window.countdown(at: Date(timeIntervalSince1970: 1001)), "等待官方更新")
        XCTAssertEqual(window.remaining, 0)
        XCTAssertEqual(window.countdown(at: Date(timeIntervalSince1970: 999)), "1 分钟后重置")
        XCTAssertEqual(QuotaWindow(usedPercent: 0).countdown(at: Date()), "重置时间未知")
    }

    func testBackendRestrictionNotInferredFromPercentage() throws {
        let bucket = try decode(QuotaBucket.self, "{\"primary\":{\"usedPercent\":0},\"spendControlReached\":true}")
        XCTAssertEqual(bucket.limitingWindow?.remaining, 100)
        XCTAssertTrue(bucket.isRestricted)
    }

    func testHistoryPreservesMissingVersusZeroAndAvoidsDuplicateInflation() throws {
        let usage = try decode(UsageResponse.self, """
        {"summary":{},"dailyUsageBuckets":[
        {"startDate":"2026-09-15","tokens":1234},
        {"startDate":"2026-09-15","tokens":1234},
        {"startDate":"2026-09-16","tokens":0}]}
        """)
        let now = ISO8601DateFormatter().date(from: "2026-09-17T10:00:00Z")!
        let days = usage.days(3, now: now)
        XCTAssertEqual(days.map(\.key), ["2026-09-15", "2026-09-16", "2026-09-17"])
        XCTAssertEqual(days[0].tokens, 1234)
        XCTAssertEqual(days[1].tokens, 0)
        XCTAssertNil(days[2].tokens)
        XCTAssertNil(usage.summary.lifetimeTokens)
        XCTAssertEqual(PulseFormat.tokens(nil), "—")
        XCTAssertEqual(PulseFormat.tokens(0), "0")
        XCTAssertEqual(usage.days(30, now: now).count, 30)
    }

    func testAlertsAreScopedToAccountBucketWindowCycleAndThreshold() throws {
        let bucket = try decode(QuotaBucket.self, "{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":91,\"resetsAt\":2000}}")
        let keys = QuotaAlerts.keys(identity: "a", bucket: bucket)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(Set(keys).intersection(QuotaAlerts.keys(identity: "b", bucket: bucket)).count, 0)
        XCTAssertTrue(QuotaAlerts.keys(identity: "", bucket: bucket).isEmpty)
        let noReset = try decode(QuotaBucket.self, "{\"primary\":{\"usedPercent\":99}}")
        XCTAssertTrue(QuotaAlerts.keys(identity: "a", bucket: noReset).isEmpty)
    }
}
