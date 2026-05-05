import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayController: OverlayWindowController?
    private var statusBarController: StatusBarController?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let appModel = AppModel.shared
        let overlayController = OverlayWindowController(appModel: appModel)
        let statusBarController = StatusBarController(appModel: appModel)
        let settingsWindowController = SettingsWindowController(appModel: appModel)

        self.overlayController = overlayController
        self.statusBarController = statusBarController
        self.settingsWindowController = settingsWindowController

        appModel.attachOverlayController(overlayController)
        appModel.attachStatusBarController(statusBarController)
        appModel.attachSettingsWindowController(settingsWindowController)
        appModel.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task {
            await AppModel.shared.stop()
        }
    }
}
