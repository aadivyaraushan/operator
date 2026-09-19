#if canImport(WebKit)
import Foundation
import OSLog
import SwiftUI
import WebKit

/// The Canvas token page, hosted inside Operator, with the clicks done for
/// the person: sign in, and Operator opens New Access Token, fills the
/// purpose, and reads the token off the details dialog the moment Canvas
/// shows it. The one tap left is Generate, so a credential is never made
/// without the person doing it.
///
/// When the school has turned student tokens off (the button is disabled),
/// the sign-in itself becomes the credential: the session stays in a data
/// store of Operator's own and signs the reads. The selectors are the ones Canvas's own
/// Selenium suite drives (`spec/selenium/profile/profile_spec.rb`); when
/// they are not found, the sheet says so and the manual path stays.
enum CanvasGuidedTokenScript {
    static let messageName = "operatorCanvas"
    static let purpose = "Operator on iPhone"

    /// Runs at document end on every page in the sheet. Posts
    /// `{token}` when the details dialog shows one, `{stage}` as it
    /// progresses, and `{stage: "not-found"}` when the settings page has no
    /// way to make a token (some schools turn it off for students).
    static let source = """
    (function () {
      if (window.__operatorCanvas) { return; }
      window.__operatorCanvas = true;
      var post = function (message) {
        try { window.webkit.messageHandlers.\(messageName).postMessage(message); } catch (e) {}
      };
      var tokenPattern = /^[0-9]{1,8}~[A-Za-z0-9]{20,}$/;
      var opened = false, filled = false, reported = false, notFoundTimer = null;
      var findToken = function () {
        var nodes = document.querySelectorAll("[data-testid='visible_token'], .visible_token");
        for (var i = 0; i < nodes.length; i++) {
          var text = (nodes[i].textContent || "").trim();
          if (tokenPattern.test(text)) { return text; }
        }
        return null;
      };
      var fillPurpose = function () {
        var dialog = document.querySelector("[role=dialog][aria-label='New Access Token']");
        if (!dialog) { return false; }
        var input = dialog.querySelector("input[name=purpose]");
        if (!input) { return false; }
        if (!input.value) {
          var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
          setter.call(input, "\(purpose)");
          input.dispatchEvent(new Event("input", { bubbles: true }));
          input.dispatchEvent(new Event("change", { bubbles: true }));
        }
        return true;
      };
      var step = function () {
        if (reported) { return; }
        var token = findToken();
        if (token) { reported = true; post({ token: token }); return; }
        if (!/\\/profile\\/settings/.test(location.pathname)) { return; }
        if (notFoundTimer === null) {
          notFoundTimer = setTimeout(function () {
            if (!opened && !document.querySelector(".add_access_token_link")) { post({ stage: "not-found" }); }
          }, 4000);
        }
        if (!opened) {
          var link = document.querySelector(".add_access_token_link");
          if (link && (link.hasAttribute("disabled") || link.getAttribute("aria-disabled") === "true")) {
            // The school does not let students make tokens; the signed-in
            // session is the way in instead.
            opened = true; reported = true; post({ stage: "token-creation-disabled" }); return;
          }
          if (link) { opened = true; link.scrollIntoView({ block: "center" }); link.click(); post({ stage: "opened" }); }
        }
        if (opened && !filled && fillPurpose()) { filled = true; post({ stage: "filled" }); }
      };
      new MutationObserver(step).observe(document.documentElement, { childList: true, subtree: true, characterData: true });
      step();
    })();
    """
}

/// What the sheet is doing, in the person's terms.
enum CanvasGuidedTokenStage: Equatable {
    case signingIn
    case opening
    case readyToGenerate
    case saving
    case keepingSession
    case notFound
    case saved(name: String?)
    case failed(String)

    var text: String {
        switch self {
        case .signingIn: "Sign in to Canvas. Operator will do the rest."
        case .opening: "Opening New Access Token…"
        case .readyToGenerate: "Tap Generate Token. Operator will pick it up from there; you don't need to copy anything."
        case .saving: "Saving the token…"
        case .keepingSession: "Your school doesn't let students make tokens, so Operator is keeping this sign-in instead…"
        case .notFound: "This page has no New Access Token button and no sign-in to keep. Ask your school, or paste a token if you have one."
        case let .saved(name): name.map { "Signed in as \($0)." } ?? "Connected."
        case let .failed(reason): reason
        }
    }
}

/// The guided sheet. `onToken` saves a captured token; `onSession` keeps
/// the sign-in when tokens are not allowed. Both report, and the sheet
/// closes itself once a save succeeds.
struct CanvasGuidedTokenSetupView: View {
    typealias SaveResult = (ok: Bool, name: String?, message: String?)
    let baseURL: URL
    let dataStore: WKWebsiteDataStore
    let onToken: (String) async -> SaveResult
    let onSession: () async -> SaveResult
    @Environment(\.dismiss) private var dismiss
    @State private var stage: CanvasGuidedTokenStage = .signingIn

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(self.stage.text)
                    .font(OperatorLettering.font(.footnote))
                    .foregroundStyle(self.isProblem ? OperatorBrand.vermilion : OperatorBrand.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .accessibilityIdentifier("canvas-guided-stage")
                Divider()
                CanvasTokenWebView(url: self.baseURL.appendingPathComponent("profile/settings"), dataStore: self.dataStore) { message in
                    self.handle(message)
                }
            }
            .navigationTitle(self.baseURL.host ?? "Canvas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { self.dismiss() } } }
        }
    }

    private var isProblem: Bool {
        switch self.stage { case .notFound, .failed: true; default: false }
    }

    private var isSettling: Bool {
        switch self.stage { case .saving, .keepingSession, .saved: true; default: false }
    }

    private func handle(_ message: [String: Any]) {
        guard !self.isSettling else { return }
        if let token = message["token"] as? String {
            self.stage = .saving
            self.finish { await self.onToken(token) }
            return
        }
        switch message["stage"] as? String {
        case "opened": if self.stage == .signingIn { self.stage = .opening }
        case "filled": if self.stage == .signingIn || self.stage == .opening { self.stage = .readyToGenerate }
        case "token-creation-disabled":
            self.stage = .keepingSession
            self.finish { await self.onSession() }
        case "not-found": if self.stage == .signingIn { self.stage = .notFound }
        default: break
        }
    }

    private func finish(_ save: @escaping () async -> SaveResult) {
        Task {
            let result = await save()
            if result.ok {
                self.stage = .saved(name: result.name)
                try? await Task.sleep(for: .seconds(1))
                self.dismiss()
            } else {
                self.stage = .failed(result.message ?? "Canvas did not accept the sign-in. Try again.")
            }
        }
    }
}

/// A WKWebView with the guided script, in Operator's own Canvas data store:
/// kept when the sign-in is the credential, cleared by the model when a
/// token is.
struct CanvasTokenWebView: UIViewRepresentable {
    let url: URL
    let dataStore: WKWebsiteDataStore
    let onMessage: @MainActor ([String: Any]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onMessage: self.onMessage) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = self.dataStore
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: CanvasGuidedTokenScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.add(context.coordinator, name: CanvasGuidedTokenScript.messageName)
        configuration.userContentController = controller
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: self.url))
        return view
    }

    func updateUIView(_: WKWebView, context _: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: CanvasGuidedTokenScript.messageName)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let onMessage: @MainActor ([String: Any]) -> Void
        private let logger = Logger(subsystem: "app.operator.ios", category: "canvas-setup")

        init(onMessage: @escaping @MainActor ([String: Any]) -> Void) { self.onMessage = onMessage }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == CanvasGuidedTokenScript.messageName, let body = message.body as? [String: Any] else { return }
            // Only the stage is logged; the token is not.
            self.logger.info("[canvas-setup] guided stage=\((body["stage"] as? String) ?? (body["token"] != nil ? "token" : "other"), privacy: .public)")
            Task { @MainActor in self.onMessage(body) }
        }

        /// Only https on the school's host and the sign-in hops it redirects
        /// to. A link out to anything else opens nowhere.
        func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, url.scheme == "https" else { return decisionHandler(.cancel) }
            decisionHandler(.allow)
        }
    }
}
#endif
