import AppKit
import ApplicationServices

/// What happens when you click, middle-click or right-click a taskbar button.
@MainActor
enum TaskbarActions {
    struct WindowRef: Identifiable {
        let id: Int
        let pid: pid_t
        let element: AXUIElement
        let windowID: CGWindowID?
        let title: String
        let minimized: Bool
    }

    /// Phase 5: the windows one taskbar acts on. A taskbar that shows only the apps with a window on its display
    /// ("Taskbar where window is open") also clicks, previews and counts only those windows. The main taskbar
    /// takes windows on displays that have no taskbar of their own.
    struct Scope: Equatable {
        let display: CGDirectDisplayID
        let isMain: Bool
        @MainActor func contains(_ d: CGDirectDisplayID) -> Bool {
            d == display || (isMain && (d == 0 || !TaskbarController.shared.hasTaskbar(display: d)))
        }
    }

    static func windows(of item: AppItem, scope: Scope? = nil) -> [WindowRef] {
        var out: [WindowRef] = []
        for pid in item.pids {
            for w in AX.windows(pid) {
                // Skip invisible helper windows some apps (Electron, browsers) keep around.
                guard let f = AX.frame(w), f.width > 60, f.height > 40 else { continue }
                if let scope, !scope.contains(Displays.screen(forAX: f).map(Displays.id) ?? 0) { continue }
                out.append(WindowRef(id: out.count, pid: pid, element: w, windowID: AX.windowID(w),
                                     title: AX.title(w), minimized: AX.isMinimized(w)))
            }
        }
        return out
    }

    /// Windows 11 click behavior:
    ///  - not running: launch
    ///  - several windows: show the thumbnails to pick one
    ///  - the app is in front and its one window is visible: minimize it
    ///  - otherwise: bring it forward (restoring it if minimized or hidden)
    static func click(_ item: AppItem, anchor: NSRect, scope: Scope? = nil) {
        guard item.isRunning else { Log.write("click \(item.name): launch"); launch(item); return }
        ThumbnailController.shared.dismiss()
        let apps = TaskbarModel.shared.runningApps(for: item)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let isFront = item.pids.contains { $0 == front } && !(apps.first?.isHidden ?? false)
        let ax = AXIsProcessTrusted()

        guard ax else {
            // Without Accessibility: hide/unhide the app (closest public equivalent of minimize/restore).
            Log.write("click \(item.name): no Accessibility, front=\(isFront)")
            if isFront { apps.first?.hide() }
            else { apps.first?.unhide(); activateViaLaunchServices(item) }
            return
        }
        let wins = windows(of: item, scope: scope)
        let visible = wins.filter { !$0.minimized }
        Log.write("click \(item.name): front=\(isFront) windows=\(wins.count) visible=\(visible.count)"
                  + (scope.map { " display=\($0.display)" } ?? ""))

        // Scoped: "in front" means the focused window is one of this taskbar's (else the click brings them here).
        let frontHere = scope == nil || visible.contains {
            $0.windowID != nil && $0.windowID == AX.focusedWindow($0.pid).flatMap(AX.windowID)
        }
        if isFront && frontHere && !visible.isEmpty {
            // App in front: minimize its windows to the taskbar.
            visible.forEach { AX.setMinimized($0.element, true) }
            return
        }
        if !wins.isEmpty && visible.isEmpty {
            // Everything minimized: restore all of them (pick a single one from the hover thumbnails).
            apps.first?.unhide()
            wins.forEach { AX.setMinimized($0.element, false) }
            AX.focus(pid: wins[0].pid, window: wins[0].element)
            return
        }
        if scope != nil, wins.isEmpty, !windows(of: item).isEmpty {
            // Pinned here with every window on another taskbar's display: Windows starts a new one here.
            Log.write("click \(item.name): no window on this taskbar, new window")
            newWindow(item)
            return
        }
        guard let w = visible.first ?? wins.first else {
            // Running with no windows: unhide, or ask the app to reopen (usually creates a new window).
            if let a = apps.first, a.isHidden { a.unhide(); activateViaLaunchServices(item) }
            else { activateViaLaunchServices(item) }
            return
        }
        apps.first?.unhide()
        AX.focus(pid: w.pid, window: w.element)
    }

    /// Click on a per-window button ("Combine taskbar buttons: Never").
    static func clickWindow(_ w: WindowTracker.Win, item: AppItem) {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focused = WindowTracker.shared.focused[w.pid]
        if front == w.pid, focused == w.windowID, !w.minimized {
            AX.setMinimized(w.element, true)
        } else {
            NSRunningApplication(processIdentifier: w.pid)?.unhide()
            AX.focus(pid: w.pid, window: w.element)
        }
    }

    /// Brings a running app forward the way the Dock does (works under macOS 14+ cooperative activation).
    static func activateViaLaunchServices(_ item: AppItem) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: item.url, configuration: cfg)
    }

    static func launch(_ item: AppItem) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: item.url, configuration: cfg)
    }

    /// Middle-click: Windows opens a new instance. On a Mac that means a new window
    /// (a second copy of the app process breaks most Mac apps).
    static func newWindow(_ item: AppItem) {
        guard let pid = item.pids.first else { launch(item); return }
        AX.focus(pid: pid, window: nil)
        if Permissions.shared.accessibility, AX.pressNewWindowMenuItem(pid: pid) { return }
        // Fallback: send Command-N straight to the app.
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 45, keyDown: down)   // N
            e?.flags = .maskCommand
            e?.postToPid(pid)
        }
    }

    /// Closing all windows ends the app, as on Windows (Finder is never quit).
    /// Scoped (a taskbar showing only its display's windows): closes those windows, and quits the app only
    /// when they were all of its windows.
    static func closeAll(_ item: AppItem, scope: Scope? = nil) {
        if let scope {
            let here = windows(of: item, scope: scope)
            if here.count < windows(of: item).count || item.id == "com.apple.finder" {
                here.forEach { AX.close($0.element) }
                return
            }
        }
        // Finder never quits; with "quit on last window" off, apps keep running like on a Mac.
        if item.id == "com.apple.finder" || !AppSettings.shared.quitOnLastWindow {
            windows(of: item).forEach { AX.close($0.element) }
            return
        }
        TaskbarModel.shared.runningApps(for: item).forEach { $0.terminate() }
    }

    /// "End task" (Windows 11: right-click a taskbar app; Settings > System > For developers). Force quits every
    /// process of the app, like Force Quit in the Apple menu. Unsaved work is lost. Never offered for Finder.
    static func endTask(_ item: AppItem) {
        guard item.id != "com.apple.finder" else { return }
        let apps = TaskbarModel.shared.runningApps(for: item)
        Log.write("end task \(item.name): \(apps.map(\.processIdentifier))")
        for app in apps where !app.forceTerminate() {
            Log.write("end task \(item.name): pid \(app.processIdentifier) refused")
        }
    }

    // MARK: Show desktop, one display (Phase 5: each taskbar's far-right corner clears only its own display)

    private struct Parked { let pid: pid_t; let element: AXUIElement; let id: CGWindowID }
    /// Windows the corner of each display's taskbar minimized, and the window that was in front there.
    private static var parked: [CGDirectDisplayID: [Parked]] = [:]
    private static var frontParked: [CGDirectDisplayID: Parked] = [:]
    private static var watchingRestores = false

    /// First click minimizes every window on that display; the second puts them back and refocuses the window
    /// that was in front. Restoring one of them yourself ends it (the next click clears the display again),
    /// as on Windows. Apps keep running and their windows on other displays stay put, so this minimizes
    /// windows instead of hiding apps (Control+Option+D, Windows key + D, still clears all displays).
    static func toggleShowDesktop(display: CGDirectDisplayID) {
        if let list = parked.removeValue(forKey: display) {
            let front = frontParked.removeValue(forKey: display)
            for p in list where AX.isMinimized(p.element) { AX.setMinimized(p.element, false) }
            if let f = front { AX.focus(pid: f.pid, window: f.element) }
            Log.write("show desktop: \(list.count) windows back on display \(display)")
            return
        }
        if !watchingRestores, WindowEvents.shared.isRunning {
            watchingRestores = true
            WindowEvents.shared.subscribe { kind, _, el in
                guard kind == .deminimized, !parked.isEmpty, let id = AX.windowID(el) else { return }
                for (d, list) in parked where list.contains(where: { $0.id == id }) {
                    parked[d] = nil
                    frontParked[d] = nil
                }
            }
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var found: [Parked] = []
        var front: Parked?
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isHidden && app.processIdentifier != me {
            let pid = app.processIdentifier
            let focused = pid == frontPid ? AX.focusedWindow(pid).flatMap(AX.windowID) : nil
            for w in AX.windows(pid) {
                guard (AX.attr(w, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole, !AX.isMinimized(w),
                      let f = AX.frame(w), f.width > 60, f.height > 40, let id = AX.windowID(w),
                      Displays.screen(forAX: f).map(Displays.id) == display else { continue }
                let p = Parked(pid: pid, element: w, id: id)
                found.append(p)
                if id == focused { front = p }
            }
        }
        guard !found.isEmpty else { return }
        // Elements are all looked up before minimizing: an app busy animating answers Accessibility slowly.
        for p in found { AX.setMinimized(p.element, true) }
        parked[display] = found
        frontParked[display] = front
        Log.write("show desktop: \(found.count) windows minimized on display \(display)")
    }

    // MARK: Show desktop, all displays (Control+Option+D, Start > Desktop)

    private static var hiddenByShowDesktop: [pid_t] = []
    private static var frontBeforeShowDesktop: pid_t?

    /// Hides every app (instant, no animation), and puts them back on the second click.
    static func toggleShowDesktop() {
        if !hiddenByShowDesktop.isEmpty {
            for pid in hiddenByShowDesktop { NSRunningApplication(processIdentifier: pid)?.unhide() }
            if let f = frontBeforeShowDesktop { AX.focus(pid: f, window: nil) }
            hiddenByShowDesktop = []
            return
        }
        frontBeforeShowDesktop = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let me = ProcessInfo.processInfo.processIdentifier
        // Hide Finder last: it owns the desktop, so macOS hands focus to it once everything else is hidden.
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != me }
            .sorted { ($0.bundleIdentifier == "com.apple.finder" ? 1 : 0) < ($1.bundleIdentifier == "com.apple.finder" ? 1 : 0) }
        for app in apps where app.hide() { hiddenByShowDesktop.append(app.processIdentifier) }
    }

    /// Any app brought forward by you ends "show desktop" mode, as on Windows.
    static func resetShowDesktopIfNeeded(activated pid: pid_t) {
        if !hiddenByShowDesktop.isEmpty,
           NSRunningApplication(processIdentifier: pid)?.bundleIdentifier != "com.apple.finder" {
            hiddenByShowDesktop = []
        }
    }
}
