import Foundation
import OSLog

/// Where pass times persist. UserDefaults: a relaunch must not reset the
/// count, or the ration would be a suggestion.
protocol DiscordReadHistoryStore: AnyObject, Sendable {
    func loadPassDates() -> [Date]
    func savePassDates(_ dates: [Date])
    func loadPausedUntil() -> Date?
    func savePausedUntil(_ date: Date?)
}

final class UserDefaultsDiscordReadHistoryStore: DiscordReadHistoryStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let passesKey = "app.operator.discord.passDates"
    private let pausedKey = "app.operator.discord.pausedUntil"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func loadPassDates() -> [Date] { (self.defaults.array(forKey: self.passesKey) as? [Double] ?? []).map(Date.init(timeIntervalSince1970:)) }
    func savePassDates(_ dates: [Date]) { self.defaults.set(dates.map(\.timeIntervalSince1970), forKey: self.passesKey) }
    func loadPausedUntil() -> Date? { (self.defaults.object(forKey: self.pausedKey) as? Double).map(Date.init(timeIntervalSince1970:)) }
    func savePausedUntil(_ date: Date?) {
        if let date { self.defaults.set(date.timeIntervalSince1970, forKey: self.pausedKey) } else { self.defaults.removeObject(forKey: self.pausedKey) }
    }
}

enum DiscordReadRefusal: Equatable, Sendable {
    /// Less than the minimum gap since the last pass.
    case tooSoon(retryAfterSeconds: Int)
    /// The rolling 24-hour ration is used up.
    case dailyCapReached(resetsInSeconds: Int)
    /// Discord asked for a pause; Operator stops for the day.
    case paused(resumesInSeconds: Int)

    var code: String {
        switch self {
        case .tooSoon: "RATE_LIMITED"
        case .dailyCapReached: "DAILY_CAP_REACHED"
        case .paused: "PAUSED_BY_DISCORD"
        }
    }

    var message: String {
        switch self {
        case let .tooSoon(seconds):
            "Operator reads Discord at most once every \(DiscordReadPace.minimumGapSeconds / 3600) hours to keep the account safe. The last read was recent; the next is possible in \(max(1, seconds / 60)) minutes. Do not retry before then."
        case let .dailyCapReached(seconds):
            "Operator has read Discord \(DiscordReadPace.dailyCap) times in the last 24 hours, its limit for keeping the account safe. The limit resets in \(max(1, seconds / 60)) minutes. Do not retry before then."
        case let .paused(seconds):
            "Discord asked Operator to slow down, so Discord reads are paused for \(max(1, seconds / 3600)) hours to protect the account. Do not retry before then."
        }
    }
}

/// The pace the Discord acknowledgement promises, enforced. A pass is one
/// read of the whole channel list, whatever the model asked for.
@MainActor
final class DiscordReadPace {
    nonisolated static let minimumGapSeconds = 2 * 3600
    nonisolated static let dailyCap = 4
    nonisolated static let pauseAfterRateLimitSeconds = 24 * 3600

    private let history: any DiscordReadHistoryStore
    private let now: () -> Date
    private let logger = Logger(subsystem: "app.operator.ios", category: "discord-pace")

    init(history: any DiscordReadHistoryStore, now: @escaping () -> Date = Date.init) {
        self.history = history
        self.now = now
    }

    /// Nil means a pass may start.
    func check() -> DiscordReadRefusal? {
        let current = self.now()
        if let paused = self.history.loadPausedUntil(), paused > current {
            self.logger.info("[discord-pace] refused branch=paused")
            return .paused(resumesInSeconds: Int(paused.timeIntervalSince(current).rounded(.up)))
        }
        let recent = self.recentPasses(at: current)
        if let last = recent.max() {
            let elapsed = current.timeIntervalSince(last)
            if elapsed < Double(Self.minimumGapSeconds) {
                self.logger.info("[discord-pace] refused branch=too-soon")
                return .tooSoon(retryAfterSeconds: Int((Double(Self.minimumGapSeconds) - elapsed).rounded(.up)))
            }
        }
        if recent.count >= Self.dailyCap, let oldest = recent.min() {
            self.logger.info("[discord-pace] refused branch=daily-cap")
            return .dailyCapReached(resetsInSeconds: Int((86_400 - current.timeIntervalSince(oldest)).rounded(.up)))
        }
        return nil
    }

    /// Recorded when a pass starts, before any request: a pass that fails
    /// halfway still counts, since Discord saw its requests.
    func recordPass() {
        let current = self.now()
        var recent = self.recentPasses(at: current)
        recent.append(current)
        self.history.savePassDates(recent)
    }

    /// Discord answered 429. Whatever Retry-After said, Operator stops for a
    /// day: a reader that backs off by seconds and comes straight back looks
    /// like a script.
    func recordRateLimit() {
        self.history.savePausedUntil(self.now().addingTimeInterval(Double(Self.pauseAfterRateLimitSeconds)))
        self.logger.info("[discord-pace] paused after rate limit")
    }

    var passesLeftToday: Int {
        max(0, Self.dailyCap - self.recentPasses(at: self.now()).count)
    }

    private func recentPasses(at current: Date) -> [Date] {
        self.history.loadPassDates().filter { current.timeIntervalSince($0) < 86_400 }
    }
}
