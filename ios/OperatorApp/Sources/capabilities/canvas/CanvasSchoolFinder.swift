import Foundation
import OSLog

/// A school as Canvas's own finder lists it: the name a student knows and
/// the Canvas host behind it.
struct CanvasSchool: Equatable, Identifiable, Sendable {
    let name: String
    let domain: String
    var id: String { self.domain }
    var baseURL: URL? { CanvasClient.baseURL(from: self.domain) }
}

/// Canvas's public school search, the one the Canvas Student app uses on
/// its first screen. No token, nothing about the person: the query is the
/// school's name. So setup starts with "type your school", not "find your
/// institution's Canvas address".
actor CanvasSchoolFinder {
    static let endpoint = URL(string: "https://canvas.instructure.com/api/v1/accounts/search")!
    static let maxBodyBytes = 262_144
    static let resultLimit = 8

    private let transport: any PhoneHTTPTransport
    private let logger = Logger(subsystem: "app.operator.ios", category: "canvas-setup")

    init(transport: any PhoneHTTPTransport = URLSessionPhoneHTTPTransport()) {
        self.transport = transport
    }

    /// Schools matching `term`, one per host, in Canvas's order. A term that
    /// already looks like a Canvas host is offered as-is first, so a person
    /// who knows the address is never blocked by the search.
    func search(_ term: String) async -> [CanvasSchool] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        var results: [CanvasSchool] = []
        if let direct = CanvasClient.baseURL(from: trimmed), let host = direct.host {
            results.append(CanvasSchool(name: host, domain: host))
        }
        guard var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false) else { return results }
        components.queryItems = [URLQueryItem(name: "search_term", value: String(trimmed.prefix(80)))]
        guard let url = components.url else { return results }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await self.transport.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= Self.maxBodyBytes,
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else {
            self.logger.info("[canvas-setup] school search unavailable")
            return results
        }
        results.append(contentsOf: Self.schools(from: array).filter { school in !results.contains { $0.domain == school.domain } })
        return Array(results.prefix(Self.resultLimit))
    }

    static func schools(from array: [[String: Any]]) -> [CanvasSchool] {
        var seen: Set<String> = []
        var out: [CanvasSchool] = []
        for object in array {
            guard let name = object["name"] as? String, !name.isEmpty,
                  let domain = (object["domain"] as? String)?.lowercased(), let url = CanvasClient.baseURL(from: domain), let host = url.host,
                  !seen.contains(host)
            else { continue }
            seen.insert(host)
            out.append(CanvasSchool(name: String(name.prefix(120)), domain: host))
        }
        return out
    }
}
