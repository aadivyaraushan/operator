import Combine
import Foundation
import OSLog
import SwiftUI

struct YouTubeAPIKeyStorage: Sendable {
    let load: @Sendable () async throws -> Data?
    let save: @Sendable (Data) async throws -> Void
    let clear: @Sendable () async throws -> Void
}

enum YouTubeAPIKeySetupState: Equatable {
    case checking
    case setupRequired
    case keySaved
    case saving
    case clearing
    case failed
}

@MainActor
final class YouTubeAPIKeySetupModel: ObservableObject {
    @Published private(set) var state: YouTubeAPIKeySetupState = .checking
    @Published private(set) var message: String?

    private let storage: YouTubeAPIKeyStorage
    private let logger = Logger(subsystem: "app.operator.ios", category: "youtube-setup")
    private var hasSavedKey = false

    init(storage: YouTubeAPIKeyStorage) {
        self.storage = storage
    }

    var statusText: String {
        switch self.state {
        case .checking: "Checking key…"
        case .setupRequired: "Setup required"
        case .keySaved: "Key saved"
        case .saving: "Saving key…"
        case .clearing: "Removing key…"
        case .failed: "Could not check key"
        }
    }

    func check() async {
        self.state = .checking
        self.message = nil
        self.logger.info("[youtube-setup] checking saved key")
        do {
            self.hasSavedKey = Self.isUsable(try await self.storage.load())
            self.state = self.hasSavedKey ? .keySaved : .setupRequired
            self.logger.info("[youtube-setup] saved key checked usable=\(self.hasSavedKey, privacy: .public)")
        } catch {
            self.hasSavedKey = false
            self.state = .failed
            self.message = "The saved YouTube key could not be checked."
            self.logger.error("[youtube-setup] saved key check failed")
        }
    }

    func save(_ rawKey: String) async -> Bool {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(key.utf8)
        guard !key.isEmpty, data.count <= 4_096 else {
            self.logger.info("[youtube-setup] save rejected reason=invalid_input")
            self.restoreStoredState(message: "Enter a YouTube API key up to 4 KB.")
            return false
        }
        self.state = .saving
        self.message = nil
        self.logger.info("[youtube-setup] saving key")
        do {
            try await self.storage.save(data)
            self.hasSavedKey = true
            self.state = .keySaved
            self.logger.info("[youtube-setup] key saved")
            return true
        } catch {
            self.logger.error("[youtube-setup] key save failed")
            self.restoreStoredState(message: "The YouTube key could not be saved.")
            return false
        }
    }

    func clear() async -> Bool {
        self.state = .clearing
        self.message = nil
        self.logger.info("[youtube-setup] removing key")
        do {
            try await self.storage.clear()
            self.hasSavedKey = false
            self.state = .setupRequired
            self.logger.info("[youtube-setup] key removed")
            return true
        } catch {
            self.logger.error("[youtube-setup] key removal failed")
            self.restoreStoredState(message: "The saved YouTube key could not be removed.")
            return false
        }
    }

    private func restoreStoredState(message: String) {
        self.state = self.hasSavedKey ? .keySaved : .setupRequired
        self.message = message
    }

    private static func isUsable(_ data: Data?) -> Bool {
        guard let data,
              !data.isEmpty,
              data.count <= 4_096,
              let value = String(data: data, encoding: .utf8)
        else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct YouTubeAPIKeySetupView: View {
    @ObservedObject var model: YouTubeAPIKeySetupModel
    @State private var key = ""
    @State private var isClearConfirmationPresented = false

    var body: some View {
        Form {
            Section {
                Text(self.model.state == .keySaved
                     ? "A YouTube API key is saved on this iPhone. Entering a new key replaces it."
                     : "Add a YouTube API key to enable YouTube search.")
                    .foregroundStyle(.secondary)
                SecureField(
                    self.model.state == .keySaved ? "Replace YouTube API key" : "YouTube API key",
                    text: self.$key)
#if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
#endif
                if let message = self.model.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Button("Save key") {
                    Task {
                        if await self.model.save(self.key) {
                            self.key = ""
                        }
                    }
                }
                .disabled(self.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.isWorking)
            } header: {
                Text("YouTube")
            } footer: {
                Text("The key is stored only in this iPhone’s Keychain. A saved key is not a live API check.")
            }

            if self.model.state == .keySaved {
                Section {
                    Button("Remove key", role: .destructive) {
                        self.isClearConfirmationPresented = true
                    }
                    .disabled(self.isWorking)
                }
            }
        }
        .navigationTitle("YouTube")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .task { await self.model.check() }
        .alert("Remove YouTube API key?", isPresented: self.$isClearConfirmationPresented) {
            Button("Remove key", role: .destructive) {
                Task { _ = await self.model.clear() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("YouTube search will require setup again.")
        }
    }

    private var isWorking: Bool {
        self.model.state == .checking || self.model.state == .saving || self.model.state == .clearing
    }
}
