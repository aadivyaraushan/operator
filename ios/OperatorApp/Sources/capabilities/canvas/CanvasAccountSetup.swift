import Combine
import Foundation
import OSLog
import SwiftUI

/// The token in the Keychain; the school's address beside it, in
/// UserDefaults, since it is not a secret; and, when the school allows no
/// tokens, the sign-in kept as a browser session (`sessionCookies`).
struct CanvasAccountStorage: Sendable {
    let loadToken: @Sendable () async throws -> String?
    let saveToken: @Sendable (String) async throws -> Void
    let clearToken: @Sendable () async throws -> Void
    let loadBaseURL: @Sendable () -> URL?
    let saveBaseURL: @Sendable (URL?) -> Void
    /// The school's cookies from the kept sign-in; empty when there is none.
    var sessionCookies: @Sendable (_ host: String) async -> [HTTPCookie] = { _ in [] }
    /// Reads the school's cookies out of the live sign-in and keeps them,
    /// while the setup sheet is still open. Returns what was kept.
    var captureSession: @Sendable (_ host: String) async -> [HTTPCookie] = { _ in [] }
    var clearSession: @Sendable () async -> Void = {}

    /// What signs a read right now: a token when one is saved, else the
    /// kept sign-in, else nothing.
    func credentials() async throws -> CanvasCredentials? {
        if let token = try await self.loadToken(), CanvasClient.plausibleToken(token) { return .token(token) }
        guard let host = self.loadBaseURL()?.host else { return nil }
        let cookies = await self.sessionCookies(host)
        return cookies.isEmpty ? nil : .session(cookies: cookies)
    }
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
    /// Schools matching what the person typed, from Canvas's own finder.
    @Published private(set) var schools: [CanvasSchool] = []
    /// The school picked or typed, before any token exists.
    @Published private(set) var chosenSchool: CanvasSchool?

    private let storage: CanvasAccountStorage
    private let client: CanvasClient
    private let finder: CanvasSchoolFinder
    private let logger = Logger(subsystem: "app.operator.ios", category: "canvas-setup")
    private var hasToken = false
    private var hasSession = false
    private var searchTask: Task<Void, Never>?

    init(storage: CanvasAccountStorage, transport: any PhoneHTTPTransport = URLSessionPhoneHTTPTransport()) {
        self.storage = storage
        self.client = CanvasClient(transport: transport, baseURL: { storage.loadBaseURL() }, credentials: { try await storage.credentials() })
        self.finder = CanvasSchoolFinder(transport: transport)
        self.baseURL = storage.loadBaseURL()
        if let host = self.baseURL?.host { self.chosenSchool = CanvasSchool(name: host, domain: host) }
    }

    /// Searches as the person types; a short pause between keystrokes so
    /// a name is one request, not one per letter.
    func searchSchools(_ term: String) {
        self.searchTask?.cancel()
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { self.schools = []; return }
        self.searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            let results = await self.finder.search(trimmed)
            guard !Task.isCancelled else { return }
            self.schools = results
        }
    }

    func choose(_ school: CanvasSchool) {
        self.chosenSchool = school
        self.schools = []
        self.message = nil
    }

    func clearChosenSchool() {
        guard !self.isConnected else { return }
        self.chosenSchool = nil
        self.schools = []
    }

    /// The address the guided sign-in should open, or nil until a school is chosen.
    var guidedURL: URL? { self.chosenSchool?.baseURL }

    /// Saves a token the guided sign-in captured, for the chosen school.
    /// The web session that made it is dropped: the token is the credential.
    func saveCapturedToken(_ token: String) async -> (ok: Bool, name: String?, message: String?) {
        guard let school = self.chosenSchool else { return (false, nil, "Choose your school first.") }
        let ok = await self.save(address: school.domain, token: token)
        if ok { await self.storage.clearSession() }
        let name: String? = if case let .connected(name) = self.state { name } else { nil }
        return (ok, name, ok ? nil : self.message)
    }

    /// Keeps the guided sign-in as the credential, for a school that lets
    /// students make no tokens. One GET /users/self with the session proves
    /// it, exactly as a token is proved.
    func keepSession() async -> (ok: Bool, name: String?, message: String?) {
        guard let school = self.chosenSchool, let url = school.baseURL, let host = url.host else { return (false, nil, "Choose your school first.") }
        self.state = .working
        self.message = nil
        let previousURL = self.storage.loadBaseURL()
        self.storage.saveBaseURL(url)
        self.baseURL = url
        // Capture while the sheet is still open: canvas_session is a session
        // cookie and is gone from WebKit once the sheet closes.
        let cookies = await self.storage.captureSession(host)
        guard !cookies.isEmpty else {
            self.storage.saveBaseURL(previousURL)
            self.baseURL = previousURL
            self.restore(message: "The sign-in did not finish. Try again.")
            return (false, nil, self.message)
        }
        do {
            try? await self.storage.clearToken()
            let name = try await self.client.me()
            self.hasToken = false
            self.hasSession = true
            self.state = .connected(name: name)
            self.logger.info("[canvas-setup] session kept and verified")
            return (true, name, nil)
        } catch {
            await self.storage.clearSession()
            self.storage.saveBaseURL(previousURL)
            self.baseURL = previousURL
            self.hasSession = false
            self.restore(message: "Canvas did not accept the sign-in. Try again.")
            self.logger.info("[canvas-setup] session rejected")
            return (false, nil, self.message)
        }
    }

    var isConnected: Bool { if case .connected = self.state { return true } else { return false } }

    var statusText: String {
        switch self.state {
        case .checking: "Checking…"
        case .setupRequired: "Setup required"
        case let .connected(name): name.map { "Signed in as \($0)" } ?? self.statusDetail
        case .working: "Working…"
        case .failed: "Could not check"
        }
    }

    /// Whether an address and a token, or a kept sign-in, are saved. No
    /// request to the school.
    func check() async {
        self.state = .checking
        self.message = nil
        do {
            let token = try await self.storage.loadToken()
            self.baseURL = self.storage.loadBaseURL()
            self.hasToken = token.map(CanvasClient.plausibleToken) ?? false
            self.hasSession = if let host = self.baseURL?.host, !self.hasToken { await !self.storage.sessionCookies(host).isEmpty } else { false }
            self.state = (self.hasToken || self.hasSession) && self.baseURL != nil ? .connected(name: nil) : .setupRequired
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
            await self.storage.clearSession()
            self.hasToken = false
            self.hasSession = false
            self.state = .setupRequired
            self.message = nil
            self.logger.info("[canvas-setup] token removed")
        } catch {
            self.restore(message: "The saved Canvas token could not be removed.")
        }
    }

    private func restore(message: String?) {
        self.state = (self.hasToken || self.hasSession) && self.baseURL != nil ? .connected(name: nil) : .setupRequired
        self.message = message
    }

    var statusDetail: String {
        self.hasSession ? "Signed in (kept in Operator)" : "Token saved"
    }
}

struct CanvasAccountSetupView: View {
    @ObservedObject var model: CanvasAccountSetupModel
    let sessionStore: CanvasSessionStore
    @State private var schoolQuery = ""
    @State private var pastedToken = ""
    @State private var isGuidedSetupPresented = false
    @State private var isClearConfirmationPresented = false
    @State private var isPasteShown = false

    var body: some View {
        Form {
            Section {
                Text("Reads your courses, what is due and announcements. Sign in to Canvas once here; Operator makes an access token for you, or keeps the sign-in where a school allows no tokens, on this iPhone only. Reading is turned on separately on the Permissions page.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let school = self.model.chosenSchool {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(school.name)
                            if school.name != school.domain { Text(school.domain).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if !self.model.isConnected {
                            Button("Change") { self.schoolQuery = ""; self.model.clearChosenSchool() }
                                .font(.callout)
                        }
                    }
                    .accessibilityIdentifier("canvas-chosen-school")
                } else {
                    TextField("Your school's name", text: self.$schoolQuery)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .onChange(of: self.schoolQuery) { _, term in self.model.searchSchools(term) }
                        .accessibilityIdentifier("canvas-school-search")
                    ForEach(self.model.schools) { school in
                        Button {
                            self.model.choose(school)
                            self.schoolQuery = ""
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(school.name).foregroundStyle(.primary)
                                Text(school.domain).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("School")
            } footer: {
                if self.model.chosenSchool == nil {
                    Text("Type a name and pick your school, or type the Canvas address if you know it (canvas.illinois.edu).")
                }
            }

            if !self.model.isConnected {
                Section {
                    Button {
                        self.isGuidedSetupPresented = true
                    } label: {
                        Label("Sign in and connect", systemImage: "person.badge.key")
                    }
                    .disabled(self.model.guidedURL == nil || self.isWorking)
                    .accessibilityIdentifier("canvas-sign-in")
                    DisclosureGroup("Have a token already?", isExpanded: self.$isPasteShown) {
                        SecureField("Paste access token", text: self.$pastedToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Save token") {
                            guard let school = self.model.chosenSchool else { return }
                            Task { if await self.model.save(address: school.domain, token: self.pastedToken) { self.pastedToken = "" } }
                        }
                        .disabled(self.model.chosenSchool == nil || self.pastedToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.isWorking)
                    }
                } header: {
                    Text("Connect")
                } footer: {
                    Text("Sign in opens your school's Canvas inside Operator, goes to the token page and fills it in; you tap Generate. The session is not kept. If you would rather make the token yourself: Canvas > Account > Settings > Approved Integrations > New Access Token.")
                }
            }

            if let message = self.model.message {
                Section { Text(message).font(.footnote).foregroundStyle(.red) }
            }

            if self.model.isConnected {
                Section {
                    Text(self.model.statusText).foregroundStyle(.secondary)
                    Button("Sign out", role: .destructive) { self.isClearConfirmationPresented = true }
                        .disabled(self.isWorking)
                }
            }
        }
        .navigationTitle("Canvas")
        .navigationBarTitleDisplayMode(.inline)
        .task { await self.model.check() }
        .sheet(isPresented: self.$isGuidedSetupPresented) {
            if let url = self.model.guidedURL {
                CanvasGuidedTokenSetupView(
                    baseURL: url, dataStore: self.sessionStore.dataStore(),
                    onToken: { token in await self.model.saveCapturedToken(token) },
                    onSession: { await self.model.keepSession() })
            }
        }
        .alert("Sign out of Canvas in Operator?", isPresented: self.$isClearConfirmationPresented) {
            Button("Sign out", role: .destructive) { Task { await self.model.clearToken() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Reading stops until you connect again. If Operator made a token, delete it in Canvas too (Account > Settings > Approved Integrations) so it works nowhere.")
        }
    }

    private var isWorking: Bool { self.model.state == .checking || self.model.state == .working }
}
