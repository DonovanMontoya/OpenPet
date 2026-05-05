import Foundation
import Testing
@testable import CompanionPet

struct LMStudioProxyTests {
    @Test
    func forwardsStreamingChatRequestsAndEmitsLifecycleEvents() async throws {
        let upstreamPort = Int.random(in: 28000...29000)
        let proxyPort = upstreamPort + 1

        let upstreamServer = SimpleHTTPServer(host: "127.0.0.1", port: upstreamPort) { request in
            if request.target == "/v1/models" {
                return HTTPResponse(
                    statusCode: 200,
                    headers: ["content-type": "application/json"],
                    body: Data(#"{"data":[]}"#.utf8)
                )
            }

            return HTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/event-stream"],
                body: Data("data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\ndata: [DONE]\n\n".utf8)
            )
        }
        try upstreamServer.start()
        defer { upstreamServer.stop() }

        let adapter = LMStudioProxyAdapter(
            settings: LMStudioAdapterSettings(
                enabled: true,
                upstreamBaseURL: "http://127.0.0.1:\(upstreamPort)",
                listenHost: "127.0.0.1",
                listenPort: proxyPort,
                displayName: "LM Studio"
            )
        )

        let eventStream = adapter.events()
        let eventTask = Task<[CompanionEvent], Never> {
            var events: [CompanionEvent] = []
            for await event in eventStream {
                events.append(event)
                if event.kind == .sessionEnded {
                    break
                }
            }
            return events
        }

        await adapter.start()
        defer {
            Task {
                await adapter.stop()
            }
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"stream":true,"messages":[{"role":"user","content":"hi"}]}"#.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("[DONE]"))

        let events = await eventTask.value
        let kinds = events.map(\.kind)
        #expect(kinds.contains(.sessionStarted))
        #expect(kinds.contains(.thinkingStarted))
        #expect(kinds.contains(.streamStarted))
        #expect(kinds.contains(.streamDelta))
        #expect(kinds.contains(.streamFinished))
        #expect(kinds.contains(.sessionEnded))
        #expect(events.first(where: { $0.kind == .thinkingStarted })?.payload["text"] == "hi")
        #expect(events.first(where: { $0.kind == .streamDelta })?.payload["text"] == "hello")
    }
}
