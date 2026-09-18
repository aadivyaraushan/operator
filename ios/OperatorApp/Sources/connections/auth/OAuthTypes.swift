import CryptoKit
import Foundation

enum OAuthProvider: String, Codable, CaseIterable, Sendable {
    case google
    case microsoftOutlook
    case slack
    case spotify

    var scopes: [String] {
        switch self {
        case .google:
            [
                "https://www.googleapis.com/auth/calendar.events",
                // All of Drive, read and write, which the Docs, Sheets and
                // Slides APIs accept too. drive.file showed only files
                // Operator had made itself, so the owner's own sheet could
                // not be found. Restricted, like gmail.readonly below.
                "https://www.googleapis.com/auth/drive",
                // Restricted scope. Works today because the project is in
                // Testing mode with named test users; a public release would
                // need a CASA security assessment first.
                "https://www.googleapis.com/auth/gmail.readonly",
                "https://www.googleapis.com/auth/tasks",
            ]
        case .microsoftOutlook:
            ["openid", "offline_access", "User.Read", "Mail.ReadWrite", "Mail.Send", "Calendars.ReadWrite"]
        case .slack:
            ["chat:write", "channels:read", "channels:history", "groups:read", "groups:history", "im:write", "im:history", "users:read"]
        case .spotify:
            ["user-read-playback-state", "user-modify-playback-state"]
        }
    }

    /// Extra authorization-request parameters a provider needs beyond the
    /// standard OAuth set.
    ///
    /// Google is the reason this exists. It issues a refresh token only when
    /// `access_type=offline` is on the authorization request - the value is a
    /// query parameter, not a scope, so nothing in `scopes` above can stand in
    /// for it. Without it the grant works exactly once and then expires about
    /// an hour later with no way to renew, which shows up much later as
    /// `[account-setup] saved connection unavailable` on the next launch
    /// rather than as a failure at sign-in.
    ///
    /// `prompt=consent` is the companion: Google returns a refresh token only
    /// on a consent it treats as new, so a re-authorization can otherwise come
    /// back without one and leave the account in the same dead state.
    var authorizationParameters: [String: String] {
        switch self {
        case .google: ["access_type": "offline", "prompt": "consent"]
        case .microsoftOutlook, .slack, .spotify: [:]
        }
    }

    var requiredAccessTokenScopes: [String] {
        switch self {
        case .microsoftOutlook:
            self.scopes.filter { $0 != "openid" && $0 != "offline_access" }
        default:
            self.scopes
        }
    }

    var authorizationEndpoint: URL {
        switch self {
        case .google: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        case .microsoftOutlook: URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize")!
        case .slack: URL(string: "https://slack.com/oauth/v2/authorize")!
        case .spotify: URL(string: "https://accounts.spotify.com/authorize")!
        }
    }

    var tokenEndpoint: URL {
        switch self {
        case .google: URL(string: "https://oauth2.googleapis.com/token")!
        case .microsoftOutlook: URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!
        case .slack: URL(string: "https://slack.com/api/oauth.v2.access")!
        case .spotify: URL(string: "https://accounts.spotify.com/api/token")!
        }
    }
}

struct OAuthPublicClientRegistration: Sendable, Equatable {
    let clientID: String
    let redirectURI: String

    init(clientID: String, redirectURI: String) {
        self.clientID = clientID
        self.redirectURI = redirectURI
    }

    var isValid: Bool {
        !self.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && URL(string: self.redirectURI) != nil
    }
}

struct OAuthAuthorizationRequest: Sendable, Equatable {
    let url: URL
    let state: String
    let codeVerifier: String
}

struct OAuthTokens: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let grantedScopes: [String]
}

enum PhoneOAuthError: String, Error, Equatable, Sendable {
    case missingRegistration
    case invalidAccountID
    case callbackRedirectMismatch
    case callbackStateMismatch
    case authorizationDenied
    case missingAuthorizationCode
    case missingPendingAuthorization
    case missingStoredTokens
    case notConnected
    case randomGenerationFailed
    case tokenRequestFailed
    case invalidTokenResponse
    case reauthorizationRequired
    case credentialStoreCorrupt
}

extension String {
    var s256Challenge: String {
        let digest = SHA256.hash(data: Data(self.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
