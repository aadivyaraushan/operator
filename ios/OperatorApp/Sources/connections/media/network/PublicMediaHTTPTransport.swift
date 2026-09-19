import Foundation

enum PublicMediaTransportError: Error, Equatable, Sendable {
    case forbiddenRequestState
    case redirectRejected
    case responseTooLarge
}

struct PublicMediaResponseBuffer: Sendable {
    let limit: Int
    private(set) var data = Data()

    mutating func append(_ chunk: Data) -> Bool {
        guard chunk.count <= self.limit,
              self.data.count <= self.limit - chunk.count
        else { return false }
        self.data.append(chunk)
        return true
    }
}

struct PublicMediaHTTPTransport: PhoneHTTPTransport {
    private let maxResponseBytes: Int
    private let timeout: TimeInterval

    init(maxResponseBytes: Int, timeout: TimeInterval = 20) {
        self.maxResponseBytes = maxResponseBytes
        self.timeout = timeout
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard (1 ... 1_048_576).contains(self.maxResponseBytes),
              request.value(forHTTPHeaderField: "Authorization") == nil,
              request.value(forHTTPHeaderField: "Cookie") == nil
        else { throw PublicMediaTransportError.forbiddenRequestState }

        let session = URLSession(configuration: Self.configuration(timeout: self.timeout))
        defer { session.invalidateAndCancel() }
        let redirectDelegate = PublicMediaRedirectRejector()
        let (bytes, response) = try await session.bytes(for: request, delegate: redirectDelegate)
        if let http = response as? HTTPURLResponse, (300 ... 399).contains(http.statusCode) {
            throw PublicMediaTransportError.redirectRejected
        }

        var buffer = PublicMediaResponseBuffer(limit: self.maxResponseBytes)
        var chunk = Data()
        chunk.reserveCapacity(8_192)
        for try await byte in bytes {
            try Task.checkCancellation()
            guard buffer.data.count + chunk.count < self.maxResponseBytes else {
                throw PublicMediaTransportError.responseTooLarge
            }
            chunk.append(byte)
            if chunk.count == 8_192 {
                guard buffer.append(chunk) else { throw PublicMediaTransportError.responseTooLarge }
                chunk.removeAll(keepingCapacity: true)
            }
        }
        guard buffer.append(chunk) else { throw PublicMediaTransportError.responseTooLarge }
        return (buffer.data, response)
    }

    static func configuration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        return configuration
    }
}

private final class PublicMediaRedirectRejector: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
