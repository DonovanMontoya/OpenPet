import AppKit
import Foundation

@MainActor
enum OverlayLaunchResolver {
    @discardableResult
    static func activate(binding: HostBinding?, fallback: () -> Void) -> Bool {
        guard let binding else {
            fallback()
            return false
        }

        guard let activatedApp = resolvedApp(for: binding) else {
            fallback()
            return false
        }

        activate(activatedApp)
        attemptTabFocus(bundleID: activatedApp.bundleIdentifier, tty: binding.tty)
        return true
    }

    // MARK: - Private helpers

    private static func resolvedApp(for binding: HostBinding) -> NSRunningApplication? {
        if let pid = binding.hostPID,
           let app = NSRunningApplication(processIdentifier: pid),
           !app.isTerminated,
           app.activationPolicy != .prohibited {
            return app
        }

        if let bundleID = binding.hostBundleID,
           let app = NSWorkspace.shared.runningApplications.first(where: {
               $0.bundleIdentifier == bundleID &&
               !$0.isTerminated &&
               $0.activationPolicy != .prohibited
           }) {
            return app
        }

        return nil
    }

    private static func activate(_ app: NSRunningApplication) {
        app.unhide()
        app.activate(options: [.activateAllWindows])
        forceActivateWithAppleScript(app)
    }

    private static func forceActivateWithAppleScript(_ app: NSRunningApplication) {
        if let bundleID = app.bundleIdentifier, !bundleID.isEmpty {
            runAppleScript("""
            tell application id "\(escapedAppleScriptInlineString(bundleID))" to activate
            """)
            return
        }

        if let name = app.localizedName, !name.isEmpty {
            runAppleScript("""
            tell application "\(escapedAppleScriptInlineString(name))" to activate
            """)
        }
    }

    private static func attemptTabFocus(bundleID: String?, tty: String?) {
        guard let bundleID, let tty, !tty.isEmpty else { return }

        let script: String
        switch bundleID {
        case "com.apple.Terminal":
            script = terminalScript(tty: tty)
        case "com.googlecode.iterm2":
            script = iterm2Script(tty: tty)
        default:
            return
        }

        runAppleScript(script)
    }

    private static func terminalScript(tty: String) -> String {
        let escapedTTY = escapedAppleScriptString(tty)
        return """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if (tty of t) is \(escapedTTY) then
                        set selected of t to true
                        set frontmost of w to true
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
    }

    private static func iterm2Script(tty: String) -> String {
        let escapedTTY = escapedAppleScriptString(tty)
        return """
        tell application "iTerm"
            activate
            repeat with w in windows
                repeat with tb in tabs of w
                    repeat with s in sessions of tb
                        if (tty of s) is \(escapedTTY) then
                            select tb
                            select s
                            tell w to set index to 1
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    }

    private static func escapedAppleScriptString(_ s: String) -> String {
        // Wrap in quotes and escape internal backslashes and quotes.
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func escapedAppleScriptInlineString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(_ source: String) {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        script?.executeAndReturnError(&error)
        if let error {
            print("[OverlayLaunchResolver] AppleScript error: \(error)")
        }
    }
}
