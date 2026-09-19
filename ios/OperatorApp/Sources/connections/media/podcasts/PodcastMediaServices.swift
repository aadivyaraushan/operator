import Foundation
import OSLog

struct PodcastEpisode: Equatable, Sendable {
    let guid: String
    let title: String
    let published: String
    let enclosureURL: URL
    let enclosureMIMEType: String
}

enum PodcastMediaError: Error, Equatable, Sendable {
    case invalidRequest
    case unsafeURL
    case unsafeXML
    case unavailable
    case invalidResponse
    case openFailed
}

actor PodcastRSSService {
    private let transport: any PhoneHTTPTransport
    private let publicHost: @Sendable (String) async -> Bool
    private let logger = Logger(subsystem: "app.operator.ios", category: "podcast-media")

    init(
        transport: any PhoneHTTPTransport = PublicMediaHTTPTransport(maxResponseBytes: 524_288),
        publicHost: @escaping @Sendable (String) async -> Bool = PublicMediaURLPolicy.hostResolvesOnlyToPublicAddresses
    ) {
        self.transport = transport
        self.publicHost = publicHost
    }

    func search(feedURL: URL, query: String?, limit: Int) async throws -> [PodcastEpisode] {
        try await self.searchValidated(feedURL: feedURL, query: query, limit: limit, maxQueryBytes: 200)
    }

    private func searchValidated(
        feedURL: URL,
        query: String?,
        limit: Int,
        maxQueryBytes: Int
    ) async throws -> [PodcastEpisode] {
        self.logger.info("[podcast-media] search input query_bytes=\(query?.utf8.count ?? 0) limit=\(limit)")
        guard (1 ... 20).contains(limit), Self.validQuery(query, maxBytes: maxQueryBytes) else {
            self.logger.error("[podcast-media] search refused error_code=invalid_request")
            throw PodcastMediaError.invalidRequest
        }
        try await self.requirePublicURL(feedURL)
        try Task.checkCancellation()

        var request = URLRequest(url: feedURL)
        request.httpMethod = "GET"
        request.setValue("application/rss+xml, application/xml, text/xml", forHTTPHeaderField: "Accept")
        self.logger.info("[podcast-media] search request method=GET")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.transport.data(for: request)
        } catch is CancellationError {
            self.logger.info("[podcast-media] search cancelled")
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            self.logger.info("[podcast-media] search cancelled")
            throw error
        } catch PublicMediaTransportError.responseTooLarge {
            self.logger.error("[podcast-media] search failed error_code=response_too_large")
            throw PodcastMediaError.invalidResponse
        } catch {
            self.logger.error("[podcast-media] search failed error_code=unavailable")
            throw PodcastMediaError.unavailable
        }
        guard let http = response as? HTTPURLResponse else {
            self.logger.error("[podcast-media] search failed error_code=unavailable")
            throw PodcastMediaError.unavailable
        }
        self.logger.info("[podcast-media] search response status=\(http.statusCode) bytes=\(data.count)")
        guard http.statusCode == 200 else { throw PodcastMediaError.unavailable }
        guard data.count <= 524_288 else { throw PodcastMediaError.invalidResponse }
        guard !Self.containsForbiddenXMLDeclaration(data) else {
            self.logger.error("[podcast-media] search refused error_code=unsafe_xml")
            throw PodcastMediaError.unsafeXML
        }

        let parserDelegate = BoundedRSSParserDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = parserDelegate
        guard parser.parse(), parserDelegate.failure == nil else {
            if parserDelegate.failure == .unsafeXML { throw PodcastMediaError.unsafeXML }
            throw PodcastMediaError.invalidResponse
        }

        let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var exact: [PodcastEpisode] = []
        var partial: [PodcastEpisode] = []
        for parsed in parserDelegate.items {
            let title = parsed.title.lowercased()
            let guid = parsed.guid.lowercased()
            if let normalizedQuery,
               !title.contains(normalizedQuery),
               !guid.contains(normalizedQuery) { continue }
            guard let url = URL(string: parsed.enclosureURL),
                  parsed.enclosureMIMEType.lowercased().hasPrefix("audio/")
            else { throw PodcastMediaError.invalidResponse }
            try await self.requirePublicURL(url)
            let episode = PodcastEpisode(
                guid: parsed.guid,
                title: parsed.title,
                published: parsed.published,
                enclosureURL: url,
                enclosureMIMEType: parsed.enclosureMIMEType
            )
            if let normalizedQuery, title == normalizedQuery || guid == normalizedQuery {
                exact.append(episode)
            } else {
                partial.append(episode)
            }
        }
        let selected = exact.isEmpty ? partial : exact
        let result = Array(selected.prefix(limit))
        self.logger.info("[podcast-media] search complete parsed_count=\(parserDelegate.items.count) result_count=\(result.count)")
        return result
    }

    func resolve(feedURL: URL, episodeID: String) async throws -> PodcastEpisode? {
        guard Self.validText(episodeID, maxBytes: 2_048, required: true) else {
            throw PodcastMediaError.invalidRequest
        }
        return try await self.searchValidated(
            feedURL: feedURL,
            query: episodeID,
            limit: 20,
            maxQueryBytes: 2_048
        )
            .first(where: { $0.guid == episodeID })
    }

    private func requirePublicURL(_ url: URL) async throws {
        guard PublicMediaURLPolicy.isStructurallySafe(url),
              let host = url.host,
              await self.publicHost(host)
        else {
            self.logger.error("[podcast-media] URL refused error_code=unsafe_url")
            throw PodcastMediaError.unsafeURL
        }
    }

    private static func validQuery(_ query: String?, maxBytes: Int) -> Bool {
        guard let query else { return true }
        return self.validText(query, maxBytes: maxBytes, required: true)
    }

    private static func validText(_ value: String, maxBytes: Int, required: Bool) -> Bool {
        guard value.utf8.count <= maxBytes,
              !value.unicodeScalars.contains(where: { $0.value == 0 })
        else { return false }
        return !required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func containsForbiddenXMLDeclaration(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8)?.uppercased() else { return true }
        return text.contains("<!DOCTYPE") || text.contains("<!ENTITY")
    }
}

@MainActor
final class PodcastEnclosureOpenService {
    private let opener: any AppHandoffOpener
    private let publicHost: @Sendable (String) async -> Bool
    private let logger = Logger(subsystem: "app.operator.ios", category: "podcast-media")

    init(
        opener: any AppHandoffOpener,
        publicHost: @escaping @Sendable (String) async -> Bool = PublicMediaURLPolicy.hostResolvesOnlyToPublicAddresses
    ) {
        self.opener = opener
        self.publicHost = publicHost
    }

    func open(_ episode: PodcastEpisode) async throws -> MediaOpenReceipt {
        let url = episode.enclosureURL
        guard episode.enclosureMIMEType.lowercased().hasPrefix("audio/"),
              PublicMediaURLPolicy.isStructurallySafe(url),
              let host = url.host,
              await self.publicHost(host)
        else {
            self.logger.error("[podcast-media] open refused error_code=unsafe_url")
            throw PodcastMediaError.unsafeURL
        }
        self.logger.info("[podcast-media] open request url_bytes=\(url.absoluteString.utf8.count)")
        guard await self.opener.open(url) else {
            self.logger.error("[podcast-media] open failed error_code=open_failed")
            throw PodcastMediaError.openFailed
        }
        self.logger.info("[podcast-media] open complete action_completed=false playback_verified=false")
        return .init(openedURL: url, actionCompleted: false, playbackVerified: false)
    }
}

private final class BoundedRSSParserDelegate: NSObject, XMLParserDelegate {
    struct ParsedItem {
        let guid: String
        let title: String
        let published: String
        let enclosureURL: String
        let enclosureMIMEType: String
    }

    private(set) var items: [ParsedItem] = []
    private(set) var failure: PodcastMediaError?
    private var insideItem = false
    private var currentElement = ""
    private var title = ""
    private var guid = ""
    private var published = ""
    private var enclosureURL = ""
    private var enclosureMIMEType = ""
    private var enclosureLength = ""

    func parser(
        _: XMLParser,
        resolveExternalEntityName _: String,
        systemID _: String?
    ) -> Data? {
        self.failure = .unsafeXML
        return nil
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard self.failure == nil else { parser.abortParsing(); return }
        let element = elementName.lowercased()
        if element == "item" {
            guard self.items.count < 50 else {
                self.failure = .invalidResponse
                parser.abortParsing()
                return
            }
            self.insideItem = true
            self.title = ""
            self.guid = ""
            self.published = ""
            self.enclosureURL = ""
            self.enclosureMIMEType = ""
            self.enclosureLength = ""
        }
        guard self.insideItem else { return }
        self.currentElement = element
        if element == "enclosure" {
            self.enclosureURL = attributeDict.firstValue(caseInsensitiveKey: "url") ?? ""
            self.enclosureMIMEType = attributeDict.firstValue(caseInsensitiveKey: "type") ?? ""
            self.enclosureLength = attributeDict.firstValue(caseInsensitiveKey: "length") ?? ""
            guard Self.valid(self.enclosureURL, maxBytes: 2_048, required: true),
                  Self.valid(self.enclosureMIMEType, maxBytes: 128, required: true),
                  self.enclosureLength.range(of: #"^[0-9]{1,20}$"#, options: .regularExpression) != nil,
                  UInt64(self.enclosureLength) != nil
            else {
                self.failure = .invalidResponse
                parser.abortParsing()
                return
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard self.insideItem, self.failure == nil else { return }
        switch self.currentElement {
        case "title":
            self.append(string, to: &self.title, limit: 512, parser: parser)
        case "guid":
            self.append(string, to: &self.guid, limit: 2_048, parser: parser)
        case "pubdate":
            self.append(string, to: &self.published, limit: 128, parser: parser)
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        let element = elementName.lowercased()
        if element == self.currentElement { self.currentElement = "" }
        guard element == "item", self.insideItem, self.failure == nil else { return }
        self.insideItem = false
        let cleanTitle = self.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanGuid = self.guid.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPublished = self.published.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.valid(cleanTitle, maxBytes: 512, required: true),
              Self.valid(cleanGuid, maxBytes: 2_048, required: false),
              Self.valid(cleanPublished, maxBytes: 128, required: false)
        else {
            self.failure = .invalidResponse
            parser.abortParsing()
            return
        }
        guard !self.enclosureURL.isEmpty else { return }
        self.items.append(.init(
            guid: cleanGuid.isEmpty ? self.enclosureURL : cleanGuid,
            title: cleanTitle,
            published: cleanPublished,
            enclosureURL: self.enclosureURL,
            enclosureMIMEType: self.enclosureMIMEType
        ))
    }

    private func append(_ string: String, to field: inout String, limit: Int, parser: XMLParser) {
        guard string.utf8.count <= limit, field.utf8.count <= limit - string.utf8.count else {
            self.failure = .invalidResponse
            parser.abortParsing()
            return
        }
        field += string
    }

    private static func valid(_ value: String, maxBytes: Int, required: Bool) -> Bool {
        guard value.utf8.count <= maxBytes,
              !value.unicodeScalars.contains(where: { $0.value == 0 })
        else { return false }
        return !required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private extension Dictionary where Key == String, Value == String {
    func firstValue(caseInsensitiveKey key: String) -> String? {
        self.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
}
