import Foundation

public struct QuotaWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetsAt: TimeInterval?
    public var used: Double { min(100, max(0, usedPercent)) }
    public var remaining: Double { 100 - used }
    public var resetDate: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }
    public var label: String {
        guard let minutes = windowDurationMins, minutes > 0 else { return "当前周期" }
        if minutes == 10080 { return "每周额度" }
        if minutes % 1440 == 0 { return "\(minutes / 1440) 天额度" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时额度" }
        return "\(minutes) 分钟额度"
    }
    public init(usedPercent: Double, windowDurationMins: Int? = nil, resetsAt: TimeInterval? = nil) {
        self.usedPercent = usedPercent; self.windowDurationMins = windowDurationMins; self.resetsAt = resetsAt
    }
    public func countdown(at now: Date) -> String {
        guard let resetDate else { return "重置时间未知" }
        let seconds = resetDate.timeIntervalSince(now)
        guard seconds > 0 else { return "等待官方更新" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1440 { return "\(minutes / 1440) 天 \((minutes % 1440) / 60) 小时后重置" }
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟后重置" }
        return "\(minutes) 分钟后重置"
    }
}

public struct Credits: Codable, Equatable, Sendable {
    public let hasCredits: Bool
    public let unlimited: Bool
    public let balance: String?
}
public struct IndividualLimit: Codable, Equatable, Sendable {
    public let limit: String
    public let used: String
    public let remainingPercent: Double
    public let resetsAt: TimeInterval
}
public struct QuotaBucket: Codable, Equatable, Identifiable, Sendable {
    public var limitId: String?
    public var limitName: String?
    public var normalModelSlug: String?
    public var primary: QuotaWindow?
    public var secondary: QuotaWindow?
    public var credits: Credits?
    public var individualLimit: IndividualLimit?
    public var spendControlReached: Bool?
    public var planType: String?
    public var rateLimitReachedType: String?
    public var id: String { limitId ?? "codex" }
    public var title: String {
        if id == "codex" { return "Codex" }
        if id == "base_model_inference" { return "Reserve" }
        if id == "codex_bengalfox" { return "Spark" }
        return limitName ?? limitId ?? "Codex"
    }
    public var subtitle: String {
        if id == "codex" { return "主要模型额度" }
        return normalModelSlug ?? limitName ?? "独立额度组"
    }
    public var symbol: String {
        switch id {
        case "codex": return "terminal"
        case "codex_bengalfox": return "bolt.fill"
        case "base_model_inference": return "moon.stars"
        default: return "cpu"
        }
    }
    public var windows: [QuotaWindow] { [primary, secondary].compactMap { $0 } }
    // The tightest actual window determines the compact indicator. Never invent a window.
    public var limitingWindow: QuotaWindow? { windows.min { $0.remaining < $1.remaining } }
    public var isRestricted: Bool { spendControlReached == true || rateLimitReachedType != nil }
}
public struct ResetCredits: Codable, Equatable, Sendable { public let availableCount: Int }
public struct LimitsResponse: Codable, Equatable, Sendable {
    public let rateLimits: QuotaBucket
    public let rateLimitsByLimitId: [String: QuotaBucket]?
    public let ordinaryUsageAllowed: Bool?
    public let accountId: String?
    public let rateLimitResetCredits: ResetCredits?
    public var buckets: [QuotaBucket] {
        let map = rateLimitsByLimitId.flatMap { $0.isEmpty ? nil : $0 }
            ?? [rateLimits.id: rateLimits]
        let ranks = ["codex": 0, "codex_bengalfox": 1, "base_model_inference": 2]
        return map.map { key, value in
            var value = value; value.limitId = key; return value
        }.sorted {
            let left = ranks[$0.id] ?? 10, right = ranks[$1.id] ?? 10
            return left == right ? $0.id < $1.id : left < right
        }
    }
}
public struct AccountResponse: Decodable, Sendable {
    public let account: Account?
    public struct Account: Codable, Sendable {
        public let type: String
        public let email: String?
        public let planType: String?
    }
}
public struct UsageSummary: Codable, Equatable, Sendable {
    public let lifetimeTokens: Int64?
    public let peakDailyTokens: Int64?
    public let longestRunningTurnSec: Int64?
    public let currentStreakDays: Int?
    public let longestStreakDays: Int?
}
public struct DailyUsage: Codable, Equatable, Sendable {
    public let startDate: String
    public let tokens: Int64
}
public struct UsageResponse: Codable, Equatable, Sendable {
    public let summary: UsageSummary
    public let dailyUsageBuckets: [DailyUsage]?
    public func days(_ count: Int, now: Date = Date()) -> [UsageDay] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // Date-only server buckets are preserved as reported, without timezone shifting.
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let values = Dictionary((dailyUsageBuckets ?? []).map { ($0.startDate, max(0, $0.tokens)) }, uniquingKeysWith: max)
        return (0..<max(0, count)).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)) else { return nil }
            let key = formatter.string(from: date)
            return UsageDay(date: date, key: key, tokens: values[key])
        }
    }
}
public struct UsageDay: Identifiable, Equatable, Sendable {
    public let date: Date
    public let key: String
    public let tokens: Int64?
    public var id: String { key }
    public var shortLabel: String { String(key.suffix(5)).replacingOccurrences(of: "-", with: "/") }
}
public struct CachedSnapshot: Codable {
    public let identity: String
    public let limits: LimitsResponse
    public let limitsUpdatedAt: Date
    public let usage: UsageResponse?
    public let usageUpdatedAt: Date?
    public init(identity: String, limits: LimitsResponse, limitsUpdatedAt: Date, usage: UsageResponse?, usageUpdatedAt: Date?) {
        self.identity = identity; self.limits = limits; self.limitsUpdatedAt = limitsUpdatedAt
        self.usage = usage; self.usageUpdatedAt = usageUpdatedAt
    }
}
public enum PulseFormat {
    public static func tokens(_ value: Int64?) -> String {
        guard let value else { return "—" }
        if value >= 1_000_000_000 { return String(format: "%.2fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1000 { return String(format: "%.1fK", Double(value) / 1000) }
        return String(value)
    }
    public static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.0f%%", min(100, max(0, value)))
    }
}

public enum QuotaAlerts {
    public static func keys(identity: String, bucket: QuotaBucket) -> [String] {
        guard !identity.isEmpty else { return [] }
        return bucket.windows.enumerated().flatMap { index, window -> [String] in
            // Missing reset timestamps cannot provide a reliable once-per-cycle identity.
            guard let reset = window.resetsAt else { return [] }
            return [20, 10].filter { window.remaining <= Double($0) }.map {
                "\(identity)|\(bucket.id)|\(index)|\(Int(reset))|\($0)"
            }
        }
    }
}
