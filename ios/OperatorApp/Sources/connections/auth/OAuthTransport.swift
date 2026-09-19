import Foundation

protocol PhoneHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionPhoneHTTPTransport: PhoneHTTPTransport {
    /// A single request's own ceiling, well inside the gateway deadline that
    /// bounds the whole operation. Without this the only bound was
    /// URLSession's default minute, applied per request rather than per
    /// operation - so a Gmail read issuing eleven of them had no meaningful
    /// ceiling at all.
    static let requestTimeoutSeconds: TimeInterval = 15

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        request.timeoutInterval = Self.requestTimeoutSeconds
        let delegate = RejectRedirectsDelegate()
        let result = try await URLSession.shared.data(for: request, delegate: delegate)
        if let response = result.1 as? HTTPURLResponse, (300 ... 399).contains(response.statusCode) {
            throw URLError(.httpTooManyRedirects)
        }
        return result
    }
}

private final class RejectRedirectsDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void)
    {
        completionHandler(nil)
    }
}
