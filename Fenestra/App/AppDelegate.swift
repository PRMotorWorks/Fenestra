import AppKit
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One shell at a time.
        if Lifecycle.anotherInstanceIsRunning() { exit(0) }

        // Opened from Finder: hand over to the login agent so the watchdog supervises us.
        if !Lifecycle.launchedFromAgent, Lifecycle.handOffToAgentIfInstalled() { exit(0) }

        Lifecycle.markRunning()
        Lifecycle.installSignalHandlers()
        Lifecycle.applyDefaults()

        AX.configureTimeouts()
        MenuBarDiagnostics.install()
        Log.write("launch: accessibility=\(AXIsProcessTrusted()) screenRecording=\(CGPreflightScreenCaptureAccess()) " +
                  "location=\(Permissions.shared.location.rawValue)")
        TaskbarController.shared.start()
        SystemStatus.shared.start()
        StartController.shared.prepare()
        ClipboardHistory.shared.start()
        AirDrop.resumeExpiry()
        AppDelegate.startAccessibilityFeatures()
        if !AXIsProcessTrusted() {
            // Pick the permission up as soon as it's granted (cheap check, stops once granted).
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { t in
                MainActor.assumeIsolated {
                    if AXIsProcessTrusted() { t.invalidate(); Permissions.shared.refresh() }
                }
            }
        }
        if !Permissions.shared.allEssentialGranted || !UserDefaults.standard.bool(forKey: "onboardingShown") {
            UserDefaults.standard.set(true, forKey: "onboardingShown")
            PermissionsWindow.show()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Lifecycle.sessionEnding = true }
        }
    }

    /// Everything that needs Accessibility; called at launch and again when the permission is granted.
    static func startAccessibilityFeatures() {
        guard AXIsProcessTrusted() else { return }
        WindowEvents.shared.start()
        WorkAreaEnforcer.shared.start()
        CaptionController.shared.start()
        WindowTracker.shared.start()
        NotificationStore.shared.start()
        DockBadges.shared.start()
        WinKey.shared.start()
        WindowList.startTracking()
        WindowSnap.shared.start()
        DragSnap.shared.start()
        HotKeys.shared.start()
        DisplayMemory.shared.start()
        MenuExtras.shared.start()
        WindowTracker.shared.displaysNeededChanged()
        TaskbarController.shared.checkFullscreen()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        Lifecycle.markStopped()
    }
}
