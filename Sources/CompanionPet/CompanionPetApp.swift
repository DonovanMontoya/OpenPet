import SwiftUI

@main
struct CompanionPetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel.shared

    var body: some Scene {
        Settings {
            SettingsView(appModel: appModel)
                .frame(minWidth: 520, minHeight: 440)
        }
    }
}
