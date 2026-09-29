import Foundation
import Testing
@testable import Launcher27B

@Suite
struct LocalModelCatalogTests {
    @Test func preservesTheExactServerModelID() throws {
        let data = Data(#"{"data":[{"id":"/Models/Bonsai-27B.gguf"}]}"#.utf8)
        #expect(try LocalModelCatalog.decodeModelID(data) == "/Models/Bonsai-27B.gguf")
    }

    @Test(arguments: [#"{"data":[]}"#, #"{"data":[{"id":" "}]}"#,
                       #"{"data":[{}]}"#, "<html>Unavailable</html>"])
    func refusesMissingOrMalformedModelIDs(payload: String) {
        #expect(throws: (any Error).self) { try LocalModelCatalog.decodeModelID(Data(payload.utf8)) }
    }

    @Test func fetchesModelIDWithoutCredentialsAndRejectsHTTPFailures() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModelCatalogTestProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let catalog = LocalModelCatalog(session: session)
        #expect(try await catalog.modelID(baseURL: URL(string: "http://ok.localhost:8080/")!) == "Actual-Model-ID")
        await #expect(throws: (any Error).self) {
            try await catalog.modelID(baseURL: URL(string: "http://reject.localhost:8080/")!)
        }
    }
}

private final class ModelCatalogTestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #expect(request.url?.path == "/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let status = request.url?.host == "reject.localhost" ? 401 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":[{"id":"Actual-Model-ID"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
