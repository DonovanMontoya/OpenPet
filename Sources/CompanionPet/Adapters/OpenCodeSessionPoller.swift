import Foundation

actor OpenCodeSessionPoller {
    private struct SessionCursor {
        var fileURL: URL?
        var sessionID: String?
        var lastModifiedAt: Date?
        var parser = OpenCodeExportParser()
        var didSeedInitialExport = false
    }

    private let executablePath: String
    private let storageDirectories: [URL]
    private let fileManager: FileManager
    private var cursor = SessionCursor()

    private static func defaultStorageDirectories() -> [URL] {
        let base = URL(filePath: NSHomeDirectory())
            .appending(path: ".local", directoryHint: .isDirectory)
            .appending(path: "share", directoryHint: .isDirectory)
            .appending(path: "opencode", directoryHint: .isDirectory)
            .appending(path: "storage", directoryHint: .isDirectory)
        return [
            base.appending(path: "session_diff", directoryHint: .isDirectory),
            base.appending(path: "session", directoryHint: .isDirectory),
        ]
    }

    init(
        executablePath: String,
        storageDirectories: [URL] = OpenCodeSessionPoller.defaultStorageDirectories(),
        fileManager: FileManager = .default
    ) {
        self.executablePath = executablePath
        self.storageDirectories = storageDirectories
        self.fileManager = fileManager
    }

    struct PollResult {
        var events: [CompanionEvent]
        var sessionID: String?
    }

    func poll(source: String) throws -> PollResult {
        guard let latestFile = try latestSessionFile() else {
            return PollResult(events: [], sessionID: nil)
        }

        let values = try latestFile.resourceValues(forKeys: [.contentModificationDateKey])
        let modifiedAt = values.contentModificationDate ?? .distantPast
        let sessionID = latestFile.deletingPathExtension().lastPathComponent

        let isInitialSession = cursor.fileURL == nil
        if cursor.fileURL != latestFile || cursor.sessionID != sessionID {
            cursor = SessionCursor(
                fileURL: latestFile,
                sessionID: sessionID,
                lastModifiedAt: nil,
                parser: OpenCodeExportParser(),
                didSeedInitialExport: !isInitialSession
            )
        }

        guard cursor.lastModifiedAt != modifiedAt else {
            return PollResult(events: [], sessionID: sessionID)
        }

        cursor.lastModifiedAt = modifiedAt
        let exportText = try exportSession(sessionID: sessionID)
        let events = cursor.parser.parse(exportText: exportText, source: source)

        if !cursor.didSeedInitialExport {
            cursor.didSeedInitialExport = true
            return PollResult(events: [], sessionID: sessionID)
        }

        return PollResult(events: events, sessionID: sessionID)
    }

    private func latestSessionFile() throws -> URL? {
        var files: [URL] = []

        for directory in storageDirectories {
            guard fileManager.fileExists(atPath: directory.path()),
                  let enumerator = fileManager.enumerator(
                    at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                  ) else {
                continue
            }
            for case let fileURL as URL in enumerator {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                if values.isRegularFile == true, fileURL.lastPathComponent.hasPrefix("ses_"), fileURL.pathExtension == "json" {
                    files.append(fileURL)
                }
            }
        }

        return try files.max(by: { lhs, rhs in
            let lhsDate = try lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let rhsDate = try rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            return lhsDate < rhsDate
        })
    }

    private func exportSession(sessionID: String) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: executablePath)
        process.arguments = ["export", sessionID, "--pure"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errorOutput = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "OpenPet.OpenCodeExport",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errorOutput.isEmpty ? "OpenCode export failed." : errorOutput]
            )
        }

        return output
    }
}
