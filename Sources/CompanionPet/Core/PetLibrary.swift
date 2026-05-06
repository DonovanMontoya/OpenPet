import Foundation

enum BuiltInPet {
    static let defaultID = "violet"
    static let legacyIDs: Set<String> = ["orbiter"]

    static func matches(_ id: String) -> Bool {
        id == defaultID || legacyIDs.contains(id)
    }
}

struct PetLibrary {
    func loadPet(id: String, customDirectory: URL, codexDirectory: URL? = nil) throws -> PetPack? {
        if BuiltInPet.matches(id) {
            return try loadBuiltInPet()
        }

        if let pack = try loadPack(id: id, from: customDirectory, source: .custom) {
            return pack
        }

        if let codexDirectory,
           let pack = try loadPack(id: id, from: codexDirectory, source: .codex) {
            return pack
        }

        return nil
    }

    func loadPets(customDirectory: URL, codexDirectory: URL? = nil) throws -> [PetPack] {
        var packs: [PetPack] = [try loadBuiltInPet()]
        var seenIDs: Set<String> = [packs[0].id]

        try loadPacks(from: customDirectory, source: .custom, into: &packs, seenIDs: &seenIDs)

        if let codexDirectory {
            try loadPacks(from: codexDirectory, source: .codex, into: &packs, seenIDs: &seenIDs)
        }

        return packs.sorted { lhs, rhs in
            let lhsRank = sourceRank(lhs.source)
            let rhsRank = sourceRank(rhs.source)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.manifest.displayName.localizedCaseInsensitiveCompare(rhs.manifest.displayName) == .orderedAscending
        }
    }

    private func loadPacks(
        from directory: URL,
        source: PetPackSource,
        into packs: inout [PetPack],
        seenIDs: inout Set<String>
    ) throws {

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path()) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let childURLs = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for childURL in childURLs {
            let values = try childURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                continue
            }

            let manifestURL = childURL.appending(path: "pet.json")
            guard fileManager.fileExists(atPath: manifestURL.path()) else {
                continue
            }

            do {
                let manifest = try decodeAnyManifest(at: manifestURL, directoryURL: childURL)
                let errors = manifest.validationErrors()
                guard errors.isEmpty else {
                    continue
                }
                guard !seenIDs.contains(manifest.id) else {
                    continue
                }

                packs.append(
                    PetPack(
                        manifest: manifest,
                        directoryURL: childURL,
                        source: source
                    )
                )
                seenIDs.insert(manifest.id)
            } catch {
                continue
            }
        }
    }

    private func loadPack(id: String, from directory: URL, source: PetPackSource) throws -> PetPack? {
        let fileManager = FileManager.default
        let packDirectory = directory.appending(path: id, directoryHint: .isDirectory)
        let manifestURL = packDirectory.appending(path: "pet.json")
        guard fileManager.fileExists(atPath: manifestURL.path()) else {
            return nil
        }

        let manifest = try decodeAnyManifest(at: manifestURL, directoryURL: packDirectory)
        let errors = manifest.validationErrors()
        guard errors.isEmpty, manifest.id == id else {
            return nil
        }

        return PetPack(
            manifest: manifest,
            directoryURL: packDirectory,
            source: source
        )
    }

    func loadBuiltInPet() throws -> PetPack {
        guard let manifestURL = builtInManifestURL() else {
            throw PetLibraryError.missingBuiltInManifest
        }

        let manifest = try decodeAnyManifest(
            at: manifestURL,
            directoryURL: manifestURL.deletingLastPathComponent()
        )
        let errors = manifest.validationErrors()
        guard errors.isEmpty else {
            throw PetLibraryError.invalidManifest(errors.joined(separator: " "))
        }

        return PetPack(
            manifest: manifest,
            directoryURL: manifestURL.deletingLastPathComponent(),
            source: .builtIn
        )
    }

    func decodeAnyManifest(at url: URL, directoryURL: URL) throws -> PetManifest {
        do {
            return try decodeManifest(at: url)
        } catch {
            let codexManifest = try decodeCodexManifest(at: url)
            return try CodexPetSupport.makeManifest(from: codexManifest, in: directoryURL)
        }
    }

    private func decodeManifest(at url: URL) throws -> PetManifest {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return try decoder.decode(PetManifest.self, from: data)
    }

    private func builtInManifestURL() -> URL? {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.resourceURL?.appending(path: "pet.json") {
            return url
        }
        #endif

        if let url = Bundle.main.resourceURL?.appending(path: "pet.json") {
            return url
        }

        guard let resourceBundleURL = Bundle.main.resourceURL?
            .appending(path: "CompanionPet_CompanionPet.bundle", directoryHint: .isDirectory),
              let resourceBundle = Bundle(url: resourceBundleURL) else {
            return nil
        }

        return resourceBundle.resourceURL?.appending(path: "pet.json")
    }

    private func decodeCodexManifest(at url: URL) throws -> CodexPetManifest {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return try decoder.decode(CodexPetManifest.self, from: data)
    }

    private func sourceRank(_ source: PetPackSource) -> Int {
        switch source {
        case .builtIn:
            return 0
        case .custom:
            return 1
        case .codex:
            return 2
        }
    }
}
