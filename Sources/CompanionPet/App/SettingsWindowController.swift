import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(appModel: AppModel) {
        let hostingController = NSHostingController(rootView: SettingsView(appModel: appModel))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "OpenPet Settings"
        window.setContentSize(NSSize(width: 620, height: 620))
        window.minSize = NSSize(width: 520, height: 440)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else {
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
