import SwiftUI

struct SettingsView: View {
    @ObservedObject var appModel: AppModel
    @State private var codexSamplePrompt = "Reply with exactly OK."

    var body: some View {
        Form {
            Section("Companion") {
                Toggle("Pause animations", isOn: pausedBinding)
                Toggle("Lock overlay", isOn: lockedBinding)
                Toggle("Reduced motion", isOn: reducedMotionBinding)
                Toggle("Show speech bubbles", isOn: speechBubblesBinding)

                Picker("Overlay size", selection: sizeBinding) {
                    ForEach(OverlayScalePreset.allCases, id: \.self) { preset in
                        Text(preset.rawValue.capitalized).tag(preset)
                    }
                }

                Text("Last event: \(appModel.lastEventSummary)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Pet") {
                Picker("Selected pet", selection: selectedPetBinding) {
                    ForEach(appModel.availablePets, id: \.id) { pet in
                        Text(pet.manifest.displayName).tag(pet.id)
                    }
                }

                Group {
                    Text("OpenPet pet folder: \(appModel.customPetsDirectoryPath())")
                    Text("Codex pet folder: \(appModel.codexPetsDirectoryPath())")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

                HStack {
                    Button("Import Pet Folder") {
                        appModel.importPetFolder()
                    }

                    Button("Reveal Pets Folder") {
                        appModel.revealPetsDirectory()
                    }

                    Button("Refresh Pets") {
                        appModel.refreshPets()
                    }
                }
            }

            Section("Codex CLI") {
                Toggle("Enable Codex adapter", isOn: codexEnabledBinding)

                HStack {
                    TextField("Codex executable path", text: codexExecutableBinding)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        appModel.chooseCodexExecutable()
                    }
                    Button("Auto-detect") {
                        appModel.autoDetectCodex()
                    }
                }

                HStack {
                    TextField("Working directory", text: codexWorkingDirectoryBinding)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        appModel.chooseCodexWorkingDirectory()
                    }
                }

                TextField("Preferred model (optional)", text: codexModelBinding)
                    .textFieldStyle(.roundedBorder)

                Text("Status: \(healthText(for: appModel.adapterHealthByID["codex-cli"]))")
                    .foregroundStyle(.secondary)
                Text("Attach OpenPet to Codex by enabling the adapter, choosing the Codex CLI executable, and setting the working directory you want sample sessions to run in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                TextField("Sample prompt", text: $codexSamplePrompt)
                    .textFieldStyle(.roundedBorder)

                Button("Run sample Codex session") {
                    appModel.runCodexSample(prompt: codexSamplePrompt)
                }
            }

            Section("LM Studio") {
                Toggle("Enable LM Studio proxy", isOn: lmStudioEnabledBinding)
                TextField("Upstream base URL", text: lmStudioURLBinding)
                    .textFieldStyle(.roundedBorder)
                Stepper(value: lmStudioPortBinding, in: 1025...65535) {
                    Text("Listen port: \(appModel.settings.lmStudio.listenPort)")
                }

                Text("Proxy URL: \(appModel.proxyBaseURL())")
                    .foregroundStyle(.secondary)
                Text("Status: \(healthText(for: appModel.adapterHealthByID["lmstudio-proxy"]))")
                    .foregroundStyle(.secondary)
            }

            Section("Claude Code") {
                Toggle("Enable Claude Code adapter", isOn: claudeEnabledBinding)
                Toggle("Auto-configure hooks", isOn: claudeAutoConfigureHooksBinding)

                HStack {
                    TextField("Claude executable path", text: claudeExecutableBinding)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        appModel.chooseClaudeExecutable()
                    }
                    Button("Auto-detect") {
                        appModel.autoDetectClaude()
                    }
                }

                HStack {
                    TextField("Working directory", text: claudeWorkingDirectoryBinding)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        appModel.chooseClaudeWorkingDirectory()
                    }
                }

                Stepper(value: claudePortBinding, in: 1025...65535) {
                    Text("Hook listener port: \(appModel.settings.claudeCode.hookListenerPort)")
                }

                Text("Status: \(healthText(for: appModel.adapterHealthByID["claude-code"]))")
                    .foregroundStyle(.secondary)
                Text("Claude Code watches local session files and can auto-install local hooks for faster updates.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button("Launch Claude Code") {
                    appModel.launchClaudeCode()
                }
                .disabled(appModel.adapterHealthByID["claude-code"]?.state != .connected)
            }

            Section("OpenCode") {
                Toggle("Enable OpenCode adapter", isOn: openCodeEnabledBinding)

                HStack {
                    TextField("OpenCode executable path", text: openCodeExecutableBinding)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        appModel.chooseOpenCodeExecutable()
                    }
                    Button("Auto-detect") {
                        appModel.autoDetectOpenCode()
                    }
                }

                HStack {
                    TextField("Working directory", text: openCodeWorkingDirectoryBinding)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        appModel.chooseOpenCodeWorkingDirectory()
                    }
                }

                Text("Status: \(healthText(for: appModel.adapterHealthByID["opencode-cli"]))")
                    .foregroundStyle(.secondary)
                Text("OpenCode reads the latest exported session transcript from your local OpenCode data directory.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button("Launch OpenCode") {
                    appModel.launchOpenCode()
                }
                .disabled(appModel.adapterHealthByID["opencode-cli"]?.state != .connected)
            }

            Section("Activity Emotes") {
                Text("Use existing pet animations for lightweight local signals: git mood uses ambient, build/test uses working/success/error, coding rhythm uses working, and focus flow uses thinking/success.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Git Mood") {
                        appModel.showGitAwareMood()
                    }

                    Button("Build Started") {
                        appModel.showBuildStartedEmote()
                    }

                    Button("Build Passed") {
                        appModel.showBuildSucceededEmote()
                    }

                    Button("Build Failed") {
                        appModel.showBuildFailedEmote()
                    }
                }

                HStack {
                    Button("Start Coding") {
                        appModel.startManualCodingRhythm()
                    }

                    Button("Stop Coding") {
                        appModel.stopManualCodingRhythm()
                    }

                    Button("Start Focus") {
                        appModel.startFocusFlow()
                    }

                    Button("Take Break") {
                        appModel.takeFocusBreak()
                    }
                }
            }

            if !appModel.settingsMessage.isEmpty {
                Section("Status") {
                    Text(appModel.settingsMessage)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(18)
    }

    private func healthText(for health: AdapterHealth?) -> String {
        guard let health else {
            return "disabled"
        }
        switch health.state {
        case .connected:
            return "connected"
        case .degraded:
            return "degraded"
        case .disconnected:
            return "disconnected"
        }
    }

    private var pausedBinding: Binding<Bool> {
        Binding(
            get: { appModel.settings.isPaused },
            set: { appModel.settings.isPaused = $0 }
        )
    }

    private var lockedBinding: Binding<Bool> {
        Binding(
            get: { appModel.settings.isLocked },
            set: { appModel.settings.isLocked = $0 }
        )
    }

    private var reducedMotionBinding: Binding<Bool> {
        Binding(
            get: { appModel.settings.reducedMotion },
            set: { appModel.setReducedMotion($0) }
        )
    }

    private var speechBubblesBinding: Binding<Bool> {
        Binding(
            get: { appModel.settings.showsSpeechBubbles },
            set: { appModel.setSpeechBubblesEnabled($0) }
        )
    }

    private var sizeBinding: Binding<OverlayScalePreset> {
        Binding(
            get: { appModel.settings.overlayScalePreset },
            set: { appModel.selectScale($0) }
        )
    }

    private var selectedPetBinding: Binding<String> {
        Binding(
            get: { appModel.settings.selectedPetID },
            set: { appModel.selectPet(id: $0) }
        )
    }

    private var codexEnabledBinding: Binding<Bool> {
        Binding(
            get: { appModel.settings.codex.enabled },
            set: { appModel.setCodexEnabled($0) }
        )
    }

    private var codexExecutableBinding: Binding<String> {
        Binding(
            get: { appModel.settings.codex.executablePath },
            set: { appModel.updateCodexExecutablePath($0) }
        )
    }

    private var codexWorkingDirectoryBinding: Binding<String> {
        Binding(
            get: { appModel.settings.codex.workingDirectoryPath },
            set: { appModel.updateCodexWorkingDirectory($0) }
        )
    }

    private var codexModelBinding: Binding<String> {
        Binding(
            get: { appModel.settings.codex.preferredModel },
            set: { appModel.updateCodexPreferredModel($0) }
        )
    }

    private var lmStudioEnabledBinding: Binding<Bool> {
        Binding(
            get: { appModel.settings.lmStudio.enabled },
            set: { appModel.setLMStudioEnabled($0) }
        )
    }

    private var lmStudioURLBinding: Binding<String> {
        Binding(
            get: { appModel.settings.lmStudio.upstreamBaseURL },
            set: { appModel.updateLMStudioEndpoint($0) }
        )
    }

    private var lmStudioPortBinding: Binding<Int> {
        Binding(
            get: { appModel.settings.lmStudio.listenPort },
            set: { appModel.updateLMStudioPort($0) }
        )
    }

    private var claudeEnabledBinding: Binding<Bool> {
        Binding(
            get: { appModel.settings.claudeCode.enabled },
            set: { appModel.setClaudeCodeEnabled($0) }
        )
    }

    private var claudeExecutableBinding: Binding<String> {
        Binding(
            get: { appModel.settings.claudeCode.executablePath },
            set: { appModel.updateClaudeCodeExecutablePath($0) }
        )
    }

    private var claudeWorkingDirectoryBinding: Binding<String> {
        Binding(
            get: { appModel.settings.claudeCode.workingDirectoryPath },
            set: { appModel.updateClaudeCodeWorkingDirectory($0) }
        )
    }

    private var claudePortBinding: Binding<Int> {
        Binding(
            get: { appModel.settings.claudeCode.hookListenerPort },
            set: { appModel.updateClaudeCodePort($0) }
        )
    }

    private var claudeAutoConfigureHooksBinding: Binding<Bool> {
        Binding(
            get: { appModel.settings.claudeCode.autoConfigureHooks },
            set: { appModel.settings.claudeCode.autoConfigureHooks = $0 }
        )
    }

    private var openCodeEnabledBinding: Binding<Bool> {
        Binding(
            get: { appModel.settings.openCode.enabled },
            set: { appModel.setOpenCodeEnabled($0) }
        )
    }

    private var openCodeExecutableBinding: Binding<String> {
        Binding(
            get: { appModel.settings.openCode.executablePath },
            set: { appModel.updateOpenCodeExecutablePath($0) }
        )
    }

    private var openCodeWorkingDirectoryBinding: Binding<String> {
        Binding(
            get: { appModel.settings.openCode.workingDirectoryPath },
            set: { appModel.updateOpenCodeWorkingDirectory($0) }
        )
    }
}
