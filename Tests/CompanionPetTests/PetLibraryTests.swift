import AppKit
import Foundation
import Testing
@testable import CompanionPet

struct PetLibraryTests {
    @Test
    func loadsBuiltInPetManifest() throws {
        let library = PetLibrary()
        let pack = try library.loadBuiltInPet()

        #expect(pack.manifest.id == BuiltInPet.defaultID)
        #expect(pack.manifest.resolvedState(named: .idle) != nil)
        #expect(pack.source == .builtIn)
    }

    @Test
    func legacyBuiltInPetIdentifierStillResolves() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let customDirectory = root.appending(path: "OpenPet", directoryHint: .isDirectory)
        let codexDirectory = root.appending(path: ".codex/pets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)

        let library = PetLibrary()
        let loadedPack = try library.loadPet(
            id: "orbiter",
            customDirectory: customDirectory,
            codexDirectory: codexDirectory
        )
        let pack = try #require(loadedPack)

        #expect(pack.id == BuiltInPet.defaultID)
        #expect(pack.source == .builtIn)
    }

    @Test
    func codexPetExposesBakedJumpingAndWavingStates() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let customDirectory = tempDirectory.appending(path: "Pets", directoryHint: .isDirectory)
        let petDirectory = customDirectory.appending(path: "pixel-pal", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: petDirectory, withIntermediateDirectories: true)

        let manifest = """
        {
          "id": "pixel-pal",
          "displayName": "Pixel Pal",
          "description": "A Codex atlas pet.",
          "spritesheetPath": "spritesheet.png"
        }
        """
        try manifest.write(to: petDirectory.appending(path: "pet.json"), atomically: true, encoding: .utf8)
        try makeCodexSpritesheet().writePNG(to: petDirectory.appending(path: "spritesheet.png"))

        let library = PetLibrary()
        let packs = try library.loadPets(customDirectory: customDirectory)
        let pack = try #require(packs.first(where: { $0.id == "pixel-pal" }))

        // Codex atlas row 4 is "jumping" with 5 used columns and does not loop.
        let jumping = try #require(pack.manifest.state(named: .jumping))
        #expect(jumping.frames.count == 5)
        #expect(jumping.loop == false)

        // Codex atlas row 3 is "waving" with 4 used columns and loops.
        let waving = try #require(pack.manifest.state(named: .waving))
        #expect(waving.frames.count == 4)
        #expect(waving.loop == true)

        // Codex atlases do not have a dedicated sleep row, so OpenPet uses the
        // patient waiting loop instead of falling back to idle.
        let sleeping = try #require(pack.manifest.state(named: .sleeping))
        #expect(sleeping.frames.count == 6)
        #expect(sleeping.frames.first?.value.contains("/waiting/") == true)
    }

    @Test
    func manifestWithoutIdleFailsValidation() {
        let manifest = PetManifest(
            id: "broken",
            displayName: "Broken",
            description: "Missing idle",
            defaultScale: 1,
            anchor: PetAnchor(x: 0.5, y: 0.5),
            states: [
                PetState(
                    name: .thinking,
                    frames: [PetFrame(kind: .symbol, value: "sparkles", tintHex: nil, backgroundHex: nil)],
                    durationsMs: [200],
                    loop: true,
                    transitionOut: nil
                ),
            ]
        )

        #expect(manifest.validationErrors().contains(where: { $0.contains("idle") }))
    }

    @Test
    func loadsCodexStylePetPackage() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let customDirectory = tempDirectory.appending(path: "Pets", directoryHint: .isDirectory)
        let codexPetDirectory = customDirectory.appending(path: "pixel-pal", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: codexPetDirectory, withIntermediateDirectories: true)

        let manifest = """
        {
          "id": "pixel-pal",
          "displayName": "Pixel Pal",
          "description": "A Codex atlas pet.",
          "spritesheetPath": "spritesheet.png"
        }
        """
        try manifest.write(to: codexPetDirectory.appending(path: "pet.json"), atomically: true, encoding: .utf8)
        try makeCodexSpritesheet().writePNG(to: codexPetDirectory.appending(path: "spritesheet.png"))

        let library = PetLibrary()
        let packs = try library.loadPets(customDirectory: customDirectory)
        let pack = try #require(packs.first(where: { $0.id == "pixel-pal" }))

        #expect(pack.manifest.resolvedState(named: .thinking)?.frames.count == 6)
        #expect(pack.manifest.resolvedState(named: .replying)?.frames.count == 4)
        #expect(pack.manifest.resolvedState(named: .replying)?.durationsMs.count == 4)
        #expect(pack.manifest.resolvedState(named: .error)?.durationsMs.last == 300)

        let extractedURL = try #require(
            pack.directoryURL?.appending(path: ".openpet-cache/codex-frames-v3/review/0.png")
        )
        #expect(FileManager.default.fileExists(atPath: extractedURL.path()))
    }

    @Test
    func loadsPetsFromCodexDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let customDirectory = root.appending(path: "OpenPet", directoryHint: .isDirectory)
        let codexDirectory = root.appending(path: ".codex/pets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)

        let codexPetDirectory = codexDirectory.appending(path: "pixel-pal", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: codexPetDirectory, withIntermediateDirectories: true)
        try writeCodexPet(at: codexPetDirectory, description: "Loaded from Codex.")

        let library = PetLibrary()
        let packs = try library.loadPets(customDirectory: customDirectory, codexDirectory: codexDirectory)
        let pack = try #require(packs.first(where: { $0.id == "pixel-pal" }))

        #expect(pack.source == .codex)
        #expect(pack.manifest.description == "Loaded from Codex.")
    }

    @Test
    func loadsSpecificPetByIDWithoutFullScan() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let customDirectory = root.appending(path: "OpenPet", directoryHint: .isDirectory)
        let codexDirectory = root.appending(path: ".codex/pets", directoryHint: .isDirectory)
        let petDirectory = customDirectory.appending(path: "pixel-pal", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: petDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try writeCodexPet(at: petDirectory, description: "Loaded directly.")

        let library = PetLibrary()
        let loadedPack = try library.loadPet(id: "pixel-pal", customDirectory: customDirectory, codexDirectory: codexDirectory)
        let pack = try #require(loadedPack)

        #expect(pack.id == "pixel-pal")
        #expect(pack.source == .custom)
        #expect(pack.manifest.description == "Loaded directly.")
    }

    @Test
    func prefersOpenPetCustomPetOverCodexDuplicate() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let customDirectory = root.appending(path: "OpenPet", directoryHint: .isDirectory)
        let codexDirectory = root.appending(path: ".codex/pets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)

        let customPetDirectory = customDirectory.appending(path: "pixel-pal", directoryHint: .isDirectory)
        let codexPetDirectory = codexDirectory.appending(path: "pixel-pal", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: customPetDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexPetDirectory, withIntermediateDirectories: true)

        try writeCodexPet(at: customPetDirectory, description: "OpenPet copy.")
        try writeCodexPet(at: codexPetDirectory, description: "Codex copy.")

        let library = PetLibrary()
        let packs = try library.loadPets(customDirectory: customDirectory, codexDirectory: codexDirectory)
        let matches = packs.filter { $0.id == "pixel-pal" }
        let pack = try #require(matches.first)

        #expect(matches.count == 1)
        #expect(pack.source == .custom)
        #expect(pack.manifest.description == "OpenPet copy.")
    }
}

private func makeCodexSpritesheet() throws -> NSBitmapImageRep {
    let width = 1536
    let height = 1872
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw CocoaError(.coderInvalidValue)
    }

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.coderInvalidValue)
    }
    NSGraphicsContext.current = context

    for row in 0..<9 {
        for column in 0..<8 {
            let hue = CGFloat((row * 8) + column) / CGFloat(9 * 8)
            NSColor(calibratedHue: hue, saturation: 0.6, brightness: 0.95, alpha: 1.0).setFill()
            NSBezierPath(
                rect: NSRect(
                    x: column * 192,
                    y: row * 208,
                    width: 192,
                    height: 208
                )
            ).fill()
        }
    }

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

private func writeCodexPet(at directory: URL, description: String) throws {
    let manifest = """
    {
      "id": "pixel-pal",
      "displayName": "Pixel Pal",
      "description": "\(description)",
      "spritesheetPath": "spritesheet.png"
    }
    """
    try manifest.write(to: directory.appending(path: "pet.json"), atomically: true, encoding: .utf8)
    try makeCodexSpritesheet().writePNG(to: directory.appending(path: "spritesheet.png"))
}

private extension NSBitmapImageRep {
    func writePNG(to url: URL) throws {
        guard let pngData = representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try pngData.write(to: url, options: .atomic)
    }
}
