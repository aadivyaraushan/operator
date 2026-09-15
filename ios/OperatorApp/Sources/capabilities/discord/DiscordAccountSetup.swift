import Combine
import Foundation
import OSLog
import SwiftUI

/// Token in the Keychain, channel list beside the grants. The list is the
/// owner's, not the model's: the read command can only ever see what is here.
struct DiscordAccountStorage: Sendable {
    let loadToken: @Sendable () async throws -> String?
    let saveToken: @Sendable (String) async throws -> Void
    let clearToken: @Sendable () async throws -> Void
    let loadChannels: @Sendable () -> [DiscordChannelEntry]
    let saveChannels: @Sendable ([DiscordChannelEntry]) -> Void
}

final class UserDefaultsDiscordChannelStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "app.operator.discord.channels"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> [DiscordChannelEntry] {
        guard let data = self.defaults.data(forKey: self.key) else { return [] }
        return (try? JSONDecoder().decode([DiscordChannelEntry].self, from: data)) ?? []
    }
    func save(_ channels: [DiscordChannelEntry]) {
        guard let data = try? JSONEncoder().encode(channels) else { return }
        self.defaults.set(data, forKey: self.key)
    }
}

enum DiscordAccountSetupState: Equatable {
    case checking
    case setupRequired
    case connected(username: String?)
    case working
    case failed
}

@MainActor
final class DiscordAccountSetupModel: ObservableObject {
    static let channelLimit = 20

    @Published private(set) var state: DiscordAccountSetupState = .checking
    @Published private(set) var channels: [DiscordChannelEntry] = []
    @Published private(set) var message: String?

    private let storage: DiscordAccountStorage
    private let client: DiscordUserClient
    private let logger = Logger(subsystem: "app.operator.ios", category: "discord-setup")
    private var hasToken = false

    init(storage: DiscordAccountStorage, transport: any PhoneHTTPTransport = URLSessionPhoneHTTPTransport()) {
        self.storage = storage
        self.client = DiscordUserClient(transport: transport, token: { try await storage.loadToken() })
        self.channels = storage.loadChannels()
    }

    var isConnected: Bool { if case .connected = self.state { return true } else { return false } }

    var statusText: String {
        switch self.state {
        case .checking: "Checking…"
        case .setupRequired: "Setup required"
        case let .connected(username): username.map { "Signed in as \($0)" } ?? "Token saved"
        case .working: "Working…"
        case .failed: "Could not check"
        }
    }

    /// Whether a token is saved. No request: a saved token is not a live check,
    /// and a check on every open would be a read Discord sees.
    func check() async {
        self.state = .checking
        self.message = nil
        do {
            let token = try await self.storage.loadToken()
            self.hasToken = token.map(DiscordUserClient.plausibleToken) ?? false
            self.state = self.hasToken ? .connected(username: nil) : .setupRequired
        } catch {
            self.hasToken = false
            self.state = .failed
            self.message = "The saved Discord token could not be checked."
            self.logger.error("[discord-setup] token check failed")
        }
    }

    /// Saves the token after one GET /users/@me proves it works. The only
    /// request setup makes on the account itself.
    func saveToken(_ raw: String) async -> Bool {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DiscordUserClient.plausibleToken(token) else {
            self.restore(message: "That does not look like a Discord token.")
            return false
        }
        self.state = .working
        self.message = nil
        do {
            try await self.storage.saveToken(token)
            let username = try await self.client.me()
            self.hasToken = true
            self.state = .connected(username: username)
            self.logger.info("[discord-setup] token saved and verified")
            return true
        } catch let error as DiscordUserClientError {
            try? await self.storage.clearToken()
            self.hasToken = false
            self.restore(message: error == .notConnected ? "Discord did not accept that token." : "Discord could not be reached to check the token. Nothing was saved.")
            self.logger.info("[discord-setup] token rejected error=\(String(describing: error), privacy: .public)")
            return false
        } catch {
            self.hasToken = false
            self.restore(message: "The Discord token could not be saved.")
            self.logger.error("[discord-setup] token save failed")
            return false
        }
    }

    func clearToken() async {
        self.state = .working
        do {
            try await self.storage.clearToken()
            self.hasToken = false
            self.state = .setupRequired
            self.message = nil
            self.logger.info("[discord-setup] token removed")
        } catch {
            self.restore(message: "The saved Discord token could not be removed.")
        }
    }

    /// Adds a channel from a pasted link or id, resolving its names with the
    /// two setup requests. Rejects duplicates and more than `channelLimit`.
    func addChannel(_ raw: String) async -> Bool {
        guard let id = Self.channelID(from: raw) else {
            self.restore(message: "Paste a channel link (Copy Link on the channel in Discord) or a channel id.")
            return false
        }
        guard !self.channels.contains(where: { $0.id == id }) else {
            self.restore(message: "That channel is already on the list.")
            return false
        }
        guard self.channels.count < Self.channelLimit else {
            self.restore(message: "Up to \(Self.channelLimit) channels can be read.")
            return false
        }
        guard self.hasToken else {
            self.restore(message: "Save the token first.")
            return false
        }
        self.state = .working
        self.message = nil
        do {
            let entry = try await self.client.channel(id: id)
            self.channels.append(entry)
            self.storage.saveChannels(self.channels)
            self.restore(message: nil)
            self.logger.info("[discord-setup] channel added count=\(self.channels.count)")
            return true
        } catch let error as DiscordUserClientError {
            let why: String = switch error {
            case .notConnected: "Discord did not accept the saved token."
            case .notVisible: "That channel is not visible to this account. Join the server with it first."
            case .rateLimited: "Discord asked to slow down. Try again later."
            default: "Discord could not be reached."
            }
            self.restore(message: why)
            return false
        } catch {
            self.restore(message: "Discord could not be reached.")
            return false
        }
    }

    func removeChannel(id: String) {
        self.channels.removeAll { $0.id == id }
        self.storage.saveChannels(self.channels)
    }

    /// https://discord.com/channels/{guild}/{channel}[/{message}], the
    /// discord:// form of it, or a bare channel id.
    static func channelID(from raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if DiscordUserClient.isSnowflake(text) { return text }
        guard let url = URL(string: text), let host = url.host?.lowercased(),
              ["discord.com", "www.discord.com", "ptb.discord.com", "canary.discord.com", "discordapp.com", "discord"].contains(host)
        else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 3, parts[0] == "channels", DiscordUserClient.isSnowflake(parts[1]), DiscordUserClient.isSnowflake(parts[2]) else { return nil }
        return parts[2]
    }

    private func restore(message: String?) {
        self.state = self.hasToken ? .connected(username: nil) : .setupRequired
        self.message = message
    }
}

struct DiscordAccountSetupView: View {
    @ObservedObject var model: DiscordAccountSetupModel
    @State private var token = ""
    @State private var channelLink = ""
    @State private var isClearConfirmationPresented = false

    var body: some View {
        Form {
            Section {
                Text("Reads announcement channels through a Discord account's own login, which Discord's terms forbid. Use a second account that has joined the same servers, not your main one. Reading is turned on separately on the Permissions page, behind a warning.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                SecureField(self.model.isConnected ? "Replace token" : "Discord token", text: self.$token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save token") {
                    Task { if await self.model.saveToken(self.token) { self.token = "" } }
                }
                .disabled(self.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.isWorking)
                if let message = self.model.message {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Saving makes one request to confirm the token. It is stored only in this iPhone's Keychain and never logged.")
            }

            Section {
                ForEach(self.model.channels) { channel in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("#\(channel.name)")
                        Text(channel.guildName).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    for index in offsets { self.model.removeChannel(id: self.model.channels[index].id) }
                }
                TextField("Paste a channel link", text: self.$channelLink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add channel") {
                    Task { if await self.model.addChannel(self.channelLink) { self.channelLink = "" } }
                }
                .disabled(self.channelLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.isWorking || !self.model.isConnected)
            } header: {
                Text("Announcement channels")
            } footer: {
                Text("In Discord, long-press the channel and choose Copy Link. Operator reads only the channels listed here, at most \(DiscordReadPace.dailyCap) times a day.")
            }

            if self.model.isConnected {
                Section {
                    Button("Remove token", role: .destructive) { self.isClearConfirmationPresented = true }
                        .disabled(self.isWorking)
                }
            }
        }
        .navigationTitle("Discord")
        .navigationBarTitleDisplayMode(.inline)
        .task { await self.model.check() }
        .alert("Remove Discord token?", isPresented: self.$isClearConfirmationPresented) {
            Button("Remove token", role: .destructive) { Task { await self.model.clearToken() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The channel list stays; reading stops until a token is saved again.")
        }
    }

    private var isWorking: Bool { self.model.state == .checking || self.model.state == .working }
}
