import AppKit

/// Keeps the auto-hidden macOS menu bar from sliding in at the top edge (user asked, 2026-11-15).
///
/// PRIVATE: SkyLight's `SLSSetMenuBarInsetAndAlpha(cid, 0, 1, alpha)` (what yabai's `menubar_opacity` uses). At
/// alpha 0 the menu bar is invisible and lets clicks through, so the slide-in at the top edge shows nothing.
/// WindowServer puts the alpha back when Mission Control runs (user test 2026-11-15), so it is set again after
/// Mission Control (the Dock's AXExpose notifications), Space changes, app switches, wake and display changes.
/// Only while `_HIHideMenuBar` is on: a shown menu bar at alpha 0 would be an empty strip.
/// Quit, crash (restore.sh runs `Fenestra --menubar-reset`) and switching the setting off put alpha 1 back.
@MainActor
final class MenuBarBlocker {
    static let shared = MenuBarBlocker()

    private typealias MainConn = @convention(c) () -> Int32
    private typealias SetAlpha = @convention(c) (Int32, Double, Double, Float) -> Int32
    private nonisolated static let fns: (MainConn, SetAlpha)? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let c = dlsym(h, "SLSMainConnectionID"), let s = dlsym(h, "SLSSetMenuBarInsetAndAlpha") else { return nil }
        return (unsafeBitCast(c, to: MainConn.self), unsafeBitCast(s, to: SetAlpha.self))
    }()

    /// Sets the menu bar's alpha. Safe from any thread and before NSApplication exists (`--menubar-reset`).
    @discardableResult
    nonisolated static func setAlpha(_ alpha: Float) -> Bool {
        guard let (conn, set) = fns else { return false }
        return set(conn(), 0, 1, alpha) == 0
    }

    private var started = false
    private var blocking = false
    private var dockObserver: AXObserver?

    /// Whether the reveal should be blocked right now.
    private var wanted: Bool {
        AppSettings.shared.hideMenuBar && AppSettings.shared.menuBarNoReveal && CaptionController.menuBarHidden
    }

    /// Called after the menu bar preference is (re)applied and when the setting changes.
    func update(reason: String) {
        start()
        if wanted {
            apply(reason: reason)
        } else if blocking {
            blocking = false
            let ok = MenuBarBlocker.setAlpha(1)
            Log.write("menubar: top edge reveal allowed again (\(reason), \(ok ? "ok" : "failed"))")
        }
    }

    private func apply(reason: String, log: Bool = true) {
        guard wanted else { return }
        let ok = MenuBarBlocker.setAlpha(0)
        if log || !blocking { Log.write("menubar: top edge reveal blocked (\(reason), \(ok ? "ok" : "SkyLight call missing or failed"))") }
        blocking = ok
    }

    /// Mission Control's own reset can land after its exit notification: set it again shortly after too.
    private func reapply(reason: String, log: Bool = true) {
        guard wanted else { return }
        apply(reason: reason, log: log)
        for delay in [0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { MenuBarBlocker.shared.apply(reason: reason, log: false) }
            }
        }
    }

    /// Called when Fenestra quits normally.
    func stop() {
        guard blocking else { return }
        blocking = false
        MenuBarBlocker.setAlpha(1)
    }

    private func start() {
        guard !started else { return }
        started = true
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MenuBarBlocker.shared.reapply(reason: "space changed") }
        }
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MenuBarBlocker.shared.apply(reason: "app switch", log: false) }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MenuBarBlocker.shared.reapply(reason: "wake") }
        }
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.dock" else { return }
            // Dock restarted (apply-defaults does `killall Dock`): watch the new one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    MenuBarBlocker.shared.watchDock()
                    MenuBarBlocker.shared.reapply(reason: "Dock restarted")
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { MenuBarBlocker.shared.reapply(reason: "displays changed") }
        }
        watchDock()
    }

    /// Mission Control, App Exposé and Show Desktop are run by the Dock, which posts these on its app element.
    private func watchDock() {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return }
        if let old = dockObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode)
        }
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, note, _ in
            let name = note as String
            MainActor.assumeIsolated { MenuBarBlocker.shared.reapply(reason: name) }
        }
        guard AXObserverCreate(dock.processIdentifier, cb, &obs) == .success, let obs else { return }
        let appEl = AX.app(dock.processIdentifier)
        var added = 0
        for n in ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop", "AXExposeExit"] {
            if AXObserverAddNotification(obs, appEl, n as CFString, nil) == .success { added += 1 }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        dockObserver = obs
        Log.write("menubar: watching Mission Control on Dock pid \(dock.processIdentifier) (\(added)/4 notifications)")
    }
}
