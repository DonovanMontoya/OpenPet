import AppKit
import Foundation
import SwiftUI

struct OverlayBubble: Identifiable, Equatable {
    var id: String
    var title: String?
    var text: String
    var symbolName: String?
    var sourceBadge: OverlaySourceBadge
    var source: String
    var expiresAt: Date?
    var updatedAt: Date
}

struct OverlaySourceBadge: Equatable {
    var label: String
    var symbolName: String
    var accessibilityLabel: String
}

private enum OverlayBubbleUpdateMode {
    case replace
    case append
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    private static let idleAnimationRestDurationMs = 4_500

    @Published var settings: CompanionSettings {
        didSet {
            settingsStore.save(settings)
            handleSettingsChange(from: oldValue)
        }
    }

    @Published private(set) var availablePets: [PetPack] = []
    @Published private(set) var selectedPet: PetPack?
    @Published private(set) var currentState: CompanionStateName = .idle
    @Published private(set) var lastEventSummary: String = "Waiting for activity"
    @Published private(set) var overlayMessageTitle: String?
    @Published private(set) var overlayMessage: String?
    @Published private(set) var overlayMessageSymbolName: String?
    @Published private(set) var overlayMessageSource: String?
    @Published private(set) var overlayBubbles: [OverlayBubble] = []
    @Published private(set) var isOverlayHovered = false
    @Published private(set) var dragFacingDirection: DragFacingDirection = .right
    @Published private(set) var adapterHealthByID: [String: AdapterHealth] = [:]
    @Published private(set) var settingsMessage: String = ""

    private let settingsStore = SettingsStore()
    private let petLibrary = PetLibrary()
    private let behaviorEngine = CompanionBehaviorEngine()
    private let adapterHost = AdapterHost()

    private var overlayController: OverlayWindowController?
    private var statusBarController: StatusBarController?
    private var settingsWindowController: SettingsWindowController?
    private var eventTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var stateEnteredAt: Date = .now
    private var visualOverrideState: CompanionStateName?
    private var visualOverrideUntil: Date?
    private var visualOverrideEnteredAt: Date?
    private var codexAdapter: CodexCLIAdapter?
    private var lmStudioAdapter: LMStudioProxyAdapter?
    private var claudeCodeAdapter: ClaudeCodeAdapter?
    private var openCodeAdapter: OpenCodeAdapter?
    private var isStarted = false
    private var overlayMessageExpiresAt: Date?
    private var isDraggingOverlay = false
    private var activityTitlesByKey: [String: String] = [:]
    private var overlayActivitySourcesByKey: [String: String] = [:]
    private var waitingBubbleSource: String?
    private var lastWaveAt: Date?
    private static let waveCooldownSeconds: TimeInterval = 6.0
    private static let waitingBubbleID = "openpet.waiting_for_user"

    private init() {
        self.settings = settingsStore.load()
    }

    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true

        loadSelectedPetForLaunch()
        currentState = .disconnected
        stateEnteredAt = .now

        eventTask = Task { [weak self] in
            guard let self else {
                return
            }
            let stream = self.adapterHost.events()
            for await event in stream {
                await self.consume(event: event)
            }
        }

        Task {
            reloadPets()
            await rebuildAdapters()
        }
    }

    func stop() async {
        eventTask?.cancel()
        eventTask = nil
        wakeTask?.cancel()
        wakeTask = nil
        await adapterHost.stopAll()
        isStarted = false
    }

    func attachOverlayController(_ controller: OverlayWindowController) {
        overlayController = controller
        controller.install()
        controller.apply(settings: settings, selectedPetChanged: false)
    }

    func attachStatusBarController(_ controller: StatusBarController) {
        statusBarController = controller
        controller.refresh()
    }

    func attachSettingsWindowController(_ controller: SettingsWindowController) {
        settingsWindowController = controller
    }

    func togglePause() {
        settings.isPaused.toggle()
    }

    func toggleLock() {
        settings.isLocked.toggle()
    }

    func selectScale(_ preset: OverlayScalePreset) {
        settings.overlayScalePreset = preset
    }

    func selectPet(id: String) {
        settings.selectedPetID = id
    }

    func setReducedMotion(_ enabled: Bool) {
        settings.reducedMotion = enabled
    }

    func setSpeechBubblesEnabled(_ enabled: Bool) {
        settings.showsSpeechBubbles = enabled
    }

    func updateCodexExecutablePath(_ path: String) {
        settings.codex.executablePath = path
    }

    func updateCodexWorkingDirectory(_ path: String) {
        settings.codex.workingDirectoryPath = path
    }

    func updateCodexPreferredModel(_ model: String) {
        settings.codex.preferredModel = model
    }

    func setCodexEnabled(_ enabled: Bool) {
        settings.codex.enabled = enabled
    }

    func updateLMStudioEndpoint(_ endpoint: String) {
        settings.lmStudio.upstreamBaseURL = endpoint
    }

    func updateLMStudioPort(_ port: Int) {
        settings.lmStudio.listenPort = port
    }

    func setLMStudioEnabled(_ enabled: Bool) {
        settings.lmStudio.enabled = enabled
    }

    func updateClaudeCodeExecutablePath(_ path: String) {
        settings.claudeCode.executablePath = path
    }

    func updateClaudeCodeWorkingDirectory(_ path: String) {
        settings.claudeCode.workingDirectoryPath = path
    }

    func updateClaudeCodePort(_ port: Int) {
        settings.claudeCode.hookListenerPort = port
    }

    func setClaudeCodeEnabled(_ enabled: Bool) {
        settings.claudeCode.enabled = enabled
    }

    func updateOpenCodeExecutablePath(_ path: String) {
        settings.openCode.executablePath = path
    }

    func updateOpenCodeWorkingDirectory(_ path: String) {
        settings.openCode.workingDirectoryPath = path
    }

    func setOpenCodeEnabled(_ enabled: Bool) {
        settings.openCode.enabled = enabled
    }

    func openSettings() {
        settingsWindowController?.show()
    }

    func customPetsDirectoryPath() -> String {
        (try? AppSupportPaths.customPetsDirectory().path()) ?? ""
    }

    func codexPetsDirectoryPath() -> String {
        (try? AppSupportPaths.codexPetsDirectory().path()) ?? ""
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func noteOverlayInteraction() {
        let snapshot = behaviorEngine.recordInteraction()
        apply(snapshot: snapshot, at: .now)
    }

    func handleOverlayTap() {
        noteOverlayInteraction()
        if currentState == .sleeping || currentState == .disconnected {
            currentState = .idle
        }
    }

    func handleOverlayDoubleTap() {
        let now = Date.now
        let snapshot = behaviorEngine.recordJump(at: now)
        apply(snapshot: snapshot, at: now)
    }

    func handleHoverDwell() {
        let now = Date.now
        if let lastWaveAt, now.timeIntervalSince(lastWaveAt) < AppModel.waveCooldownSeconds {
            return
        }
        // Only wave when the pet is in a calm state — avoid interrupting active work.
        switch currentState {
        case .idle, .ambient, .waitingForUser, .sleeping, .disconnected:
            break
        default:
            return
        }
        lastWaveAt = now
        let snapshot = behaviorEngine.recordWave(at: now)
        apply(snapshot: snapshot, at: now)
    }

    func setOverlayHovered(_ hovered: Bool) {
        guard isOverlayHovered != hovered else {
            return
        }
        isOverlayHovered = hovered
    }

    func beginDrag() {
        isDraggingOverlay = true
        noteOverlayInteraction()
    }

    func updateOverlayPosition(to proposedOrigin: CGPoint, horizontalMotion: CGFloat) {
        guard let overlayController else {
            return
        }
        if horizontalMotion < 0 {
            dragFacingDirection = .left
        } else if horizontalMotion > 0 {
            dragFacingDirection = .right
        }
        overlayController.setOrigin(proposedOrigin, snap: false)
    }

    func finishOverlayDrag() {
        guard let overlayController else {
            return
        }
        noteOverlayInteraction()
        let snapped = overlayController.snapToVisibleFrame()
        isDraggingOverlay = false
        settings.overlayPlacement = snapped
    }

    func currentWindowOrigin() -> CGPoint {
        overlayController?.currentOrigin ?? .zero
    }

    func petCanvasSize() -> CGSize {
        settings.overlayScalePreset.petCanvasSize
    }

    func bubbleCanvasSize() -> CGSize {
        let baseSize = settings.overlayScalePreset.bubbleCanvasSize
        let count = max(1, overlayBubbles.count)
        let spacing = 8.0
        return CGSize(
            width: baseSize.width,
            height: baseSize.height * Double(count) + spacing * Double(count - 1)
        )
    }

    func showsOverlayBubble() -> Bool {
        settings.showsSpeechBubbles && !overlayBubbles.isEmpty
    }

    func handleOverlayBubbleTap(id: String, source: String?) {
        if let bubble = overlayBubbles.first(where: { $0.id == id }),
           bubble.symbolName == "checkmark.circle.fill" {
            overlayBubbles.removeAll { $0.id == id }
            if overlayBubbles.isEmpty {
                overlayMessage = nil
                overlayMessageTitle = nil
                overlayMessageSymbolName = nil
                overlayMessageSource = nil
                overlayMessageExpiresAt = nil
            }
            applyOverlaySettings(selectedPetChanged: false)
            return
        }

        guard let source else {
            return
        }

        switch source {
        case "codex", "codex-cli", "codex-app", "codex-desktop":
            activateRunningApplication(named: "Codex")
        case "claude-code":
            activateTerminalApplication()
        case "opencode-cli":
            activateTerminalApplication()
        case "lmstudio-proxy":
            activateRunningApplication(named: "LM Studio")
        default:
            break
        }
    }

    func renderFrame(at date: Date) -> PetRenderFrame? {
        guard let selectedPet else {
            return nil
        }

        let semanticState = settings.isPaused ? CompanionStateName.idle : currentState
        let overrideState = activeVisualOverride(at: date)
        let baseVisualState = overrideState ?? semanticState
        let visualState = isDraggingOverlay && !settings.isPaused ? CompanionStateName.working : baseVisualState
        let enteredAt = overrideState == nil ? stateEnteredAt : (visualOverrideEnteredAt ?? stateEnteredAt)

        guard let state = selectedPet.manifest.resolvedState(named: visualState) else {
            return nil
        }

        let frameIndex: Int
        if settings.reducedMotion || settings.isPaused {
            frameIndex = 0
        } else {
            frameIndex = computeFrameIndex(for: state, semanticState: visualState, enteredAt: enteredAt, at: date)
        }

        guard state.frames.indices.contains(frameIndex) else {
            return fallbackRenderFrame(for: selectedPet)
        }
        let frame = state.frames[frameIndex]
        if frame.kind == .file {
            guard let url = selectedPet.resolvedFrameURL(for: frame), FileManager.default.fileExists(atPath: url.path()) else {
                return fallbackRenderFrame(for: selectedPet)
            }
        }

        return PetRenderFrame(
            petPack: selectedPet,
            semanticState: visualState,
            state: state,
            frameIndex: frameIndex,
            frame: frame
        )
    }

    private func fallbackRenderFrame(for petPack: PetPack) -> PetRenderFrame? {
        guard let idleState = petPack.manifest.state(named: .idle), let frame = idleState.frames.first else {
            return nil
        }
        return PetRenderFrame(
            petPack: petPack,
            semanticState: .idle,
            state: idleState,
            frameIndex: 0,
            frame: frame
        )
    }

    func proxyBaseURL() -> String {
        "http://\(settings.lmStudio.listenHost):\(settings.lmStudio.listenPort)"
    }

    func runCodexSample(prompt: String) {
        Task {
            guard let codexAdapter else {
                return
            }
            let workingDirectory = URL(filePath: settings.codex.workingDirectoryPath)
            try? await codexAdapter.launchSession(
                prompt: prompt,
                workingDirectory: workingDirectory,
                model: settings.codex.preferredModel.isEmpty ? nil : settings.codex.preferredModel
            )
        }
    }

    func launchClaudeCode() {
        let workingDirectory = URL(filePath: settings.claudeCode.workingDirectoryPath)
        claudeCodeAdapter?.openTerminalSession(workingDirectory: workingDirectory)
    }

    func launchOpenCode() {
        let workingDirectory = URL(filePath: settings.openCode.workingDirectoryPath)
        openCodeAdapter?.openTerminalSession(workingDirectory: workingDirectory)
    }

    func showGitAwareMood() {
        emitLocalActivity(kind: .gitChanged, message: "Git changes noticed.")
    }

    func showBuildStartedEmote() {
        emitLocalActivity(kind: .buildStarted, message: "Build or tests running.")
    }

    func showBuildSucceededEmote() {
        emitLocalActivity(kind: .buildSucceeded, message: "Build or tests passed.")
    }

    func showBuildFailedEmote() {
        emitLocalActivity(kind: .buildFailed, message: "Build or tests failed.")
    }

    func startManualCodingRhythm() {
        emitLocalActivity(kind: .codingStarted, message: "Coding rhythm started.")
    }

    func stopManualCodingRhythm() {
        emitLocalActivity(kind: .codingStopped, message: "Coding rhythm stopped.")
    }

    func startFocusFlow() {
        emitLocalActivity(kind: .focusStarted, message: "Focus flow started.")
    }

    func takeFocusBreak() {
        emitLocalActivity(kind: .focusBreak, message: "Focus break.")
    }

    func refreshPets() {
        reloadPets()
        settingsMessage = "Pet library refreshed."
    }

    func revealPetsDirectory() {
        do {
            let petsDirectory = try AppSupportPaths.customPetsDirectory()
            let codexPetsDirectory = try AppSupportPaths.codexPetsDirectory()
            NSWorkspace.shared.activateFileViewerSelecting([petsDirectory, codexPetsDirectory])
            settingsMessage = "Opened OpenPet and Codex pet folders."
        } catch {
            settingsMessage = "Could not open pets directory: \(error.localizedDescription)"
        }
    }

    func importPetFolder() {
        let panel = NSOpenPanel()
        panel.title = "Import Pet Folder"
        panel.message = "Choose a folder containing pet.json and any referenced assets."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let sourceURL = panel.url else {
            return
        }

        do {
            let destination = try importPet(from: sourceURL)
            reloadPets()
            if let importedPet = availablePets.first(where: { $0.directoryURL == destination }) {
                settings.selectedPetID = importedPet.id
            }
            settingsMessage = "Imported pet from \(sourceURL.lastPathComponent)."
        } catch {
            settingsMessage = "Pet import failed: \(error.localizedDescription)"
        }
    }

    func autoDetectCodex() {
        let executableCandidates = [
            settings.codex.executablePath,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ].filter { !$0.isEmpty }

        if let path = executableCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            settings.codex.executablePath = path
            settings.codex.enabled = true
            settingsMessage = "Attached Codex adapter to \(path)."
            return
        }

        do {
            let resolvedPath = try resolveExecutable(named: "codex")
            settings.codex.executablePath = resolvedPath
            settings.codex.enabled = true
            settingsMessage = "Attached Codex adapter to \(resolvedPath)."
        } catch {
            settingsMessage = "Could not locate Codex CLI automatically."
        }
    }

    func autoDetectClaude() {
        let executableCandidates = [
            settings.claudeCode.executablePath,
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ].filter { !$0.isEmpty }

        if let path = executableCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            settings.claudeCode.executablePath = path
            settings.claudeCode.enabled = true
            settingsMessage = "Attached Claude Code adapter to \(path)."
            return
        }

        do {
            let resolvedPath = try resolveExecutable(named: "claude")
            settings.claudeCode.executablePath = resolvedPath
            settings.claudeCode.enabled = true
            settingsMessage = "Attached Claude Code adapter to \(resolvedPath)."
        } catch {
            settingsMessage = "Could not locate Claude Code automatically."
        }
    }

    func autoDetectOpenCode() {
        let executableCandidates = [
            settings.openCode.executablePath,
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
        ].filter { !$0.isEmpty }

        if let path = executableCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            settings.openCode.executablePath = path
            settings.openCode.enabled = true
            settingsMessage = "Attached OpenCode adapter to \(path)."
            return
        }

        do {
            let resolvedPath = try resolveExecutable(named: "opencode")
            settings.openCode.executablePath = resolvedPath
            settings.openCode.enabled = true
            settingsMessage = "Attached OpenCode adapter to \(resolvedPath)."
        } catch {
            settingsMessage = "Could not locate OpenCode automatically."
        }
    }

    func chooseCodexExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose Codex Executable"
        panel.message = "Select the Codex CLI executable."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        settings.codex.executablePath = selectedURL.path()
        settings.codex.enabled = true
        settingsMessage = "Updated Codex executable path."
    }

    func chooseCodexWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Codex Working Directory"
        panel.message = "Select the project directory Codex should use."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        settings.codex.workingDirectoryPath = selectedURL.path()
        settings.codex.enabled = true
        settingsMessage = "Updated Codex working directory."
    }

    func chooseClaudeExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose Claude Code Executable"
        panel.message = "Select the Claude Code executable."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        settings.claudeCode.executablePath = selectedURL.path()
        settings.claudeCode.enabled = true
        settingsMessage = "Updated Claude Code executable path."
    }

    func chooseClaudeWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Claude Code Working Directory"
        panel.message = "Select the project directory Claude Code should use."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        settings.claudeCode.workingDirectoryPath = selectedURL.path()
        settings.claudeCode.enabled = true
        settingsMessage = "Updated Claude Code working directory."
    }

    func chooseOpenCodeExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose OpenCode Executable"
        panel.message = "Select the OpenCode executable."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        settings.openCode.executablePath = selectedURL.path()
        settings.openCode.enabled = true
        settingsMessage = "Updated OpenCode executable path."
    }

    func chooseOpenCodeWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose OpenCode Working Directory"
        panel.message = "Select the project directory OpenCode should use."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        settings.openCode.workingDirectoryPath = selectedURL.path()
        settings.openCode.enabled = true
        settingsMessage = "Updated OpenCode working directory."
    }

    private func handleSettingsChange(from oldSettings: CompanionSettings) {
        if oldSettings.selectedPetID != settings.selectedPetID {
            resolveSelectedPet()
        }

        if oldSettings.overlayScalePreset != settings.overlayScalePreset ||
            oldSettings.isLocked != settings.isLocked ||
            oldSettings.overlayPlacement != settings.overlayPlacement ||
            oldSettings.selectedPetID != settings.selectedPetID {
            applyOverlaySettings(selectedPetChanged: false)
        }

        if oldSettings.codex != settings.codex ||
            oldSettings.lmStudio != settings.lmStudio ||
            oldSettings.claudeCode != settings.claudeCode ||
            oldSettings.openCode != settings.openCode {
            Task {
                await rebuildAdapters()
            }
        }

        statusBarController?.refresh()
    }

    private func reloadPets() {
        do {
            let customDirectory = try AppSupportPaths.customPetsDirectory()
            let codexDirectory = try AppSupportPaths.codexPetsDirectory()
            availablePets = try petLibrary.loadPets(
                customDirectory: customDirectory,
                codexDirectory: codexDirectory
            )
        } catch {
            availablePets = []
        }
        resolveSelectedPet()
    }

    private func loadSelectedPetForLaunch() {
        do {
            let customDirectory = try AppSupportPaths.customPetsDirectory()
            let codexDirectory = try AppSupportPaths.codexPetsDirectory()
            let launchPet = try petLibrary.loadPet(
                id: settings.selectedPetID,
                customDirectory: customDirectory,
                codexDirectory: codexDirectory
            ) ?? petLibrary.loadBuiltInPet()

            availablePets = [launchPet]
            selectedPet = launchPet
            overlayController?.apply(settings: settings, selectedPetChanged: true)
            statusBarController?.refresh()
        } catch {
            availablePets = []
            selectedPet = nil
        }
    }

    private func resolveSelectedPet() {
        if let exactMatch = availablePets.first(where: { $0.id == settings.selectedPetID }) {
            selectedPet = exactMatch
        } else {
            selectedPet = availablePets.first
            settings.selectedPetID = selectedPet?.id ?? "orbiter"
        }
        overlayController?.apply(settings: settings, selectedPetChanged: true)
        statusBarController?.refresh()
    }

    private func importPet(from sourceURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let customDirectory = try AppSupportPaths.customPetsDirectory(fileManager: fileManager)
        let manifestURL = sourceURL.appending(path: "pet.json")

        guard fileManager.fileExists(atPath: manifestURL.path()) else {
            throw NSError(
                domain: "OpenPet.Import",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The selected folder does not contain pet.json."]
            )
        }

        let manifest = try petLibrary.decodeAnyManifest(at: manifestURL, directoryURL: sourceURL)
        let errors = manifest.validationErrors()
        guard errors.isEmpty else {
            throw NSError(
                domain: "OpenPet.Import",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: errors.joined(separator: " ")]
            )
        }

        let destinationURL = customDirectory.appending(path: manifest.id, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: destinationURL.path()) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private func resolveExecutable(named executableName: String) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/which")
        process.arguments = [executableName]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "OpenPet.CodexDetect",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not find \(executableName) in PATH."]
            )
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw NSError(
                domain: "OpenPet.CodexDetect",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The detected executable path was empty."]
            )
        }

        return path
    }

    private func rebuildAdapters() async {
        let codexAdapter = CodexCLIAdapter(settings: settings.codex)
        let lmStudioAdapter = LMStudioProxyAdapter(settings: settings.lmStudio)
        let claudeCodeAdapter = ClaudeCodeAdapter(settings: settings.claudeCode)
        let openCodeAdapter = OpenCodeAdapter(settings: settings.openCode)

        self.codexAdapter = codexAdapter
        self.lmStudioAdapter = lmStudioAdapter
        self.claudeCodeAdapter = claudeCodeAdapter
        self.openCodeAdapter = openCodeAdapter

        var adapters: [any CompanionAdapter] = []
        if settings.codex.enabled {
            adapters.append(codexAdapter)
        }
        if settings.lmStudio.enabled {
            adapters.append(lmStudioAdapter)
        }
        if settings.claudeCode.enabled {
            adapters.append(claudeCodeAdapter)
        }
        if settings.openCode.enabled {
            adapters.append(openCodeAdapter)
        }

        await adapterHost.install(adapters)
        adapterHealthByID = await adapterHost.healthSnapshot()
        statusBarController?.refresh()
    }

    private func consume(event: CompanionEvent) async {
        lastEventSummary = summarize(event: event)
        updateOverlayMessage(for: event)
        let snapshot = behaviorEngine.handle(event: event)
        adapterHealthByID = await adapterHost.healthSnapshot()
        apply(snapshot: snapshot, at: event.timestamp)
    }

    private func emitLocalActivity(kind: CompanionEventKind, message: String) {
        let event = CompanionEvent(
            source: "openpet-manual",
            kind: kind,
            payload: ["message": message]
        )
        Task {
            await consume(event: event)
        }
    }

    private func apply(snapshot: BehaviorSnapshot, at date: Date) {
        if currentState != snapshot.currentState {
            updateVisualOverride(forTransitionFrom: currentState, to: snapshot.currentState, at: date)
            currentState = snapshot.currentState
            stateEnteredAt = date
        }

        if let visualOverrideUntil, date >= visualOverrideUntil {
            visualOverrideState = nil
            self.visualOverrideUntil = nil
            visualOverrideEnteredAt = nil
        }

        expireOverlayBubbles(at: date)
        syncWaitingBubble(at: date)

        scheduleWake(for: snapshot.nextWakeAt)
        applyOverlaySettings(selectedPetChanged: false)
        statusBarController?.refresh()
    }

    private func applyOverlaySettings(selectedPetChanged: Bool) {
        guard !isDraggingOverlay || selectedPetChanged else {
            return
        }
        overlayController?.apply(settings: settings, selectedPetChanged: selectedPetChanged)
    }

    private func scheduleWake(for date: Date?) {
        wakeTask?.cancel()
        wakeTask = nil

        let nextBubbleExpiry = overlayBubbles.compactMap(\.expiresAt).min()
        let nextDate = [date, nextBubbleExpiry, visualOverrideUntil].compactMap { $0 }.min()
        guard let nextDate else {
            return
        }

        let delay = max(0, nextDate.timeIntervalSinceNow)
        wakeTask = Task { [weak self] in
            guard let self else {
                return
            }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else {
                return
            }
            let snapshot = self.behaviorEngine.advance()
            self.apply(snapshot: snapshot, at: .now)
        }
    }

    private func summarize(event: CompanionEvent) -> String {
        if let message = event.payload["message"], !message.isEmpty {
            return "\(event.source): \(message)"
        }
        if let text = event.payload["text"], !text.isEmpty {
            return "\(event.source): \(truncatedBubbleText(text))"
        }
        if let command = event.payload["command"], !command.isEmpty {
            return "\(event.source): \(command)"
        }
        return "\(event.source): \(event.kind.rawValue)"
    }

    private func updateOverlayMessage(for event: CompanionEvent) {
        let previousActivityTitle = currentActivityTitle(for: event)
        updateOverlayActivityState(for: event)
        updateActivityTitle(for: event)

        let message: String?
        let title: String?
        let symbolName: String?
        let updateMode: OverlayBubbleUpdateMode
        let duration: TimeInterval
        let keepsBubbleVisible: Bool

        switch event.kind {
        case .gitChanged, .buildSucceeded, .focusBreak:
            message = event.payload["message"] ?? "Nice progress."
            title = nil
            symbolName = event.kind == .buildSucceeded ? "checkmark.circle.fill" : nil
            updateMode = .append
            duration = 2
            keepsBubbleVisible = false
        case .buildStarted, .codingStarted, .focusStarted:
            message = event.payload["message"] ?? "Working..."
            title = nil
            symbolName = "progress"
            updateMode = .append
            duration = 0
            keepsBubbleVisible = true
        case .buildFailed:
            message = event.payload["message"] ?? "Build or tests failed."
            title = nil
            symbolName = nil
            updateMode = .append
            duration = 4
            keepsBubbleVisible = false
        case .codingStopped:
            message = event.payload["message"] ?? "Coding rhythm stopped."
            title = nil
            symbolName = nil
            updateMode = .append
            duration = 2
            keepsBubbleVisible = false
        case .adapterConnected:
            guard !hasActiveOverlayActivity else {
                return
            }
            message = event.payload["message"] ?? "\(sourceLabel(for: event.source)) connected"
            title = nil
            symbolName = nil
            updateMode = .replace
            duration = 2
            keepsBubbleVisible = false
        case .thinkingStarted:
            message = thinkingBubbleText(for: event)
            title = nil
            symbolName = "progress"
            updateMode = .replace
            duration = 0
            keepsBubbleVisible = true
        case .toolStarted:
            message = toolBubbleText(for: event)
            title = currentActivityTitle(for: event) ?? previousActivityTitle
            symbolName = "progress"
            updateMode = .append
            duration = 0
            keepsBubbleVisible = true
        case .streamStarted:
            message = "\(sourceLabel(for: event.source)) replying..."
            title = currentActivityTitle(for: event) ?? previousActivityTitle
            symbolName = "progress"
            updateMode = .append
            duration = 0
            keepsBubbleVisible = true
        case .streamDelta:
            message = event.payload["text"].flatMap(truncatedBubbleText) ?? genericStreamBubble(for: event)
            title = currentActivityTitle(for: event) ?? previousActivityTitle
            symbolName = "progress"
            updateMode = .replace
            duration = 0
            keepsBubbleVisible = true
        case .error:
            message = event.payload["message"].flatMap(truncatedBubbleText) ?? "Something failed."
            title = currentActivityTitle(for: event) ?? previousActivityTitle
            symbolName = nil
            updateMode = .append
            duration = hasActiveOverlayActivity ? 0 : 4
            keepsBubbleVisible = hasActiveOverlayActivity
        case .sessionEnded:
            message = "Done."
            title = previousActivityTitle
            symbolName = "checkmark.circle.fill"
            updateMode = .append
            duration = 12
            keepsBubbleVisible = false
            clearActivityTitle(for: event)
        case .userWaiting:
            message = "Waiting for your input."
            title = sourceLabel(for: event.source)
            symbolName = "questionmark.circle.fill"
            updateMode = .replace
            duration = 0
            keepsBubbleVisible = true
            waitingBubbleSource = event.source
        case .adapterDisconnected:
            message = event.payload["message"].flatMap(truncatedBubbleText) ?? "\(sourceLabel(for: event.source)) disconnected"
            title = nil
            symbolName = nil
            updateMode = .append
            duration = 4
            keepsBubbleVisible = false
        default:
            message = nil
            title = nil
            symbolName = nil
            updateMode = .replace
            duration = 0
            keepsBubbleVisible = false
        }

        guard let message, !message.isEmpty else {
            return
        }
        overlayMessageTitle = title
        overlayMessage = message
        overlayMessageSymbolName = symbolName
        overlayMessageSource = event.source
        overlayMessageExpiresAt = keepsBubbleVisible ? nil : event.timestamp.addingTimeInterval(duration)
        upsertOverlayBubble(
            id: activityKey(for: event),
            title: title,
            text: message,
            symbolName: symbolName,
            sourceBadge: sourceBadge(for: event),
            source: event.source,
            expiresAt: keepsBubbleVisible ? nil : event.timestamp.addingTimeInterval(duration),
            updatedAt: event.timestamp,
            updateMode: updateMode
        )
    }

    private func upsertOverlayBubble(
        id: String,
        title: String?,
        text: String,
        symbolName: String?,
        sourceBadge: OverlaySourceBadge,
        source: String,
        expiresAt: Date?,
        updatedAt: Date,
        updateMode: OverlayBubbleUpdateMode
    ) {
        let resolvedText: String
        if updateMode == .append,
           let existing = overlayBubbles.first(where: { $0.id == id })?.text {
            resolvedText = appendedBubbleText(existing: existing, next: text)
        } else {
            resolvedText = text
        }

        let bubble = OverlayBubble(
            id: id,
            title: title,
            text: resolvedText,
            symbolName: symbolName,
            sourceBadge: sourceBadge,
            source: source,
            expiresAt: expiresAt,
            updatedAt: updatedAt
        )

        if let index = overlayBubbles.firstIndex(where: { $0.id == id }) {
            overlayBubbles[index] = bubble
        } else {
            overlayBubbles.append(bubble)
        }
        overlayBubbles.sort { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
    }

    private func syncWaitingBubble(at date: Date) {
        guard currentState == .waitingForUser else {
            removeWaitingBubble()
            return
        }

        let source = waitingBubbleSource ?? "openpet-manual"
        upsertOverlayBubble(
            id: Self.waitingBubbleID,
            title: sourceLabel(for: source),
            text: "Waiting for your input.",
            symbolName: "questionmark.circle.fill",
            sourceBadge: sourceBadge(forSource: source, modelId: nil),
            source: source,
            expiresAt: nil,
            updatedAt: date,
            updateMode: .replace
        )
    }

    private func removeWaitingBubble() {
        overlayBubbles.removeAll { $0.id == Self.waitingBubbleID }
    }

    private func appendedBubbleText(existing: String, next: String) -> String {
        let compactNext = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compactNext.isEmpty else {
            return existing
        }

        let lines = existing
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == compactNext {
            return existing
        }

        let combined = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else {
            return compactNext
        }
        return combined + "\n" + compactNext
    }

    private func expireOverlayBubbles(at date: Date) {
        overlayBubbles.removeAll { bubble in
            guard let expiresAt = bubble.expiresAt, date >= expiresAt else {
                return false
            }
            return true
        }

        if overlayBubbles.isEmpty {
            overlayMessage = nil
            overlayMessageTitle = nil
            overlayMessageSymbolName = nil
            overlayMessageSource = nil
            overlayMessageExpiresAt = nil
        }
    }

    private func truncatedBubbleText(_ text: String) -> String {
        truncatedText(text, limit: 72)
    }

    private func truncatedTitleText(_ text: String) -> String {
        truncatedText(text, limit: 42)
    }

    private func truncatedText(_ text: String, limit: Int) -> String {
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > limit else {
            return compact
        }
        return String(compact.prefix(max(0, limit - 3))).trimmingCharacters(in: .whitespaces) + "..."
    }

    private func toolBubbleText(for event: CompanionEvent) -> String? {
        if event.payload["item_type"] == "local_shell_call" {
            let command = event.payload["display_command"] ?? event.payload["command"] ?? ""
            let commandText = commandBubbleText(command, limit: 58)
            return commandText == "Working..." ? "Running command..." : "Running \(commandText)"
        }

        guard let command = event.payload["display_command"] ?? event.payload["command"] else {
            return nil
        }
        return commandBubbleText(command, limit: 72)
    }

    private func commandBubbleText(_ command: String, limit: Int) -> String {
        let compact = command
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else {
            return "Working..."
        }
        return truncatedText(compact, limit: limit)
    }

    private func thinkingBubbleText(for event: CompanionEvent) -> String {
        let fallback = "\(sourceLabel(for: event.source)) thinking..."
        guard let text = event.payload["text"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              shouldShowPromptTextInBubble(text) else {
            return fallback
        }
        return truncatedBubbleText(text)
    }

    private func shouldShowPromptTextInBubble(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count <= 140 else {
            return false
        }

        let lowercased = compact.lowercased()
        let catchupMarkers = [
            "agents.md",
            "<instructions>",
            "<environment_context>",
            "current date",
            "knowledge cutoff",
            "short project summary",
        ]
        guard !catchupMarkers.contains(where: { lowercased.contains($0) }) else {
            return false
        }

        return true
    }

    private func sourceLabel(for source: String) -> String {
        switch source {
        case "codex", "codex-cli", "codex-app", "codex-desktop":
            return "Codex"
        case "lmstudio-proxy":
            return "LM Studio"
        case "claude-code":
            return "Claude Code"
        case "opencode-cli":
            return "OpenCode"
        case "openpet-manual":
            return "OpenPet"
        default:
            return source
        }
    }

    private func sourceBadge(for event: CompanionEvent) -> OverlaySourceBadge {
        sourceBadge(forSource: event.source, modelId: event.modelId ?? event.payload["model"])
    }

    private func sourceBadge(forSource source: String, modelId: String?) -> OverlaySourceBadge {
        let label = sourceBadgeLabel(source: source, modelId: modelId)
        let sourceName = sourceLabel(for: source)
        let accessibleModel = modelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let accessibilityLabel: String
        if let accessibleModel, !accessibleModel.isEmpty {
            accessibilityLabel = "\(sourceName), \(accessibleModel)"
        } else {
            accessibilityLabel = sourceName
        }

        return OverlaySourceBadge(
            label: label,
            symbolName: sourceBadgeSymbol(for: source),
            accessibilityLabel: accessibilityLabel
        )
    }

    private func sourceBadgeLabel(source: String, modelId: String?) -> String {
        if let modelId {
            let compact = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !compact.isEmpty {
                return compactModelLabel(compact)
            }
        }

        switch source {
        case "codex", "codex-cli", "codex-app", "codex-desktop":
            return "Codex"
        case "lmstudio-proxy":
            return "LM"
        case "claude-code":
            return "Claude"
        case "opencode-cli":
            return "OpenCode"
        case "openpet-manual":
            return "OpenPet"
        default:
            return source
        }
    }

    private func compactModelLabel(_ modelId: String) -> String {
        let tail = modelId
            .split(whereSeparator: { $0 == "/" || $0 == ":" || $0 == "\\" })
            .last
            .map(String.init) ?? modelId
        let compact = tail
            .replacingOccurrences(of: "-instruct", with: "")
            .replacingOccurrences(of: "-chat", with: "")
            .replacingOccurrences(of: "_", with: " ")
        return truncatedText(compact, limit: 14)
    }

    private func sourceBadgeSymbol(for source: String) -> String {
        switch source {
        case "codex", "codex-cli", "codex-app", "codex-desktop":
            return "terminal.fill"
        case "lmstudio-proxy":
            return "cpu.fill"
        case "claude-code":
            return "curlybraces"
        case "opencode-cli":
            return "chevron.left.forwardslash.chevron.right"
        case "openpet-manual":
            return "pawprint.fill"
        default:
            return "sparkles"
        }
    }

    private func genericStreamBubble(for event: CompanionEvent) -> String? {
        if event.source == "lmstudio-proxy", event.payload["bytes"] != nil {
            return "LM Studio replying..."
        }
        return nil
    }

    private func activateRunningApplication(named appName: String) {
        let runningApp = NSWorkspace.shared.runningApplications.first { app in
            app.localizedName == appName
        }
        runningApp?.activate(options: [.activateAllWindows])
    }

    private func activateTerminalApplication() {
        activateRunningApplication(named: "Terminal")
    }

    private func updateActivityTitle(for event: CompanionEvent) {
        guard event.kind == .thinkingStarted,
              let text = event.payload["text"],
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        activityTitlesByKey[activityKey(for: event)] = truncatedTitleText(text)
    }

    private func currentActivityTitle(for event: CompanionEvent) -> String? {
        activityTitlesByKey[activityKey(for: event)]
    }

    private func clearActivityTitle(for event: CompanionEvent) {
        activityTitlesByKey.removeValue(forKey: activityKey(for: event))
    }

    private func updateOverlayActivityState(for event: CompanionEvent) {
        let key = activityKey(for: event)

        switch event.kind {
        case .sessionStarted, .thinkingStarted, .toolStarted, .streamStarted, .buildStarted, .codingStarted, .focusStarted:
            overlayActivitySourcesByKey[key] = event.source
            removeWaitingBubble()
            waitingBubbleSource = nil
        case .sessionEnded, .buildSucceeded, .buildFailed, .codingStopped, .focusBreak:
            overlayActivitySourcesByKey.removeValue(forKey: key)
        case .adapterDisconnected:
            let keysToRemove = overlayActivitySourcesByKey.compactMap { trackedKey, source in
                source == event.source ? trackedKey : nil
            }
            for trackedKey in keysToRemove {
                overlayActivitySourcesByKey.removeValue(forKey: trackedKey)
                activityTitlesByKey.removeValue(forKey: trackedKey)
            }
        default:
            break
        }
    }

    private var hasActiveOverlayActivity: Bool {
        !overlayActivitySourcesByKey.isEmpty
    }

    private func activityKey(for event: CompanionEvent) -> String {
        event.sessionId ?? event.source
    }

    private func computeFrameIndex(for state: PetState, semanticState: CompanionStateName, enteredAt: Date, at date: Date) -> Int {
        let elapsedMs = max(0, Int(date.timeIntervalSince(enteredAt) * 1000))
        let totalDuration = state.durationsMs.reduce(0, +)
        guard totalDuration > 0 else {
            return 0
        }

        let animationTime: Int
        if semanticState == .idle && state.loop {
            let cycleDuration = AppModel.idleAnimationRestDurationMs + totalDuration
            let cycleTime = elapsedMs % cycleDuration
            if cycleTime < AppModel.idleAnimationRestDurationMs {
                return 0
            }
            animationTime = min(cycleTime - AppModel.idleAnimationRestDurationMs, totalDuration - 1)
        } else {
            animationTime = state.loop ? elapsedMs % totalDuration : min(elapsedMs, totalDuration - 1)
        }

        var running = 0
        for (index, duration) in state.durationsMs.enumerated() {
            running += duration
            if animationTime < running {
                return index
            }
        }

        return max(0, state.frames.count - 1)
    }

    private func updateVisualOverride(forTransitionFrom oldState: CompanionStateName, to newState: CompanionStateName, at date: Date) {
        guard oldState != newState else {
            return
        }

        guard let holdDuration = minimumVisualHoldDuration(for: oldState) else {
            visualOverrideState = nil
            visualOverrideUntil = nil
            visualOverrideEnteredAt = nil
            return
        }

        let elapsed = date.timeIntervalSince(stateEnteredAt)
        guard elapsed < holdDuration else {
            visualOverrideState = nil
            visualOverrideUntil = nil
            visualOverrideEnteredAt = nil
            return
        }

        visualOverrideState = oldState
        visualOverrideUntil = stateEnteredAt.addingTimeInterval(holdDuration)
        visualOverrideEnteredAt = stateEnteredAt
    }

    private func minimumVisualHoldDuration(for state: CompanionStateName) -> TimeInterval? {
        guard let petState = selectedPet?.manifest.resolvedState(named: state) else {
            return nil
        }

        switch state {
        case .working, .success, .error:
            let totalDuration = Double(petState.durationsMs.reduce(0, +)) / 1000
            return max(0, totalDuration)
        default:
            return nil
        }
    }

    private func activeVisualOverride(at date: Date) -> CompanionStateName? {
        guard let visualOverrideState, let visualOverrideUntil, date < visualOverrideUntil else {
            return nil
        }
        return visualOverrideState
    }
}

struct PetRenderFrame {
    var petPack: PetPack
    var semanticState: CompanionStateName
    var state: PetState
    var frameIndex: Int
    var frame: PetFrame
}

enum DragFacingDirection: Sendable {
    case left
    case right
}
