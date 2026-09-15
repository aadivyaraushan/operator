import Foundation
import OSLog

/// Where pass times and per-channel read times persist. UserDefaults: a
/// relaunch must not reset them, or the ration would be a suggestion.
protocol DiscordReadHistoryStore: AnyObject, Sendable {
    func loadPassDates() -> [Date]
    func savePassDates(_ dates: [Date])
    func loadPausedUntil() -> Date?
    func savePausedUntil(_ date: Date?)
    func loadChannelReads() -> [String: Date]
    func saveChannelReads(_ reads: [String: Date])
}

final class UserDefaultsDiscordReadHistoryStore: DiscordReadHistoryStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let passesKey = "app.operator.discord.passDates"
    private let pausedKey = "app.operator.discord.pausedUntil"
    private let readsKey = "app.operator.discord.channelReads"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func loadPassDates() -> [Date] { (self.defaults.array(forKey: self.passesKey) as? [Double] ?? []).map(Date.init(timeIntervalSince1970:)) }
    func savePassDates(_ dates: [Date]) { self.defaults.set(dates.map(\.timeIntervalSince1970), forKey: self.passesKey) }
    func loadPausedUntil() -> Date? { (self.defaults.object(forKey: self.pausedKey) as? Double).map(Date.init(timeIntervalSince1970:)) }
    func savePausedUntil(_ date: Date?) {
        if let date { self.defaults.set(date.timeIntervalSince1970, forKey: self.pausedKey) } else { self.defaults.removeObject(forKey: self.pausedKey) }
    }
    func loadChannelReads() -> [String: Date] {
        (self.defaults.dictionary(forKey: self.readsKey) as? [String: Double] ?? [:]).mapValues(Date.init(timeIntervalSince1970:))
    }
    func saveChannelReads(_ reads: [String: Date]) { self.defaults.set(reads.mapValues(\.timeIntervalSince1970), forKey: self.readsKey) }
}

enum DiscordReadRefusal: Equatable, Sendable {
    /// Every listed channel was read within the cooldown.
    case tooSoon(retryAfterSeconds: Int)
    /// The rolling 24-hour pass cap is used up.
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
            "Operator reads each Discord channel at most once every \(DiscordReadPace.channelCooldownSeconds / 60) minutes to keep the account safe. Every listed channel was read recently; the next read is possible in \(max(1, seconds / 60)) minutes. Do not retry before then."
        case let .dailyCapReached(seconds):
            "Operator has made \(DiscordReadPace.dailyCap) Discord reads in the last 24 hours, its limit for keeping the account safe. The limit resets in \(max(1, seconds / 60)) minutes. Do not retry before then."
        case let .paused(seconds):
            "Discord asked Operator to slow down, so Discord reads are paused for \(max(1, seconds / 3600)) hours to protect the account. Do not retry before then."
        }
    }
}

/// The pace the Discord acknowledgement promises, enforced. Each channel is
/// requested at most once per cooldown; a pass is any call that requests at
/// least one channel, and passes are capped per day so that nothing, the
/// model included, can turn the owner's questions into a poller.
///
/// Loosened on 2026-09-15 from 4 passes a day, 2 hours apart, after the
/// read-frequency research in saved-results: every read-only lock on record
/// was a burst or an unattended loop, and neither survives a ten-minute
/// cooldown with a daily pass cap.
@MainActor
final class DiscordReadPace {
    nonisolated static let channelCooldownSeconds = 10 * 60
    nonisolated static let dailyCap = 24
    nonisolated static let pauseAfterRateLimitSeconds = 24 * 3600

    private let history: any DiscordReadHistoryStore
    private let now: () -> Date
    private let logger = Logger(subsystem: "app.operator.ios", category: "discord-pace")

    init(history: any DiscordReadHistoryStore, now: @escaping () -> Date = Date.init) {
        self.history = history
        self.now = now
    }

    /// Nil means a pass may start. The per-channel cooldown is separate
    /// (`isDue`): a call with nothing due makes no request and is not a pass.
    func check() -> DiscordReadRefusal? {
        let current = self.now()
        if let paused = self.history.loadPausedUntil(), paused > current {
            self.logger.info("[discord-pace] refused branch=paused")
            return .paused(resumesInSeconds: Int(paused.timeIntervalSince(current).rounded(.up)))
        }
        let recent = self.recentPasses(at: current)
        if recent.count >= Self.dailyCap, let oldest = recent.min() {
            self.logger.info("[discord-pace] refused branch=daily-cap")
            return .dailyCapReached(resetsInSeconds: Int((86_400 - current.timeIntervalSince(oldest)).rounded(.up)))
        }
        return nil
    }

    /// Whether a channel may be requested: never read, or read longer ago
    /// than the cooldown.
    func isDue(channelID: String) -> Bool {
        guard let last = self.history.loadChannelReads()[channelID] else { return true }
        return self.now().timeIntervalSince(last) >= Double(Self.channelCooldownSeconds)
    }

    /// Seconds until the soonest of these channels is due again; zero when
    /// one already is.
    func secondsUntilDue(channelIDs: [String]) -> Int {
        let reads = self.history.loadChannelReads()
        let current = self.now()
        let waits = channelIDs.map { id -> Double in
            guard let last = reads[id] else { return 0 }
            return max(0, Double(Self.channelCooldownSeconds) - current.timeIntervalSince(last))
        }
        return Int((waits.min() ?? 0).rounded(.up))
    }

    /// Recorded when a pass starts, before any request: a pass that fails
    /// halfway still counts, since Discord saw its requests.
    func recordPass() {
        let current = self.now()
        var recent = self.recentPasses(at: current)
        recent.append(current)
        self.history.savePassDates(recent)
    }

    /// Recorded when a channel is requested, whether or not the request
    /// succeeds: a failing channel is not retried inside the cooldown either.
    func recordRead(channelID: String) {
        let current = self.now()
        var reads = self.history.loadChannelReads()
        reads[channelID] = current
        // Entries past the cooldown no longer decide anything.
        reads = reads.filter { current.timeIntervalSince($0.value) < Double(Self.channelCooldownSeconds) }
        self.history.saveChannelReads(reads)
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
