import Foundation

struct LlamaMetricsClient: Sendable {
    private let session: URLSession
    private let parser: LlamaMetricsParser
    init(session: URLSession = LocalMonitorTransport.session(), parser: LlamaMetricsParser = LlamaMetricsParser()) {
        self.session = session
        self.parser = parser
    }

    func fetch(baseURL: URL) async throws -> TokenUsageSnapshot {
        var request = URLRequest(url: baseURL.appending(path: "metrics"))
        request.timeoutInterval = 1.5
        // Telemetry must never send a credential to a replaceable local listener.
        let (data, response) = try await session.data(for: request, delegate: LocalMonitorRedirectPolicy())
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LlamaMetricsError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LlamaMetricsError.requestFailed(httpResponse.statusCode)
        }
        guard let payload = String(data: data, encoding: .utf8) else {
            throw LlamaMetricsError.invalidResponse
        }

        return try parser.parse(payload)
    }
}

final class LocalMonitorRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Monitoring never shares browser cookies, saved credentials, cache or redirects.
enum LocalMonitorTransport {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }
}
