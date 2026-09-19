import Foundation

public enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

public enum MessageDelivery: String, Codable, Sendable {
    case waiting
    case sending
    case accepted
    case failed
}

public struct WeatherCardAttribution: Codable, Equatable, Sendable {
    public let legalPageURL: URL
    public let combinedMarkLightURL: URL
    public let combinedMarkDarkURL: URL
    public init(legalPageURL: URL, combinedMarkLightURL: URL, combinedMarkDarkURL: URL) {
        self.legalPageURL = legalPageURL
        self.combinedMarkLightURL = combinedMarkLightURL
        self.combinedMarkDarkURL = combinedMarkDarkURL
    }
}

public struct WeatherCard: Codable, Equatable, Sendable {
    public let temperatureCelsius: Double
    public let apparentCelsius: Double?
    public let condition: String
    public let humidity: Double?
    public let windKilometresPerHour: Double?
    public let highCelsius: Double?
    public let lowCelsius: Double?
    public let attribution: WeatherCardAttribution

    public init(temperatureCelsius: Double, apparentCelsius: Double?, condition: String, humidity: Double?, windKilometresPerHour: Double?, highCelsius: Double?, lowCelsius: Double?, attribution: WeatherCardAttribution) {
        self.temperatureCelsius = temperatureCelsius
        self.apparentCelsius = apparentCelsius
        self.condition = condition
        self.humidity = humidity
        self.windKilometresPerHour = windKilometresPerHour
        self.highCelsius = highCelsius
        self.lowCelsius = lowCelsius
        self.attribution = attribution
    }
}

public enum ChatAttachment: Codable, Equatable, Sendable {
    case weather(WeatherCard)
}

public struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let role: ChatRole
    public var text: String
    public let createdAt: Date
    public var delivery: MessageDelivery
    public var attachment: ChatAttachment?

    public init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        createdAt: Date = Date(),
        delivery: MessageDelivery = .accepted,
        attachment: ChatAttachment? = nil)
    {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.delivery = delivery
        self.attachment = attachment
    }
}

public enum OutboxState: String, Codable, Sendable {
    case waiting
    case sending
    case failed
}

public struct OutboxEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let messageID: UUID
    public let text: String
    public let idempotencyKey: String
    public var state: OutboxState

    public init(
        id: UUID,
        messageID: UUID,
        text: String,
        idempotencyKey: String,
        state: OutboxState)
    {
        self.id = id
        self.messageID = messageID
        self.text = text
        self.idempotencyKey = idempotencyKey
        self.state = state
    }
}

public struct ConversationSnapshot: Codable, Equatable, Sendable {
    public var messages: [ChatMessage]
    public var draft: String
    public var outbox: [OutboxEntry]

    public init(
        messages: [ChatMessage] = [],
        draft: String = "",
        outbox: [OutboxEntry] = [])
    {
        self.messages = messages
        self.draft = draft
        self.outbox = outbox
    }
}
