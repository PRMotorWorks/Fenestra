import AppKit
import ApplicationServices

/// One AXObserver per app, shared by everything that needs window events
/// (work-area fix, per-window taskbar buttons, full-screen detection). Event-driven: no polling.
@MainActor
final class WindowEvents {
    static let shared = WindowEvents()

    enum Kind { case created, destroyed, resized, moved, minimized, deminimized, focused, title }
    typealias Handler = (Kind, pid_t, AXUIElement) -> Void

    private var observers: [pid_t: AXObserver] = [:]
    private var handlers: [Handler] = []
    private var watchedWindows: Set<CFHashCode> = []
    private var started = false

    func subscribe(_ h: @escaping Handler) { handlers.append(h) }

    func start() {
        guard !started, AXIsProcessTrusted() else { return }
        started = true
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observe(app.processIdentifier)
        }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular else { return }
            let pid = app.processIdentifier
            for delay in [0.5, 2.0] {      // apps build their AX tree a moment after launch
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated { WindowEvents.shared.observe(pid) }
                }
            }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
            guard let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            else { return }
            MainActor.assumeIsolated { WindowEvents.shared.unobserve(pid) }
        }
    }

    var isRunning: Bool { started }

    private func observe(_ pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        if observers[pid] == nil {
            var obs: AXObserver?
            let cb: AXObserverCallback = { _, element, note, _ in
                let n = note as String
                MainActor.assumeIsolated { WindowEvents.shared.dispatch(n, element) }
            }
            guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return }
            let appEl = AX.app(pid)
            for n in [kAXWindowCreatedNotification, kAXWindowResizedNotification, kAXWindowMovedNotification,
                      kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                      kAXFocusedWindowChangedNotification, kAXTitleChangedNotification] {
                AXObserverAddNotification(obs, appEl, n as CFString, nil)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            observers[pid] = obs
        }
        for w in AX.windows(pid) { watchDestroy(w, pid) }
    }

    private func watchDestroy(_ w: AXUIElement, _ pid: pid_t) {
        guard let obs = observers[pid] else { return }
        let h = CFHash(w)
        guard !watchedWindows.contains(h) else { return }
        watchedWindows.insert(h)
        AXObserverAddNotification(obs, w, kAXUIElementDestroyedNotification as CFString, nil)
    }

    private func unobserve(_ pid: pid_t) {
        if let obs = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        for h in handlers { h(.destroyed, pid, AX.app(pid)) }
    }

    private func dispatch(_ note: String, _ el: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        let kind: Kind
        switch note {
        case kAXWindowCreatedNotification: kind = .created; watchDestroy(el, pid)
        case kAXUIElementDestroyedNotification: kind = .destroyed; watchedWindows.remove(CFHash(el))
        case kAXWindowResizedNotification: kind = .resized
        case kAXWindowMovedNotification: kind = .moved
        case kAXWindowMiniaturizedNotification: kind = .minimized
        case kAXWindowDeminiaturizedNotification: kind = .deminimized
        case kAXFocusedWindowChangedNotification: kind = .focused
        default: kind = .title
        }
        for h in handlers { h(kind, pid, el) }
    }
}
