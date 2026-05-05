import CoreGraphics
import Foundation

enum OverlayScalePreset: String, Codable, CaseIterable, Sendable {
    static let bubbleWidth: CGFloat = 270
    static let bubbleHeight: CGFloat = 98

    case small
    case medium
    case large

    var petDimension: CGFloat {
        switch self {
        case .small:
            return 112
        case .medium:
            return 156
        case .large:
            return 212
        }
    }

    var petCanvasSize: CGSize {
        let pet = petDimension
        let padding = 12.0
        return CGSize(width: pet + padding, height: pet + padding)
    }

    var bubbleCanvasSize: CGSize {
        CGSize(width: OverlayScalePreset.bubbleWidth + 12, height: OverlayScalePreset.bubbleHeight + 12)
    }

    func canvasSize(showingBubble: Bool) -> CGSize {
        showingBubble ? bubbleCanvasSize : petCanvasSize
    }
}

struct OverlayPlacement: Codable, Equatable, Sendable {
    var screenID: String
    var originX: Double
    var originY: Double
}

struct CodexAdapterSettings: Codable, Equatable, Sendable {
    var enabled: Bool = true
    var executablePath: String = "/opt/homebrew/bin/codex"
    var workingDirectoryPath: String = NSHomeDirectory()
    var preferredModel: String = ""
    var displayName: String = "Codex CLI"
}

struct LMStudioAdapterSettings: Codable, Equatable, Sendable {
    var enabled: Bool = true
    var upstreamBaseURL: String = "http://127.0.0.1:1234"
    var listenHost: String = "127.0.0.1"
    var listenPort: Int = 5050
    var displayName: String = "LM Studio"
}

struct ClaudeCodeAdapterSettings: Codable, Equatable, Sendable {
    var enabled: Bool = true
    var executablePath: String = "/usr/local/bin/claude"
    var workingDirectoryPath: String = NSHomeDirectory()
    var hookListenerPort: Int = 5051
    var autoConfigureHooks: Bool = true
    var displayName: String = "Claude Code"
}

struct OpenCodeAdapterSettings: Codable, Equatable, Sendable {
    var enabled: Bool = true
    var executablePath: String = "/opt/homebrew/bin/opencode"
    var workingDirectoryPath: String = NSHomeDirectory()
    var displayName: String = "OpenCode"
}

struct CompanionSettings: Codable, Equatable, Sendable {
    var isPaused: Bool = false
    var isLocked: Bool = false
    var reducedMotion: Bool = false
    var showsSpeechBubbles: Bool = true
    var selectedPetID: String = BuiltInPet.defaultID
    var overlayScalePreset: OverlayScalePreset = .medium
    var overlayPlacement: OverlayPlacement?
    var codex: CodexAdapterSettings = .init()
    var lmStudio: LMStudioAdapterSettings = .init()
    var claudeCode: ClaudeCodeAdapterSettings = .init()
    var openCode: OpenCodeAdapterSettings = .init()
}

enum AppSupportPaths {
    static let suiteName = "CompanionPet"

    static func applicationSupportDirectory(fileManager: FileManager = .default) throws -> URL {
        let baseURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = baseURL.appending(path: suiteName, directoryHint: .isDirectory)
        if !fileManager.fileExists(atPath: directory.path()) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func customPetsDirectory(fileManager: FileManager = .default) throws -> URL {
        let directory = try applicationSupportDirectory(fileManager: fileManager)
            .appending(path: "Pets", directoryHint: .isDirectory)
        if !fileManager.fileExists(atPath: directory.path()) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func codexPetsDirectory(fileManager: FileManager = .default) throws -> URL {
        let directory = URL(filePath: NSHomeDirectory())
            .appending(path: ".codex", directoryHint: .isDirectory)
            .appending(path: "pets", directoryHint: .isDirectory)
        if !fileManager.fileExists(atPath: directory.path()) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}

final class SettingsStore {
    private let defaults: UserDefaults
    private let key = "companion-settings"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> CompanionSettings {
        guard let data = defaults.data(forKey: key) else {
            return CompanionSettings()
        }

        do {
            return try decoder.decode(CompanionSettings.self, from: data)
        } catch {
            return CompanionSettings()
        }
    }

    func save(_ settings: CompanionSettings) {
        guard let data = try? encoder.encode(settings) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}
