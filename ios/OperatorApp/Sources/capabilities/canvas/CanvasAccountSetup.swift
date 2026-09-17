import Combine
import Foundation
import OSLog
import SwiftUI

/// The token in the Keychain; the school's address beside it, in
/// UserDefaults, since it is not a secret.
struct CanvasAccountStorage: Sendable {
    let loadToken: @Sendable () async throws -> String?
    let saveToken: @Sendable (String) async throws -> Void
    let clearToken: @Sendable () async throws -> Void
    let loadBaseURL: @Sendable () -> URL?
    let saveBaseURL: @Sendable (URL?) -> Void
}

final class UserDefaultsCanvasBaseURLStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "app.operator.canvas.baseURL"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> URL? {
        self.defaults.string(forKey: self.key).flatMap(CanvasClient.baseURL(from:))
    }
    func save(_ url: URL?) {
        if let url { self.defaults.set(url.absoluteString, forKey: self.key) } else { self.defaults.removeObject(forKey: self.key) }
    }
}

enum CanvasAccountSetupState: Equatable {
    case checking
    case setupRequired
    case connected(name: String?)
    case working
    case failed
}

@MainActor
final class CanvasAccountSetupModel: ObservableObject {
    @Published private(set) var state: CanvasAccountSetupState = .checking
    @Published private(set) var baseURL: URL?
    @Published private(set) var message: String?

    private let storage: CanvasAccountStorage
    private let client: CanvasClient
    private let logger = Logger(subsystem: "app.operator.ios", category: "canvas-setup")
    private var hasToken = false

    init(storage: CanvasAccountStorage, transport: any PhoneHTTPTransport = URLSessionPhoneHTTPTransport()) {
        self.storage = storage
        self.client = CanvasClient(transport: transport, baseURL: { storage.loadBaseURL() }, token: { try await storage.loadToken() })
        self.baseURL = storage.loadBaseURL()
    }

    var isConnected: Bool { if case .connected = self.state { return true } else { return false } }

    var statusText: String {
        switch self.state {
        case .checking: "Checking…"
        case .setupRequired: "Setup required"
        case let .connected(name): name.map { "Signed in as \($0)" } ?? "Token saved"
        case .working: "Working…"
        case .failed: "Could not check"
        }
    }

    /// Whether an address and a token are saved. No request.
    func check() async {
        self.state = .checking
        self.message = nil
        do {
            let token = try await self.storage.loadToken()
            self.baseURL = self.storage.loadBaseURL()
            self.hasToken = token.map(CanvasClient.plausibleToken) ?? false
            self.state = self.hasToken && self.baseURL != nil ? .connected(name: nil) : .setupRequired
        } catch {
            self.hasToken = false
            self.state = .failed
            self.message = "The saved Canvas token could not be checked."
            self.logger.error("[canvas-setup] token check failed")
        }
    }

    /// Saves the address and token after one GET /users/self proves they
    /// go together. The only request setup makes.
    func save(address rawAddress: String, token rawToken: String) async -> Bool {
        guard let url = CanvasClient.baseURL(from: rawAddress) else {
            self.restore(message: "Enter your school's Canvas address, like canvas.illinois.edu.")
            return false
        }
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CanvasClient.plausibleToken(token) else {
            self.restore(message: "That does not look like a Canvas access token.")
            return false
        }
        self.state = .working
        self.message = nil
        let previousURL = self.storage.loadBaseURL()
        do {
            self.storage.saveBaseURL(url)
            self.baseURL = url
            try await self.storage.saveToken(token)
            let name = try await self.client.me()
            self.hasToken = true
            self.state = .connected(name: name)
            self.logger.info("[canvas-setup] token saved and verified")
            return true
        } catch let error as CanvasClientError {
            try? await self.storage.clearToken()
            self.storage.saveBaseURL(previousURL)
            self.baseURL = previousURL
            self.hasToken = false
            let why: String = switch error {
            case .notConnected: "Canvas did not accept that token."
            case .notVisible: "Canvas at that address did not answer as expected. Check the address."
            case .rateLimited: "Canvas asked to slow down. Try again in a minute."
            default: "Canvas could not be reached at that address. Nothing was saved."
            }
            self.restore(message: why)
            self.logger.info("[canvas-setup] token rejected error=\(String(describing: error), privacy: .public)")
            return false
        } catch {
            self.hasToken = false
            self.restore(message: "The Canvas token could not be saved.")
            self.logger.error("[canvas-setup] token save failed")
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
            self.logger.info("[canvas-setup] token removed")
        } catch {
            self.restore(message: "The saved Canvas token could not be removed.")
        }
    }

    private func restore(message: String?) {
        self.state = self.hasToken && self.baseURL != nil ? .connected(name: nil) : .setupRequired
        self.message = message
    }
}

struct CanvasAccountSetupView: View {
    @ObservedObject var model: CanvasAccountSetupModel
    @State private var address = ""
    @State private var token = ""
    @State private var isClearConfirmationPresented = false

    var body: some View {
        Form {
            Section {
                Text("Reads your courses, what is due and announcements through an access token you make in Canvas. Canvas supports these tokens for exactly this; nothing here can affect your account. Reading is turned on separately on the Permissions page.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField("School's Canvas address", text: self.$address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField(self.model.isConnected ? "Replace access token" : "Access token", text: self.$token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save") {
                    Task { if await self.model.save(address: self.address, token: self.token) { self.token = "" } }
                }
                .disabled(self.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.isWorking)
                if let message = self.model.message {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Account")
            } footer: {
                Text("In Canvas: Account > Settings > Approved Integrations > New Access Token. Saving makes one request to confirm it. The token is stored only in this iPhone's Keychain and never logged.")
            }

            if self.model.isConnected {
                Section {
                    Button("Remove token", role: .destructive) { self.isClearConfirmationPresented = true }
                        .disabled(self.isWorking)
                }
            }
        }
        .navigationTitle("Canvas")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await self.model.check()
            if self.address.isEmpty, let host = self.model.baseURL?.host { self.address = host }
        }
        .alert("Remove Canvas token?", isPresented: self.$isClearConfirmationPresented) {
            Button("Remove token", role: .destructive) { Task { await self.model.clearToken() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Reading stops until a token is saved again. Delete the token in Canvas too if it should no longer work anywhere.")
        }
    }

    private var isWorking: Bool { self.model.state == .checking || self.model.state == .working }
}
