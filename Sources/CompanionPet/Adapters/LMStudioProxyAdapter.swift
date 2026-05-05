import Foundation

private enum LMStudioProxyError: Error, LocalizedError {
    case invalidUpstreamURL
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidUpstreamURL:
            return "The LM Studio upstream URL is invalid."
        case .invalidResponse:
            return "The upstream did not return a valid HTTP response."
        }
    }
}

final class LMStudioProxyAdapter: CompanionAdapter, @unchecked Sendable {
    let id = "lmstudio-proxy"
    let displayName: String
    let capabilities: Set<AdapterCapability> = [.proxiesRequests, .healthChecks]

    private let settings: LMStudioAdapterSettings
    private let channel = EventChannel<CompanionEvent>()
    private let healthStore = AdapterHealthStore(AdapterHealth.disconnected)
    private let session: URLSession
    private var server: SimpleHTTPServer?
    private var healthCheckTask: Task<Void, Never>?
    private var hasStopped = false

    init(settings: LMStudioAdapterSettings, session: URLSession = .shared) {
        self.settings = settings
        self.displayName = settings.displayName
        self.session = session
    }

    func health() async -> AdapterHealth {
        await healthStore.get()
    }

    func events() -> AsyncStream<CompanionEvent> {
        channel.stream()
    }

    func start() async {
        let server = SimpleHTTPServer(host: settings.listenHost, port: settings.listenPort) { [weak self] request in
            guard let self else {
                return HTTPResponse.json(statusCode: 503, payload: ["error": "Proxy unavailable"])
            }
            return await self.forward(request)
        }

        do {
            try server.start()
            self.server = server
            await healthStore.set(.connected)
            channel.send(CompanionEvent(source: id, kind: .adapterConnected, payload: ["message": "LM Studio proxy listening."]))
            healthCheckTask?.cancel()
            healthCheckTask = Task { [weak self] in
                await self?.checkHealth()
            }
        } catch {
            await healthStore.set(AdapterHealth(state: .disconnected, lastErrorText: error.localizedDescription))
            channel.send(
                CompanionEvent(
                    source: id,
                    kind: .adapterDisconnected,
                    payload: ["message": error.localizedDescription]
                )
            )
        }
    }

    func stop() async {
        hasStopped = true
        healthCheckTask?.cancel()
        healthCheckTask = nil
        server?.stop()
        server = nil
        await healthStore.set(AdapterHealth.disconnected)
        channel.finish()
    }

    private func checkHealth() async {
        guard let healthURL = URL(string: settings.upstreamBaseURL)?.appending(path: "v1/models") else {
            await healthStore.set(AdapterHealth(state: .degraded, lastErrorText: LMStudioProxyError.invalidUpstreamURL.localizedDescription))
            return
        }

        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 3
        request.httpMethod = "GET"

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...499).contains(httpResponse.statusCode) else {
                throw LMStudioProxyError.invalidResponse
            }
            guard !Task.isCancelled, !hasStopped else {
                return
            }
            await healthStore.set(AdapterHealth.connected)
        } catch {
            guard !Task.isCancelled, !hasStopped else {
                return
            }
            await healthStore.set(AdapterHealth(state: .disconnected, lastErrorText: error.localizedDescription))
            channel.send(
                CompanionEvent(
                    source: id,
                    kind: .adapterDisconnected,
                    payload: ["message": error.localizedDescription]
                )
            )
        }
    }

    private func forward(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = UUID().uuidString
        let requestStartedAt = Date.now
        let promptSummary = requestPromptSummary(from: request.body)

        channel.send(CompanionEvent(source: id, kind: .sessionStarted, timestamp: requestStartedAt, sessionId: sessionID))
        channel.send(
            CompanionEvent(
                source: id,
                kind: .thinkingStarted,
                timestamp: requestStartedAt,
                sessionId: sessionID,
                payload: promptSummary.map { ["text": $0] } ?? [:]
            )
        )

        do {
            let upstreamRequest = try makeUpstreamRequest(from: request)

            if isStreamingRequest(request) {
                let (bytes, response) = try await session.bytes(for: upstreamRequest)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw LMStudioProxyError.invalidResponse
                }

                await healthStore.set(AdapterHealth.connected)
                channel.send(CompanionEvent(source: id, kind: .adapterConnected, sessionId: sessionID))
                channel.send(CompanionEvent(source: id, kind: .streamStarted, sessionId: sessionID))

                let headers = responseHeaders(for: httpResponse, streaming: true)
                let stream = AsyncStream<Data> { continuation in
                    Task {
                        var buffer = Data()

                        do {
                            for try await byte in bytes {
                                buffer.append(byte)
                                if buffer.count >= 512 || byte == 0x0A {
                                    let chunk = buffer
                                    buffer.removeAll(keepingCapacity: true)
                                    continuation.yield(chunk)
                                    let text = self.responseText(fromStreamingChunk: chunk)
                                    self.channel.send(
                                        CompanionEvent(
                                            source: self.id,
                                            kind: .streamDelta,
                                            sessionId: sessionID,
                                            payload: self.streamPayload(bytes: chunk.count, text: text)
                                        )
                                    )
                                }
                            }

                            if !buffer.isEmpty {
                                let chunk = buffer
                                continuation.yield(chunk)
                                let text = self.responseText(fromStreamingChunk: chunk)
                                self.channel.send(
                                    CompanionEvent(
                                        source: self.id,
                                        kind: .streamDelta,
                                        sessionId: sessionID,
                                        payload: self.streamPayload(bytes: chunk.count, text: text)
                                    )
                                )
                            }

                            continuation.finish()
                            self.channel.send(CompanionEvent(source: self.id, kind: .streamFinished, sessionId: sessionID))
                            self.channel.send(CompanionEvent(source: self.id, kind: .sessionEnded, sessionId: sessionID))
                        } catch {
                            continuation.finish()
                            await self.handleForwardingError(error, sessionID: sessionID)
                        }
                    }
                }

                return HTTPResponse(statusCode: httpResponse.statusCode, headers: headers, streamingBody: stream)
            }

            let (data, response) = try await session.data(for: upstreamRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw LMStudioProxyError.invalidResponse
            }

            await healthStore.set(AdapterHealth.connected)
            channel.send(CompanionEvent(source: id, kind: .adapterConnected, sessionId: sessionID))
            channel.send(CompanionEvent(source: id, kind: .streamStarted, sessionId: sessionID))
            if !data.isEmpty {
                let text = responseText(fromJSONData: data)
                channel.send(
                    CompanionEvent(
                        source: id,
                        kind: .streamDelta,
                        sessionId: sessionID,
                        payload: streamPayload(bytes: data.count, text: text)
                    )
                )
            }
            channel.send(CompanionEvent(source: id, kind: .streamFinished, sessionId: sessionID))
            channel.send(CompanionEvent(source: id, kind: .sessionEnded, sessionId: sessionID))

            return HTTPResponse(statusCode: httpResponse.statusCode, headers: responseHeaders(for: httpResponse, streaming: false), body: data)
        } catch {
            await handleForwardingError(error, sessionID: sessionID)
            return HTTPResponse.json(statusCode: 502, payload: ["error": error.localizedDescription])
        }
    }

    private func handleForwardingError(_ error: Error, sessionID: String) async {
        guard !hasStopped else {
            return
        }

        await healthStore.set(AdapterHealth(state: .disconnected, lastErrorText: error.localizedDescription))
        channel.send(
            CompanionEvent(
                source: id,
                kind: .adapterDisconnected,
                sessionId: sessionID,
                payload: ["message": error.localizedDescription]
            )
        )
        channel.send(
            CompanionEvent(
                source: id,
                kind: .error,
                sessionId: sessionID,
                payload: ["message": error.localizedDescription]
            )
        )
    }

    private func makeUpstreamRequest(from request: HTTPRequest) throws -> URLRequest {
        guard let baseURL = URL(string: settings.upstreamBaseURL) else {
            throw LMStudioProxyError.invalidUpstreamURL
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let targetComponents = URLComponents(string: request.target)
        components?.path = targetComponents?.path.isEmpty == false ? targetComponents?.path ?? "/" : request.target
        components?.query = targetComponents?.query

        guard let url = components?.url else {
            throw LMStudioProxyError.invalidUpstreamURL
        }

        var upstreamRequest = URLRequest(url: url)
        upstreamRequest.httpMethod = request.method
        if !request.body.isEmpty {
            upstreamRequest.httpBody = request.body
        }
        for (key, value) in request.headers {
            switch key.lowercased() {
            case "host", "content-length", "connection":
                continue
            default:
                upstreamRequest.setValue(value, forHTTPHeaderField: key)
            }
        }
        return upstreamRequest
    }

    private func isStreamingRequest(_ request: HTTPRequest) -> Bool {
        if request.headerValue(for: "accept")?.localizedCaseInsensitiveContains("text/event-stream") == true {
            return true
        }

        guard !request.body.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return false
        }

        return (json["stream"] as? Bool) == true
    }

    private func responseHeaders(for response: HTTPURLResponse, streaming: Bool) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, let value = value as? String else {
                continue
            }
            let normalizedKey = key.lowercased()
            if streaming && (normalizedKey == "content-length" || normalizedKey == "transfer-encoding") {
                continue
            }
            headers[normalizedKey] = value
        }
        return headers
    }

    private func streamPayload(bytes: Int, text: String?) -> [String: String] {
        var payload = ["bytes": "\(bytes)"]
        if let text, !text.isEmpty {
            payload["text"] = text
        }
        return payload
    }

    private func requestPromptSummary(from data: Data) -> String? {
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let prompt = json["prompt"] as? String {
            return prompt
        }

        guard let messages = json["messages"] as? [[String: Any]] else {
            return nil
        }

        return messages.reversed().compactMap { message -> String? in
            guard (message["role"] as? String) == "user" else {
                return nil
            }
            return extractedText(from: message["content"])
        }.first
    }

    private func responseText(fromStreamingChunk data: Data) -> String? {
        guard let raw = String(data: data, encoding: .utf8) else {
            return nil
        }

        let fragments = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("data:") else {
                    return nil
                }
                let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard payload != "[DONE]", let data = payload.data(using: .utf8) else {
                    return nil
                }
                return responseText(fromJSONData: data)
            }

        let text = fragments.filter { !$0.isEmpty }.joined()
        return text.isEmpty ? nil : text
    }

    private func responseText(fromJSONData data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return responseText(fromJSONObject: json)
    }

    private func responseText(fromJSONObject json: Any) -> String? {
        guard let dictionary = json as? [String: Any] else {
            return extractedText(from: json)
        }

        if let choices = dictionary["choices"] as? [[String: Any]] {
            let text = choices.compactMap { choice -> String? in
                if let delta = choice["delta"] {
                    return extractedText(from: delta)
                }
                if let message = choice["message"] {
                    return extractedText(from: message)
                }
                return extractedText(from: choice["text"])
            }.joined()
            if !text.isEmpty {
                return text
            }
        }

        return extractedText(from: dictionary)
    }

    private func extractedText(from value: Any?) -> String? {
        switch value {
        case let text as String:
            return text
        case let dictionary as [String: Any]:
            for key in ["content", "text", "message", "delta", "output"] {
                if let text = extractedText(from: dictionary[key]), !text.isEmpty {
                    return text
                }
            }
            return nil
        case let array as [Any]:
            let text = array.compactMap { extractedText(from: $0) }.filter { !$0.isEmpty }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        default:
            return nil
        }
    }
}
