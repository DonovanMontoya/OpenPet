import Foundation

actor ClaudeCodeSessionPoller {
    private struct SessionCursor {
        var fileURL: URL?
        var offset: UInt64 = 0
        var parser = ClaudeCodeJSONLParser()
    }

    private let rootDirectory: URL
    private let fileManager: FileManager
    private var cursor = SessionCursor()

    init(
        rootDirectory: URL = URL(filePath: NSHomeDirectory())
            .appending(path: ".claude", directoryHint: .isDirectory)
            .appending(path: "projects", directoryHint: .isDirectory),
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    func poll(source: String) throws -> [CompanionEvent] {
        guard fileManager.fileExists(atPath: rootDirectory.path()) else {
            return []
        }

        let sessionFiles = try jsonlFiles(in: rootDirectory)
        guard let latestFile = try sessionFiles.max(by: { lhs, rhs in
            let lhsDate = try lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let rhsDate = try rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            return lhsDate < rhsDate
        }) else {
            return []
        }

        if cursor.fileURL != latestFile {
            cursor = SessionCursor(
                fileURL: latestFile,
                offset: initialSessionOffset(for: latestFile, previousFileURL: cursor.fileURL),
                parser: ClaudeCodeJSONLParser(sessionID: latestFile.deletingPathExtension().lastPathComponent)
            )
        }

        let handle = try FileHandle(forReadingFrom: latestFile)
        defer { try? handle.close() }
        try handle.seek(toOffset: cursor.offset)
        let data = try handle.readToEnd() ?? Data()
        cursor.offset += UInt64(data.count)

        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            return []
        }

        var events: [CompanionEvent] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            events.append(contentsOf: cursor.parser.parse(line: String(rawLine), source: source))
        }
        return events
    }

    private func jsonlFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true, fileURL.pathExtension == "jsonl" {
                files.append(fileURL)
            }
        }
        return files
    }

    private func initialSessionOffset(for fileURL: URL, previousFileURL: URL?) -> UInt64 {
        guard previousFileURL == nil,
              let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return 0
        }
        return UInt64(max(0, size))
    }
}
