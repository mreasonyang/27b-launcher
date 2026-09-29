import Foundation

struct LocalModelCatalog: Sendable {
    let session: URLSession

    init(session: URLSession = LocalMonitorTransport.session()) {
        self.session = session
    }

    func modelID(baseURL: URL) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "v1/models"))
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request, delegate: LocalMonitorRedirectPolicy())
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CatalogError.invalidResponse
        }
        return try Self.decodeModelID(data)
    }

    static func decodeModelID(_ data: Data) throws -> String {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let id = response.data.first?.id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CatalogError.invalidResponse
        }
        return id
    }

    private struct Response: Decodable {
        let data: [Model]
        struct Model: Decodable { let id: String }
    }
    enum CatalogError: Error { case invalidResponse }
}
