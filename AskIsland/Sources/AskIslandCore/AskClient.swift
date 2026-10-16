import Foundation

public enum AskClientError: Error, LocalizedError, Equatable {
    case notRunning
    case serverError(statusCode: Int, message: String)
    case invalidResponse
    case badRequest(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning:
            return "AskIsland is not running"
        case .serverError(let code, let msg):
            return "Server error (\(code)): \(msg)"
        case .invalidResponse:
            return "Invalid server response"
        case .badRequest(let msg):
            return "Bad request: \(msg)"
        }
    }
}

public final class AskClient: Sendable {
    public let endpointURL: URL

    public init(endpointURL: URL = AskEndpoint.resolvedURL) {
        self.endpointURL = endpointURL
    }

    /// Checks if AskIsland is running by reading the endpoint file,
    /// checking if the process is alive, and hitting GET /health.
    public func isRunning() async -> Bool {
        guard let endpoint = try? loadEndpoint() else {
            return false
        }
        guard let url = URL(string: "http://127.0.0.1:\(endpoint.port)/health") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 2.0
        config.timeoutIntervalForResource = 2.0
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return false
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = json["ok"] as? Bool, ok {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    /// Submits a request to the server. No client-side request timeout of its own.
    public func ask(_ request: AskRequest) async throws -> AskResponse {
        let endpoint = try loadEndpoint()
        guard let url = URL(string: "http://127.0.0.1:\(endpoint.port)/ask") else {
            throw AskClientError.notRunning
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        urlRequest.httpBody = try encoder.encode(request)

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 86400 * 365
        config.timeoutIntervalForResource = 86400 * 365
        let session = URLSession(configuration: config)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw AskClientError.notRunning
        }

        guard let http = response as? HTTPURLResponse else {
            throw AskClientError.invalidResponse
        }

        if http.statusCode == 200 {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let askResponse = try? decoder.decode(AskResponse.self, from: data) else {
                throw AskClientError.invalidResponse
            }
            return askResponse
        } else if http.statusCode == 400 {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "Bad Request"
            throw AskClientError.badRequest(msg)
        } else if http.statusCode == 401 {
            throw AskClientError.serverError(statusCode: 401, message: "Unauthorized")
        } else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "Server Error"
            throw AskClientError.serverError(statusCode: http.statusCode, message: msg)
        }
    }

    private func loadEndpoint() throws -> AskEndpoint {
        guard FileManager.default.fileExists(atPath: endpointURL.path) else {
            throw AskClientError.notRunning
        }
        guard let data = try? Data(contentsOf: endpointURL),
              let endpoint = try? JSONDecoder().decode(AskEndpoint.self, from: data) else {
            throw AskClientError.notRunning
        }
        guard isProcessAlive(pid: endpoint.pid) else {
            throw AskClientError.notRunning
        }
        return endpoint
    }

    private func isProcessAlive(pid: Int32) -> Bool {
        if pid <= 0 { return false }
        let ret = kill(pid, 0)
        if ret == 0 { return true }
        return errno == EPERM
    }
}
