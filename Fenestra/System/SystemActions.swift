import AppKit
import ApplicationServices

/// Opening System Settings panes, system apps and synthesized shortcuts.
@MainActor
enum SystemActions {
    /// Pane IDs are the bundle IDs of the extensions in /System/Library/ExtensionKit/Extensions.
    /// Undocumented: Apple may rename them in a macOS update (the pane then opens at its top level).
    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openApp(_ path: String) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path),
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    /// Posts a key combination as if typed (needs Accessibility).
    static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static func openTaskManager() { openApp("/System/Applications/Utilities/Activity Monitor.app") }

    /// Opens the native Notification Center by pressing the clock menu extra through Accessibility.
    static func openNotificationCenter() {
        guard let cc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first
        else { return }
        let appEl = AX.app(cc.processIdentifier)
        guard let extras = AX.elementAttr(appEl, "AXExtrasMenuBar"),
              let items: [AXUIElement] = AX.attr(extras, kAXChildrenAttribute) else { return }
        for item in items {
            let ident: String? = AX.attr(item, kAXIdentifierAttribute)
            if ident == "com.apple.menuextra.clock" {
                AX.perform(item, kAXPressAction)
                return
            }
        }
    }
}
