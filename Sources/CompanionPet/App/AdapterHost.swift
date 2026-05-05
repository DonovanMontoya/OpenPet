import Foundation

@MainActor
final class AdapterHost {
    private let channel = EventChannel<CompanionEvent>()
    private var adapters: [String: any CompanionAdapter] = [:]
    private var readTasks: [String: Task<Void, Never>] = [:]

    func events() -> AsyncStream<CompanionEvent> {
        channel.stream()
    }

    func install(_ newAdapters: [any CompanionAdapter]) async {
        await stopAll()

        adapters = Dictionary(uniqueKeysWithValues: newAdapters.map { ($0.id, $0) })
        for adapter in newAdapters {
            readTasks[adapter.id] = Task { [channel] in
                let stream = adapter.events()
                for await event in stream {
                    channel.send(event)
                }
            }
            await adapter.start()
        }
    }

    func stopAll() async {
        for task in readTasks.values {
            task.cancel()
        }
        readTasks.removeAll()

        for adapter in adapters.values {
            await adapter.stop()
        }
        adapters.removeAll()
    }

    func healthSnapshot() async -> [String: AdapterHealth] {
        var snapshot: [String: AdapterHealth] = [:]
        for (id, adapter) in adapters {
            snapshot[id] = await adapter.health()
        }
        return snapshot
    }
}
