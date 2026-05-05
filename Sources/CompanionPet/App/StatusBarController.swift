import AppKit

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let appModel: AppModel
    private let statusItem: NSStatusItem

    private lazy var menu = NSMenu()
    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let codexStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lmStudioStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let claudeCodeStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let launchClaudeCodeItem = NSMenuItem(title: "Launch Claude Code", action: #selector(launchClaudeCode), keyEquivalent: "")
    private let openCodeStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let launchOpenCodeItem = NSMenuItem(title: "Launch OpenCode", action: #selector(launchOpenCode), keyEquivalent: "")
    private let lockItem = NSMenuItem(title: "", action: #selector(toggleLock), keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "", action: #selector(togglePause), keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "Open Settings…", action: #selector(openSettings), keyEquivalent: ",")
    private let quitItem = NSMenuItem(title: "Quit Companion Pet", action: #selector(quit), keyEquivalent: "q")
    private let sizeMenuItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
    private let petMenuItem = NSMenuItem(title: "Pet", action: nil, keyEquivalent: "")

    init(appModel: AppModel) {
        self.appModel = appModel
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configure()
    }

    func refresh() {
        statusItem.button?.title = "✦"
        stateItem.title = "State: \(appModel.currentState.rawValue)"
        stateItem.isEnabled = false

        codexStatusItem.title = "Codex: \(healthLabel(for: appModel.adapterHealthByID["codex-cli"]))"
        codexStatusItem.isEnabled = false
        lmStudioStatusItem.title = "LM Studio: \(healthLabel(for: appModel.adapterHealthByID["lmstudio-proxy"]))"
        lmStudioStatusItem.isEnabled = false
        claudeCodeStatusItem.title = "Claude Code: \(healthLabel(for: appModel.adapterHealthByID["claude-code"]))"
        claudeCodeStatusItem.isEnabled = false
        launchClaudeCodeItem.isEnabled = appModel.adapterHealthByID["claude-code"]?.state == .connected
        openCodeStatusItem.title = "OpenCode: \(healthLabel(for: appModel.adapterHealthByID["opencode-cli"]))"
        openCodeStatusItem.isEnabled = false
        launchOpenCodeItem.isEnabled = appModel.adapterHealthByID["opencode-cli"]?.state == .connected

        lockItem.title = appModel.settings.isLocked ? "Unlock Overlay" : "Lock Overlay"
        pauseItem.title = appModel.settings.isPaused ? "Resume Animations" : "Pause Animations"

        refreshSizeMenu()
        refreshPetMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    private func configure() {
        statusItem.button?.title = "✦"
        statusItem.menu = menu

        menu.delegate = self
        menu.addItem(stateItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(codexStatusItem)
        menu.addItem(lmStudioStatusItem)
        menu.addItem(claudeCodeStatusItem)
        menu.addItem(openCodeStatusItem)
        menu.addItem(NSMenuItem.separator())
        launchClaudeCodeItem.target = self
        launchOpenCodeItem.target = self
        menu.addItem(launchClaudeCodeItem)
        menu.addItem(launchOpenCodeItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(lockItem)
        menu.addItem(pauseItem)
        menu.addItem(sizeMenuItem)
        menu.addItem(petMenuItem)
        menu.addItem(NSMenuItem.separator())
        settingsItem.target = self
        quitItem.target = self
        lockItem.target = self
        pauseItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(quitItem)

        refresh()
    }

    private func refreshSizeMenu() {
        let submenu = NSMenu()
        for preset in OverlayScalePreset.allCases {
            let item = NSMenuItem(
                title: preset.rawValue.capitalized,
                action: #selector(selectSize(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = preset.rawValue
            item.state = preset == appModel.settings.overlayScalePreset ? .on : .off
            submenu.addItem(item)
        }
        sizeMenuItem.submenu = submenu
    }

    private func refreshPetMenu() {
        let submenu = NSMenu()
        for pet in appModel.availablePets {
            let item = NSMenuItem(
                title: pet.manifest.displayName,
                action: #selector(selectPet(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = pet.id
            item.state = pet.id == appModel.settings.selectedPetID ? .on : .off
            submenu.addItem(item)
        }
        petMenuItem.submenu = submenu
    }

    private func healthLabel(for health: AdapterHealth?) -> String {
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

    @objc private func toggleLock() {
        appModel.toggleLock()
    }

    @objc private func togglePause() {
        appModel.togglePause()
    }

    @objc private func openSettings() {
        appModel.openSettings()
    }

    @objc private func quit() {
        appModel.quit()
    }

    @objc private func launchClaudeCode() {
        appModel.launchClaudeCode()
    }

    @objc private func launchOpenCode() {
        appModel.launchOpenCode()
    }

    @objc private func selectSize(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let preset = OverlayScalePreset(rawValue: rawValue) else {
            return
        }
        appModel.selectScale(preset)
    }

    @objc private func selectPet(_ sender: NSMenuItem) {
        guard let petID = sender.representedObject as? String else {
            return
        }
        appModel.selectPet(id: petID)
    }
}
