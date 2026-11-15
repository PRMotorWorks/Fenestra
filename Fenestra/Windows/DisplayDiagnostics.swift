import AppKit
import ApplicationServices

/// Phase 5 diagnostics (only with `captionDebug`, same distributed notification as the other tests):
///   "TextEdit displays"  opens three TextEdit windows on the second display (plain, snapped left, maximized),
///                        then simulates unplugging that display by mirroring it onto the main display (session
///                        only), checks the windows were minimized (or moved, with that option off), stops the
///                        mirroring and checks every window is back with the same frame and state. Runs twice:
///                        with the user's settings, then with "Minimize windows when a monitor is disconnected" off.
///                        The display arrangement and the main display's mode are put back afterward.
/// Results go to the app log ("displaytest") and ~/Library/Logs/Fenestra-dragtest/displays.txt.
/// The screens flicker while mirroring switches on and off; the test windows are closed at the end.
@MainActor
enum DisplayDiagnostics {
    private static var lines: [String] = []
    private static func pause(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    private struct TestWin { let label: String; let pid: pid_t; let el: AXUIElement; let id: CGWindowID; var frame = CGRect.zero }

    static func run(appName: String) async {
        lines = []
        guard NSScreen.screens.count >= 2 else { Log.write("displaytest: needs two displays"); return }
        let mainID = Displays.id(NSScreen.screens[0])
        guard let second = NSScreen.screens.dropFirst().first else { return }
        let secondID = Displays.id(second)
        let secondOrigin = CGDisplayBounds(secondID).origin
        let mainMode = CGDisplayCopyDisplayMode(mainID)

        // TextEdit with three fresh windows.
        if NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) == nil,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init())
            await pause(1500)
        }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) else {
            Log.write("displaytest: \(appName) not running"); return
        }
        let pid = app.processIdentifier
        let before = Set(AX.windows(pid).compactMap(AX.windowID))
        for _ in 0..<3 { _ = AX.pressNewWindowMenuItem(pid: pid); await pause(500) }
        let fresh = AX.windows(pid).filter { w in
            (AX.attr(w, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole
                && AX.windowID(w).map { !before.contains($0) } == true
        }
        guard fresh.count >= 3 else { Log.write("displaytest: could not open 3 windows (\(fresh.count))"); return }
        var wins = zip(["plain", "snapped", "maximized"], fresh).map { TestWin(label: $0, pid: pid, el: $1, id: AX.windowID($1)!) }

        let settings = AppSettings.shared
        let userMinimize = settings.minimizeOnDisconnect
        for (round, minimize) in [userMinimize, !userMinimize].enumerated() {
            settings.minimizeOnDisconnect = minimize
            // Arrange on the second display.
            guard let s2 = NSScreen.screens.first(where: { Displays.id($0) == secondID }) else { break }
            let wa = CaptionController.workArea(screen: s2)
            CaptionController.setFrame(pid, wins[0].el, CGRect(x: wa.minX + 120, y: wa.minY + 90, width: 700, height: 460))
            WindowSnap.shared.snap(.init(pid: pid, element: wins[1].el, id: wins[1].id), zone: WindowSnap.Zones.left,
                                   workArea: wa, layout: nil, source: "test", assist: false)
            CaptionController.shared.maximize(pid: pid, element: wins[2].el, id: wins[2].id, workArea: wa)
            await pause(1500)                                   // DisplayMemory records 0.5 s after activity
            for i in wins.indices { wins[i].frame = AX.frame(wins[i].el) ?? .zero }
            lines.append("round \(round + 1) (minimize=\(minimize)): " +
                         wins.map { "\($0.label) \(CaptionController.describe($0.frame))" }.joined(separator: ", "))

            // "Unplug": mirror the second display onto the main one.
            var cfg: CGDisplayConfigRef?
            CGBeginDisplayConfiguration(&cfg)
            CGConfigureDisplayMirrorOfDisplay(cfg, secondID, mainID)
            let e1 = CGCompleteDisplayConfiguration(cfg, .forSession)
            let gone = await waitFor { NSScreen.screens.count == 1 }
            await pause(1500)
            lines.append("mirror on: err=\(e1.rawValue) displays=\(NSScreen.screens.count) \(gone ? "" : "(timeout)")")
            for w in wins {
                let m = AX.isMinimized(w.el)
                let onMain = AX.frame(w.el).map { Displays.screen(forAX: $0).map(Displays.id) == mainID } ?? false
                let ok = minimize ? m : (!m && onMain)
                lines.append("\(ok ? "PASS" : "FAIL") disconnected, \(w.label): minimized=\(m) onMain=\(onMain)")
            }

            // "Plug back in": stop mirroring, same place in the arrangement.
            CGBeginDisplayConfiguration(&cfg)
            CGConfigureDisplayMirrorOfDisplay(cfg, secondID, kCGNullDirectDisplay)
            CGConfigureDisplayOrigin(cfg, secondID, Int32(secondOrigin.x), Int32(secondOrigin.y))
            let e2 = CGCompleteDisplayConfiguration(cfg, .forSession)
            let back = await waitFor { NSScreen.screens.count >= 2 }
            await pause(2500)
            lines.append("mirror off: err=\(e2.rawValue) displays=\(NSScreen.screens.count) \(back ? "" : "(timeout)")")
            for w in wins {
                let f = AX.frame(w.el) ?? .zero
                let m = AX.isMinimized(w.el)
                var ok = !m && CaptionController.approx(f, w.frame)
                var state = ""
                if w.label == "snapped" {
                    let z = WindowSnap.shared.snappedZone(w.id, f)
                    ok = ok && z == WindowSnap.Zones.left; state = " zone=\(z.map { "\($0)" } ?? "none")"
                }
                if w.label == "maximized" {
                    let mx = CaptionController.shared.maximizedByUs(w.id, f)
                    ok = ok && mx; state = " maximizedByUs=\(mx)"
                }
                lines.append("\(ok ? "PASS" : "FAIL") reconnected, \(w.label): got \(CaptionController.describe(f)) " +
                             "expected \(CaptionController.describe(w.frame)) minimized=\(m)\(state)")
            }
            let bar = NSScreen.screens.first { Displays.id($0) == secondID }.map(TaskbarController.shared.hasTaskbar) ?? false
            lines.append("\(bar == settings.taskbarAllDisplays ? "PASS" : "FAIL") taskbar on second display: \(bar)")
        }
        settings.minimizeOnDisconnect = userMinimize

        // Put the main display's mode back if mirroring changed it (for example the refresh rate).
        if let want = mainMode, let now = CGDisplayCopyDisplayMode(mainID), now.refreshRate != want.refreshRate
            || now.width != want.width || now.height != want.height {
            var cfg: CGDisplayConfigRef?
            CGBeginDisplayConfiguration(&cfg)
            CGConfigureDisplayWithDisplayMode(cfg, mainID, want, nil)
            CGCompleteDisplayConfiguration(cfg, .forSession)
            lines.append("main display mode put back to \(want.width)x\(want.height) @ \(want.refreshRate) Hz")
        }
        let o = CGDisplayBounds(secondID).origin
        lines.append("\(o == secondOrigin ? "PASS" : "FAIL") arrangement: second display at \(o) (was \(secondOrigin))")
        for w in wins { AX.close(w.el) }
        finish()
    }

    private static func waitFor(_ cond: () -> Bool, timeout: Double = 6) async -> Bool {
        let t0 = Date()
        while Date().timeIntervalSince(t0) < timeout {
            if cond() { return true }
            await pause(100)
        }
        return false
    }

    private static func finish() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Fenestra-dragtest")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("displays.txt"), atomically: true, encoding: .utf8)
        Log.write("displaytest: " + lines.joined(separator: " | "))
        lines = []
    }
}
