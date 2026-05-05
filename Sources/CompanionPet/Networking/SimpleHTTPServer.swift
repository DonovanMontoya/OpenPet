import Foundation
import Network

final class SimpleHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let host: String
    private let port: Int
    private let handler: Handler
    private let queue = DispatchQueue(label: "CompanionPet.SimpleHTTPServer")
    private var listener: NWListener?

    init(host: String, port: Int, handler: @escaping Handler) {
        self.host = host
        self.port = port
        self.handler = handler
    }

    func start() throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw HTTPServerError.listenerUnavailable
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: endpointPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(on: connection, buffer: Data())
    }

    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                self.send(response: HTTPResponse.json(statusCode: 500, payload: ["error": error.localizedDescription]), on: connection)
                return
            }

            let combined = buffer + (data ?? Data())
            do {
                if let request = try self.parseRequest(from: combined) {
                    Task {
                        let response = await self.handler(request)
                        self.send(response: response, on: connection)
                    }
                    return
                }

                if isComplete {
                    self.send(response: HTTPResponse.json(statusCode: 400, payload: ["error": "Incomplete request"]), on: connection)
                    return
                }

                self.readRequest(on: connection, buffer: combined)
            } catch {
                self.send(response: HTTPResponse.json(statusCode: 400, payload: ["error": error.localizedDescription]), on: connection)
            }
        }
    }

    private func parseRequest(from buffer: Data) throws -> HTTPRequest? {
        let delimiter = Data([13, 10, 13, 10])
        guard let headerRange = buffer.range(of: delimiter) else {
            return nil
        }

        let headerData = buffer[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw HTTPServerError.invalidRequestEncoding
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw HTTPServerError.invalidRequestLine
        }

        let requestComponents = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestComponents.count == 3 else {
            throw HTTPServerError.invalidRequestLine
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else {
                continue
            }
            headers[String(pieces[0]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] =
                String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let bodyOffset = headerRange.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let totalLength = bodyOffset + contentLength
        guard buffer.count >= totalLength else {
            return nil
        }

        let body = Data(buffer[bodyOffset..<totalLength])
        return HTTPRequest(
            method: String(requestComponents[0]),
            target: String(requestComponents[1]),
            version: String(requestComponents[2]),
            headers: headers,
            body: body
        )
    }

    private func send(response: HTTPResponse, on connection: NWConnection) {
        Task {
            do {
                var headers = response.headers
                headers["connection"] = "close"
                if response.streamingBody == nil {
                    headers["content-length"] = "\(response.body?.count ?? 0)"
                } else {
                    headers.removeValue(forKey: "content-length")
                    headers.removeValue(forKey: "transfer-encoding")
                }

                var head = "HTTP/1.1 \(response.statusCode) \(HTTPStatus.reasonPhrase(for: response.statusCode))\r\n"
                for (key, value) in headers {
                    head += "\(key): \(value)\r\n"
                }
                head += "\r\n"

                try await send(data: Data(head.utf8), on: connection)

                if let body = response.body, !body.isEmpty {
                    try await send(data: body, on: connection)
                }

                if let streamingBody = response.streamingBody {
                    for await chunk in streamingBody {
                        try await send(data: chunk, on: connection)
                    }
                }

                connection.cancel()
            } catch {
                connection.cancel()
            }
        }
    }

    private func send(data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }
}
