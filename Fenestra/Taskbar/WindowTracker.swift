import AppKit
import ApplicationServices

/// Live list of each app's windows, for "Combine taskbar buttons: Never" (one button per window, with label).
/// Rebuilt per app only when that app reports a window event.
@MainActor
final class WindowTracker: ObservableObject {
    static let shared = WindowTracker()

    struct Win: Identifiable, Equatable {
        let id: String            // "pid:windowID"
        let pid: pid_t
        let windowID: CGWindowID?
        let title: String
        let minimized: Bool
        let element: AXUIElement
        var display: CGDirectDisplayID = 0       // display holding the window's center (Phase 5)
        static func == (a: Win, b: Win) -> Bool {
            a.id == b.id && a.title == b.title && a.minimized == b.minimized && a.display == b.display
        }
    }

    @Published private(set) var windows: [pid_t: [Win]] = [:]
    @Published private(set) var focused: [pid_t: CGWindowID] = [:]
    private var started = false
    private var dirty: Set<pid_t> = []
    private var scheduled = false

    func start() {
        guard !started, WindowEvents.shared.isRunning else { return }
        started = true
        WindowEvents.shared.subscribe { kind, pid, _ in
            if kind == .moved || kind == .resized {
                // Only per-display taskbar buttons care where a window is.
                if WindowTracker.shared.needsDisplays { WindowTracker.shared.markMoved(pid) }
                return
            }
            WindowTracker.shared.markDirty(pid)
        }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { n in
                guard let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                else { return }
                MainActor.assumeIsolated { WindowTracker.shared.markDirty(pid) }
            }
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            refresh(app.processIdentifier)
        }
    }

    /// Phase 5: taskbars on several displays that show only their own windows' apps.
    var needsDisplays: Bool {
        let s = AppSettings.shared
        return s.taskbarAllDisplays && s.taskbarAppsOn != .all && TaskbarController.shared.bars.count > 1
    }

    /// Display setup or the setting changed: re-read every app once so each window's display is current.
    func displaysNeededChanged() {
        guard started else { return }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            markDirty(app.processIdentifier)
        }
    }

    private var moved: Set<pid_t> = []
    private var movedScheduled = false

    /// Window moves arrive in bursts while dragging: re-read once the mouse is released.
    private func markMoved(_ pid: pid_t) {
        moved.insert(pid)
        guard !movedScheduled else { return }
        movedScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                let t = WindowTracker.shared
                t.movedScheduled = false
                if NSEvent.pressedMouseButtons != 0, let any = t.moved.first { t.markMoved(any); return }
                let pids = t.moved
                t.moved = []
                pids.forEach(t.markDirty)
            }
        }
    }

    func windows(for item: AppItem) -> [Win] { item.pids.flatMap { windows[$0] ?? [] } }

    func markDirty(_ pid: pid_t) {
        dirty.insert(pid)
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            MainActor.assumeIsolated {
                let t = WindowTracker.shared
                t.scheduled = false
                let pids = t.dirty
                t.dirty = []
                pids.forEach(t.refresh)
            }
        }
    }

    private func refresh(_ pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            windows[pid] = nil; focused[pid] = nil; return
        }
        let list = AX.windows(pid).compactMap { w -> Win? in
            guard let f = AX.frame(w), f.width > 60, f.height > 40 else { return nil }
            let id = AX.windowID(w)
            return Win(id: "\(pid):\(id.map(String.init) ?? "\(CFHash(w))")", pid: pid, windowID: id,
                       title: AX.title(w), minimized: AX.isMinimized(w), element: w,
                       display: Displays.screen(forAX: f).map(Displays.id) ?? 0)
        }
        if windows[pid] != list { windows[pid] = list }
        let f = AX.focusedWindow(pid).flatMap(AX.windowID)
        if focused[pid] != f { focused[pid] = f }
    }
}
