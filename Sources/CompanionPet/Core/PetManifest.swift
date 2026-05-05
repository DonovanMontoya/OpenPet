import Foundation

struct PetAnchor: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
}

enum PetFrameSourceKind: String, Codable, Sendable {
    case symbol
    case file
}

struct PetFrame: Codable, Equatable, Sendable {
    var kind: PetFrameSourceKind
    var value: String
    var tintHex: String?
    var backgroundHex: String?
}

enum PetTransitionHint: String, Codable, Sendable {
    case holdLast
    case loop
    case returnToIdle
}

struct PetState: Codable, Equatable, Sendable {
    var name: CompanionStateName
    var frames: [PetFrame]
    var durationsMs: [Int]
    var loop: Bool
    var transitionOut: PetTransitionHint?

    func validationErrors() -> [String] {
        var errors: [String] = []
        if frames.isEmpty {
            errors.append("State \(name.rawValue) must include at least one frame.")
        }
        if frames.count != durationsMs.count {
            errors.append("State \(name.rawValue) frames and durations must have equal counts.")
        }
        if durationsMs.contains(where: { $0 <= 0 }) {
            errors.append("State \(name.rawValue) durations must be positive.")
        }
        return errors
    }
}

struct PetManifest: Codable, Equatable, Sendable {
    var id: String
    var displayName: String
    var description: String
    var defaultScale: Double
    var anchor: PetAnchor
    var states: [PetState]

    func state(named name: CompanionStateName) -> PetState? {
        states.first(where: { $0.name == name })
    }

    func resolvedState(named name: CompanionStateName) -> PetState? {
        state(named: name) ?? state(named: .idle)
    }

    func validationErrors() -> [String] {
        var errors: [String] = []

        if id.isEmpty {
            errors.append("Manifest id must not be empty.")
        }
        if displayName.isEmpty {
            errors.append("Manifest displayName must not be empty.")
        }
        if defaultScale <= 0 {
            errors.append("Manifest defaultScale must be greater than zero.")
        }
        if state(named: .idle) == nil {
            errors.append("Manifest must define an idle state.")
        }

        let names = states.map(\.name)
        if Set(names).count != names.count {
            errors.append("Manifest contains duplicate state definitions.")
        }

        for state in states {
            errors.append(contentsOf: state.validationErrors())
        }

        return errors
    }
}

enum PetPackSource: String, Sendable {
    case builtIn
    case custom
    case codex
}

struct PetPack: Identifiable, Equatable, Sendable {
    var id: String { manifest.id }
    var manifest: PetManifest
    var directoryURL: URL?
    var source: PetPackSource

    func resolvedFrameURL(for frame: PetFrame) -> URL? {
        guard frame.kind == .file else {
            return nil
        }
        guard let directoryURL else {
            return nil
        }
        return directoryURL.appending(path: frame.value)
    }
}

enum PetLibraryError: Error, LocalizedError {
    case missingBuiltInManifest
    case invalidManifest(String)

    var errorDescription: String? {
        switch self {
        case .missingBuiltInManifest:
            return "The built-in default pet manifest could not be found."
        case .invalidManifest(let message):
            return message
        }
    }
}
