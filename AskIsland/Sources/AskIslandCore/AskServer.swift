import Foundation
import Network
import os

private final class AtomicBool: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var _val: Bool
    init(_ val: Bool) { self._val = val }
    func get() -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _val
    }
    func set(_ val: Bool) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        _val = val
    }
}

public enum AskServerError: Error, LocalizedError {
    case cryptoFailed
    case portUnavailable
    case failedToStart(String)

    public var errorDescription: String? {
        switch self {
        case .cryptoFailed:
            return "Failed to generate random cryptographic token."
        case .portUnavailable:
            return "Unable to determine server port."
        case .failedToStart(let msg):
            return "Server failed to start: \(msg)"
        }
    }
}

/// HTTP/1.1 server on 127.0.0.1 only (Network.framework), port 0 (random) unless ASK_ISLAND_PORT.
public final class AskServer: @unchecked Sendable {
    public let store: AskStore
    public let endpointURL: URL

    private var listener: NWListener?
    private var currentToken: String?
    private let queue = DispatchQueue(label: "com.askisland.server", qos: .userInitiated)

    private let lock = NSLock()
    private var activeConnections: [NWConnection] = []

    public init(store: AskStore, endpointURL: URL = AskEndpoint.resolvedURL) {
        self.store = store
        self.endpointURL = endpointURL
    }

    /// Starts the server and writes the endpoint file (dir 0700, file 0600).
    public func start() throws -> AskEndpoint {
        let requestedPort: UInt16
        if let envPort = ProcessInfo.processInfo.environment["ASK_ISLAND_PORT"],
           let p = UInt16(envPort), p > 0 {
            requestedPort = p
        } else {
            requestedPort = 0
        }

        let params = NWParameters.tcp
        let portEndpoint: NWEndpoint.Port = requestedPort > 0 ? (NWEndpoint.Port(rawValue: requestedPort) ?? .any) : .any
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: portEndpoint)

        let listener = try NWListener(using: params)

        // Random 32-hex token
        var randomBytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        guard status == errSecSuccess else {
            throw AskServerError.cryptoFailed
        }
        let token = randomBytes.map { String(format: "%02x", $0) }.joined()
        self.currentToken = token

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var startError: Error?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                semaphore.signal()
            case .failed(let error):
                startError = error
                semaphore.signal()
            case .cancelled:
                semaphore.signal()
            default:
                break
            }
        }

        listener.start(queue: queue)
        semaphore.wait()

        if let error = startError {
            listener.cancel()
            throw AskServerError.failedToStart(error.localizedDescription)
        }

        guard let actualPort = listener.port?.rawValue else {
            listener.cancel()
            throw AskServerError.portUnavailable
        }

        self.listener = listener

        let pid = ProcessInfo.processInfo.processIdentifier
        let endpoint = AskEndpoint(port: actualPort, token: token, pid: pid)

        // Write endpoint file with dir 0700, file 0600
        let dirURL = endpointURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(endpoint)

        FileManager.default.createFile(atPath: endpointURL.path, contents: data, attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: endpointURL.path)

        return endpoint
    }

    /// Stops the server and removes the endpoint file if it holds this pid.
    public func stop() {
        listener?.cancel()
        listener = nil

        lock.lock()
        let conns = activeConnections
        activeConnections.removeAll()
        lock.unlock()

        for conn in conns {
            conn.cancel()
        }

        if FileManager.default.fileExists(atPath: endpointURL.path) {
            if let data = try? Data(contentsOf: endpointURL),
               let ep = try? JSONDecoder().decode(AskEndpoint.self, from: data),
               ep.pid == ProcessInfo.processInfo.processIdentifier {
                try? FileManager.default.removeItem(at: endpointURL)
            }
        }
    }

    private func trackConnection(_ conn: NWConnection) {
        lock.lock()
        activeConnections.append(conn)
        lock.unlock()
    }

    private func untrackConnection(_ conn: NWConnection) {
        lock.lock()
        activeConnections.removeAll { $0 === conn }
        lock.unlock()
    }

    private func handleNewConnection(_ connection: NWConnection) {
        trackConnection(connection)
        connection.start(queue: queue)
        readRequest(connection: connection, buffer: Data())
    }

    private func readRequest(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if error != nil {
                self.untrackConnection(connection)
                connection.cancel()
                return
            }

            var currentBuffer = buffer
            if let data = content, !data.isEmpty {
                currentBuffer.append(data)
            }

            if currentBuffer.count > 1024 * 1024 + 16384 {
                // Total request too large (> 1MB body)
                self.sendResponse(connection: connection, statusCode: 400, body: #"{"error": "Payload too large"}"#)
                return
            }

            // Look for header terminator \r\n\r\n or \n\n
            let delimCRLF = "\r\n\r\n".data(using: .utf8)!
            let delimLF = "\n\n".data(using: .utf8)!

            var headerEndRange: Range<Data.Index>? = currentBuffer.range(of: delimCRLF)
            var delimLength = 4
            if headerEndRange == nil {
                headerEndRange = currentBuffer.range(of: delimLF)
                delimLength = 2
            }

            guard let foundRange = headerEndRange else {
                if isComplete {
                    self.untrackConnection(connection)
                    connection.cancel()
                } else {
                    self.readRequest(connection: connection, buffer: currentBuffer)
                }
                return
            }

            let headerData = currentBuffer.subdata(in: 0..<foundRange.lowerBound)
            let bodyStartIndex = foundRange.lowerBound + delimLength
            guard let headerStr = String(data: headerData, encoding: .utf8) else {
                self.sendResponse(connection: connection, statusCode: 400, body: #"{"error": "Invalid HTTP headers"}"#)
                return
            }

            let lines = headerStr.components(separatedBy: .newlines).filter { !$0.isEmpty }
            guard let requestLine = lines.first else {
                self.sendResponse(connection: connection, statusCode: 400, body: #"{"error": "Empty request line"}"#)
                return
            }

            let requestParts = requestLine.split(separator: " ")
            guard requestParts.count >= 2 else {
                self.sendResponse(connection: connection, statusCode: 400, body: #"{"error": "Invalid request line"}"#)
                return
            }

            let method = String(requestParts[0]).uppercased()
            let rawPath = String(requestParts[1])
            let path = rawPath.split(separator: "?").first.map(String.init) ?? rawPath

            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                if let colonIndex = line.firstIndex(of: ":") {
                    let key = line[..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
                    headers[key] = value
                }
            }

            let contentLength = Int(headers["content-length"] ?? "0") ?? 0
            if contentLength > 1024 * 1024 {
                self.sendResponse(connection: connection, statusCode: 400, body: #"{"error": "Body exceeds 1 MB"}"#)
                return
            }

            let bodyBytesAvailable = currentBuffer.count - bodyStartIndex
            if bodyBytesAvailable < contentLength {
                if isComplete {
                    self.sendResponse(connection: connection, statusCode: 400, body: #"{"error": "Incomplete request body"}"#)
                } else {
                    self.readRequest(connection: connection, buffer: currentBuffer)
                }
                return
            }

            let bodyData = currentBuffer.subdata(in: bodyStartIndex..<(bodyStartIndex + contentLength))
            self.processRequest(connection: connection, method: method, path: path, headers: headers, bodyData: bodyData)
        }
    }

    private func processRequest(connection: NWConnection, method: String, path: String, headers: [String: String], bodyData: Data) {
        if method == "GET" && path == "/health" {
            sendResponse(connection: connection, statusCode: 200, body: #"{"ok":true}"#)
            return
        }

        if method == "POST" && path == "/ask" {
            // Check auth token
            guard let authHeader = headers["authorization"],
                  let token = currentToken,
                  authHeader == "Bearer \(token)" else {
                sendResponse(connection: connection, statusCode: 401, body: #"{"error": "Unauthorized"}"#)
                return
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard var request = try? decoder.decode(AskRequest.self, from: bodyData) else {
                sendResponse(connection: connection, statusCode: 400, body: #"{"error": "Invalid request JSON"}"#)
                return
            }

            // Empty title is 400 for every kind
            if request.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sendResponse(connection: connection, statusCode: 400, body: #"{"error": "Title cannot be empty"}"#)
                return
            }

            // .question with no questions is 400
            if request.kind == .question && request.questions.isEmpty {
                sendResponse(connection: connection, statusCode: 400, body: #"{"error": "Questions cannot be empty"}"#)
                return
            }

            if request.id.isEmpty {
                request.id = UUID().uuidString
            }
            let requestId = request.id

            let isResolved = AtomicBool(false)

            // Monitor client disconnect while waiting
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, _, _ in
                if !isResolved.get() {
                    Task { @MainActor [weak self] in
                        self?.store.cancel(requestId)
                    }
                }
            }

            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled:
                    if !isResolved.get() {
                        Task { @MainActor [weak self] in
                            self?.store.cancel(requestId)
                        }
                    }
                default:
                    break
                }
            }

            Task {
                let response = await self.store.submit(request)
                isResolved.set(true)

                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                if let responseData = try? encoder.encode(response) {
                    self.sendResponse(connection: connection, statusCode: 200, contentType: "application/json", data: responseData)
                } else {
                    self.sendResponse(connection: connection, statusCode: 500, body: #"{"error": "Failed to encode response"}"#)
                }
            }
            return
        }

        // Other paths 404
        sendResponse(connection: connection, statusCode: 404, body: #"{"error": "Not found"}"#)
    }

    private func sendResponse(connection: NWConnection, statusCode: Int, contentType: String = "application/json", body: String) {
        let data = body.data(using: .utf8) ?? Data()
        sendResponse(connection: connection, statusCode: statusCode, contentType: contentType, data: data)
    }

    private func sendResponse(connection: NWConnection, statusCode: Int, contentType: String = "application/json", data: Data) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "HTTP"
        }

        let header = "HTTP/1.1 \(statusCode) \(statusText)\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        var responseData = header.data(using: .utf8) ?? Data()
        responseData.append(data)

        connection.send(content: responseData, completion: .contentProcessed { [weak self] _ in
            self?.untrackConnection(connection)
            connection.cancel()
        })
    }
}
