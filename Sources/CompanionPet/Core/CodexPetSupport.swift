import AppKit
import Foundation
import ImageIO

struct CodexPetManifest: Codable, Equatable, Sendable {
    var id: String
    var displayName: String
    var description: String
    var spritesheetPath: String
}

enum CodexPetSupportError: Error, LocalizedError {
    case missingSpritesheet(String)
    case invalidSpritesheetSize(width: Int, height: Int)
    case couldNotReadSpritesheet
    case couldNotWriteFrame(String)

    var errorDescription: String? {
        switch self {
        case .missingSpritesheet(let path):
            return "The Codex pet spritesheet is missing at \(path)."
        case .invalidSpritesheetSize(let width, let height):
            return "The Codex pet spritesheet must be 1536x1872, got \(width)x\(height)."
        case .couldNotReadSpritesheet:
            return "The Codex pet spritesheet could not be decoded."
        case .couldNotWriteFrame(let path):
            return "A frame image could not be written to \(path)."
        }
    }
}

enum CodexPetSupport {
    static let atlasColumns = 8
    static let cellWidth = 192
    static let cellHeight = 208
    static let atlasSize = CGSize(width: atlasColumns * cellWidth, height: 9 * cellHeight)
    static let cacheVersionDirectory = "codex-frames-v3"
    static let defaultScale = 1.0
    static let defaultAnchor = PetAnchor(x: 0.5, y: 0.5)

    private static let rowSpecs: [CodexRowSpec] = [
        .init(name: "idle", row: 0, usedColumns: 6, durationsMs: [350, 140, 140, 175, 175, 400], loop: true, transitionOut: .holdLast),
        .init(name: "running-right", row: 1, usedColumns: 8, durationsMs: [150, 150, 150, 150, 150, 150, 150, 275], loop: true, transitionOut: .holdLast),
        .init(name: "running-left", row: 2, usedColumns: 8, durationsMs: [150, 150, 150, 150, 150, 150, 150, 275], loop: true, transitionOut: .holdLast),
        .init(name: "waving", row: 3, usedColumns: 4, durationsMs: [175, 175, 175, 350], loop: true, transitionOut: .holdLast),
        .init(name: "jumping", row: 4, usedColumns: 5, durationsMs: [175, 175, 175, 175, 350], loop: false, transitionOut: .returnToIdle),
        .init(name: "failed", row: 5, usedColumns: 8, durationsMs: [175, 175, 175, 175, 175, 175, 175, 300], loop: false, transitionOut: .returnToIdle),
        .init(name: "waiting", row: 6, usedColumns: 6, durationsMs: [190, 190, 190, 190, 190, 325], loop: true, transitionOut: .holdLast),
        .init(name: "running", row: 7, usedColumns: 6, durationsMs: [150, 150, 150, 150, 150, 275], loop: true, transitionOut: .holdLast),
        .init(name: "review", row: 8, usedColumns: 6, durationsMs: [190, 190, 190, 190, 190, 350], loop: true, transitionOut: .holdLast),
    ]

    private static let semanticStateMap: [CompanionStateName: String] = [
        .idle: "idle",
        .ambient: "idle",
        .thinking: "review",
        .working: "running",
        .replying: "waving",
        .success: "jumping",
        .error: "failed",
        .waitingForUser: "waiting",
        .disconnected: "idle",
        .sleeping: "waiting",
        .jumping: "jumping",
        .waving: "waving",
    ]

    static func makeManifest(from manifest: CodexPetManifest, in directoryURL: URL) throws -> PetManifest {
        let spritesheetURL = directoryURL.appending(path: manifest.spritesheetPath)
        let extractedFrames = try extractFrames(from: spritesheetURL, in: directoryURL)

        let states = CompanionStateName.allCases.compactMap { semanticState -> PetState? in
            guard let codexStateName = semanticStateMap[semanticState],
                  let codexState = extractedFrames[codexStateName],
                  !codexState.frames.isEmpty
            else {
                return nil
            }

            return PetState(
                name: semanticState,
                frames: codexState.frames,
                durationsMs: codexState.durationsMs,
                loop: codexState.loop,
                transitionOut: codexState.transitionOut
            )
        }

        return PetManifest(
            id: manifest.id,
            displayName: manifest.displayName,
            description: manifest.description,
            defaultScale: defaultScale,
            anchor: defaultAnchor,
            states: states
        )
    }

    private static func extractFrames(from spritesheetURL: URL, in directoryURL: URL) throws -> [String: ExtractedState] {
        guard FileManager.default.fileExists(atPath: spritesheetURL.path()) else {
            throw CodexPetSupportError.missingSpritesheet(spritesheetURL.path())
        }
        guard let imageSource = CGImageSourceCreateWithURL(spritesheetURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            throw CodexPetSupportError.couldNotReadSpritesheet
        }

        guard cgImage.width == Int(atlasSize.width), cgImage.height == Int(atlasSize.height) else {
            throw CodexPetSupportError.invalidSpritesheetSize(width: cgImage.width, height: cgImage.height)
        }

        let cacheDirectory = directoryURL
            .appending(path: ".openpet-cache", directoryHint: .isDirectory)
            .appending(path: cacheVersionDirectory, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        var states: [String: ExtractedState] = [:]
        for spec in rowSpecs {
            let stateDirectory = cacheDirectory.appending(path: spec.name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

            let columnIndices = Array(0..<min(spec.usedColumns, atlasColumns))
            let fallbackFrame = firstVisibleFrame(for: spec, in: cgImage)
            var previousVisibleFrame: CGImage?
            var frames: [PetFrame] = []

            for column in columnIndices {
                guard let croppedFrame = croppedFrameImage(from: cgImage, row: spec.row, column: column) else {
                    throw CodexPetSupportError.couldNotReadSpritesheet
                }

                let frameImage: CGImage
                if frameContainsVisiblePixels(croppedFrame) {
                    frameImage = croppedFrame
                    previousVisibleFrame = croppedFrame
                } else if let previousVisibleFrame {
                    frameImage = previousVisibleFrame
                } else if let fallbackFrame {
                    frameImage = fallbackFrame
                } else {
                    continue
                }

                let frameURL = stateDirectory.appending(path: "\(column).png")
                if cachedFrameNeedsWrite(at: frameURL) {
                    try writePNG(frameImage, to: frameURL)
                }

                let relativePath = ".openpet-cache/\(cacheVersionDirectory)/\(spec.name)/\(column).png"
                frames.append(PetFrame(kind: .file, value: relativePath, tintHex: nil, backgroundHex: nil))
            }

            let durations = adjustedDurations(spec.durationsMs, usedColumns: frames.count)
            states[spec.name] = ExtractedState(
                frames: frames,
                durationsMs: durations,
                loop: spec.loop,
                transitionOut: spec.transitionOut
            )
        }

        return states
    }

    private static func firstVisibleFrame(for spec: CodexRowSpec, in spritesheet: CGImage) -> CGImage? {
        for column in 0..<min(spec.usedColumns, atlasColumns) {
            guard let frameImage = croppedFrameImage(from: spritesheet, row: spec.row, column: column),
                  frameContainsVisiblePixels(frameImage) else {
                continue
            }
            return frameImage
        }
        return nil
    }

    private static func cachedFrameNeedsWrite(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path()) else {
            return true
        }
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return true
        }
        return !frameContainsVisiblePixels(image)
    }

    private static func croppedFrameImage(from spritesheet: CGImage, row: Int, column: Int) -> CGImage? {
        let cropRect = CGRect(
            x: column * cellWidth,
            y: row * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
        return spritesheet.cropping(to: cropRect)
    }

    private static func frameContainsVisiblePixels(_ image: CGImage) -> Bool {
        guard let dataProvider = image.dataProvider,
              let data = dataProvider.data else {
            return true
        }

        let length = CFDataGetLength(data)
        guard let bytes = CFDataGetBytePtr(data), length > 0 else {
            return true
        }

        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        let alphaInfo = image.alphaInfo
        let alphaOffset: Int? = switch alphaInfo {
        case .premultipliedFirst, .first, .noneSkipFirst:
            0
        case .premultipliedLast, .last, .noneSkipLast:
            bytesPerPixel - 1
        default:
            nil
        }

        guard let alphaOffset else {
            return true
        }

        var count = 0
        var index = alphaOffset
        while index < length {
            if bytes[index] > 0 {
                count += 1
                if count >= 10 {
                    return true
                }
            }
            index += bytesPerPixel
        }
        return false
    }

    private static func adjustedDurations(_ durations: [Int], usedColumns: Int) -> [Int] {
        guard usedColumns > 0 else {
            return []
        }
        guard usedColumns > durations.count, let last = durations.last else {
            return Array(durations.prefix(usedColumns))
        }

        if durations.count == 1 {
            return Array(repeating: last, count: usedColumns)
        }

        let bodyDuration = durations[durations.count - 2]
        let fillerCount = usedColumns - durations.count
        return Array(durations.dropLast()) + Array(repeating: bodyDuration, count: fillerCount) + [last]
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CodexPetSupportError.couldNotWriteFrame(url.path())
        }
        try data.write(to: url, options: .atomic)
    }
}

private struct CodexRowSpec: Sendable {
    var name: String
    var row: Int
    var usedColumns: Int
    var durationsMs: [Int]
    var loop: Bool
    var transitionOut: PetTransitionHint?
}

private struct ExtractedState: Sendable {
    var frames: [PetFrame]
    var durationsMs: [Int]
    var loop: Bool
    var transitionOut: PetTransitionHint?
}
