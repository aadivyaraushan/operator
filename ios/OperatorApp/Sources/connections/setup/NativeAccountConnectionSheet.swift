import SwiftUI
import AuthenticationServices
import UIKit

struct NativeAccountConnectionSheet: View {
    @ObservedObject var model: NativeAccountSetupCoordinator
    @ObservedObject var youtube: YouTubeAPIKeySetupModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(OAuthProvider.allCases, id: \.rawValue) { provider in
                        Button { model.connect(provider) } label: {
                            HStack { Text(Self.name(provider)); Spacer(); if model.activeProvider == provider { ProgressView() } else { Text(Self.status(model.state(for: provider))).font(.caption).foregroundStyle(.secondary) } }
                        }
                        .disabled(model.activeProvider != nil || model.state(for: provider) == .needsSetup)
                    }
                }
                Section("Media") {
                    NavigationLink {
                        YouTubeAPIKeySetupView(model: self.youtube)
                    } label: {
                        HStack {
                            Text("YouTube")
                            Spacer()
                            Text(self.youtube.statusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Connect accounts")
            .task {
                async let accounts: Void = self.model.checkConnections()
                async let youtube: Void = self.youtube.check()
                _ = await (accounts, youtube)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.cancel(); dismiss() } } }
        }
    }
    private static func name(_ provider: OAuthProvider) -> String { switch provider { case .google: "Google"; case .microsoftOutlook: "Microsoft Outlook"; case .slack: "Slack"; case .spotify: "Spotify" } }
    private static func status(_ state: NativeAccountSetupState) -> String { switch state { case .needsSetup: "Setup required"; case .connected: "Connected"; case .failed: "Try again"; case .cancelled: "Cancelled"; default: "Connect" } }
}

@MainActor final class SystemOAuthSessionPresenter: NSObject, OAuthSessionPresenting, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?; private var continuation: CheckedContinuation<URL, Error>?; private var generation = 0
    func authenticate(url: URL, callbackScheme: String?) async throws -> URL {
        cancel()
        return try await withCheckedThrowingContinuation { continuation in
            generation += 1; let run = generation
            self.continuation = continuation
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callback, error in
                Task { @MainActor in guard let self, self.generation == run else { return }; if let callback { self.finish(.success(callback)) } else { self.finish(.failure(OAuthSessionCancellation.normalized(error ?? CancellationError()))) } }
            }
            session.presentationContextProvider = self; session.prefersEphemeralWebBrowserSession = true; self.session = session
            if !session.start() { finish(.failure(PhoneOAuthError.authorizationDenied)) }
        }
    }
    func cancel() { generation += 1; session?.cancel(); finish(.failure(CancellationError())) }
    private func finish(_ result: Result<URL, Error>) { session = nil; let saved = continuation; continuation = nil; saved?.resume(with: result) }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first(where: \.isKeyWindow) ?? ASPresentationAnchor() }
}
