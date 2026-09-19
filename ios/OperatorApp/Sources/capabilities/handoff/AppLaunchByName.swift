import Foundation

// Opening an installed app by the name the owner used ("open google docs").
// iOS has no approved call for this, so there are two steps: the app's own
// link when the bundled table has one, then Apple's private launch call by
// bundle id. The private call must come out before an App Store submission.

/// Opens things outside Operator. Both leave Operator on success.
@MainActor
protocol InstalledAppLaunching: AnyObject {
    func openLink(_ url: URL) async -> Bool
    func openBundle(_ bundleID: String) -> Bool
}

/// Finds the bundle id of an app the table does not list.
protocol AppBundleLookup: Sendable {
    func bundleID(forName name: String) async -> String?
}

struct AppLinkTable: Sendable {
    struct Entry: Decodable, Sendable {
        let names: [String]
        let link: String?
        let bundleID: String?
    }
    enum InvalidTable: Error { case invalidEntry }

    let entries: [Entry]
    static let empty = AppLinkTable(entries: [])

    static func decode(_ data: Data) throws -> AppLinkTable {
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        for entry in entries {
            guard !entry.names.isEmpty, entry.names.allSatisfy({ $0 == Self.normalized($0) && !$0.isEmpty }),
                  entry.link != nil || entry.bundleID != nil,
                  entry.link.map(Self.isAppLink) ?? true,
                  entry.bundleID.map(Self.isBundleID) ?? true
            else { throw InvalidTable.invalidEntry }
        }
        return AppLinkTable(entries: entries)
    }

    func match(_ name: String) -> Entry? {
        let wanted = Self.normalized(name)
        return self.entries.first { $0.names.contains(wanted) }
    }

    static func normalized(_ name: String) -> String {
        name.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    /// A bare app scheme such as googledocs:// - never a web, file or script URL.
    static func isAppLink(_ value: String) -> Bool {
        guard value.range(of: #"^[A-Za-z][A-Za-z0-9+.-]{1,63}:(//)?$"#, options: .regularExpression) != nil,
              let scheme = URL(string: value)?.scheme?.lowercased()
        else { return false }
        return !["http", "https", "file", "javascript", "data", "tel", "sms", "mailto", "facetime"].contains(scheme)
    }

    static func isBundleID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]{2,154}$"#, options: .regularExpression) != nil && value.contains(".")
    }
}

/// Apple's public app search (free, no key). Only the app's name leaves the phone.
struct AppStoreBundleLookup: AppBundleLookup {
    let region: String
    let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    func bundleID(forName name: String) async -> String? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: name), URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "country", value: self.region), URLQueryItem(name: "limit", value: "10"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url); request.timeoutInterval = 8
        guard let (data, response) = try? await self.fetch(request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_000_000,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]]
        else { return nil }
        let wanted = AppLinkTable.normalized(name)
        // The store title is often "Name: tagline" or "Name - tagline". Only a
        // title that is the asked name counts; a lookalike must not be opened.
        let hit = results.first { result in
            guard let title = result["trackName"] as? String else { return false }
            let head = title.components(separatedBy: CharacterSet(charactersIn: ":-–—|")).first ?? title
            return AppLinkTable.normalized(title) == wanted || AppLinkTable.normalized(head.trimmingCharacters(in: .whitespaces)) == wanted
        }
        guard let bundleID = hit?["bundleId"] as? String, AppLinkTable.isBundleID(bundleID) else { return nil }
        return bundleID
    }
}
