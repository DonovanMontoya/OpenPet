import Foundation

actor OpenCodeSessionPoller {
    private struct SessionCursor {
        var fileURL: URL?
        var sessionID: String?
        var lastModifiedAt: Date?
        var parser = OpenCodeExportParser()
        var didSkipInitialExport = false
    }

    private let executablePath: String
    private let storageDirectory: URL
    private let fileManager: FileManager
    private var cursor = SessionCursor()

    init(
        executablePath: String,
        storageDirectory: URL = URL(filePath: NSHomeDirectory())
            .appending(path: ".local", directoryHint: .isDirectory)
            .appending(path: "share", directoryHint: .isDirectory)
            .appending(path: "opencode", directoryHint: .isDirectory)
            .appending(path: "storage", directoryHint: .isDirectory)
            .appending(path: "session", directoryHint: .isDirectory),
        fileManager: FileManager = .default
    ) {
        self.executablePath = executablePath
        self.storageDirectory = storageDirectory
        self.fileManager = fileManager
    }

    func poll(source: String) throws -> [CompanionEvent] {
        guard let latestFile = try latestSessionFile() else {
            return []
        }

        let values = try latestFile.resourceValues(forKeys: [.contentModificationDateKey])
        let modifiedAt = values.contentModificationDate ?? .distantPast
        let sessionID = latestFile.deletingPathExtension().lastPathComponent

        if cursor.fileURL != latestFile || cursor.sessionID != sessionID {
            cursor = SessionCursor(fileURL: latestFile, sessionID: sessionID, lastModifiedAt: nil, parser: OpenCodeExportParser())
        }

        guard cursor.lastModifiedAt != modifiedAt else {
            return []
        }

        cursor.lastModifiedAt = modifiedAt
        if !cursor.didSkipInitialExport {
            cursor.didSkipInitialExport = true
            return []
        }

        let exportText = try exportSession(sessionID: sessionID)
        return cursor.parser.parse(exportText: exportText, source: source)
    }

    private func latestSessionFile() throws -> URL? {
        guard fileManager.fileExists(atPath: storageDirectory.path()),
              let enumerator = fileManager.enumerator(
                at: storageDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true, fileURL.lastPathComponent.hasPrefix("ses_"), fileURL.pathExtension == "json" {
                files.append(fileURL)
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
