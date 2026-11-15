import AppKit
import ApplicationServices
import ScreenCaptureKit

/// One window as Alt+Tab, Task View and Snap Assist show it.
struct SwitchWindow: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let element: AXUIElement
    let title: String
    let appName: String
    let frame: CGRect          // AX coordinates (top-left origin)
    let minimized: Bool
    let onScreen: Bool
    var aspect: CGFloat { frame.height > 0 ? frame.width / frame.height : 1.6 }
    var label: String { title.isEmpty ? appName : title }
}

/// The windows you can switch to, most recently used first (Phase 4).
/// Built from `WindowTracker` (already kept current by window events) plus one window-list read for the
/// on-screen stacking order, so opening Alt+Tab costs no Accessibility round trips for visible windows.
@MainActor
enum WindowList {
    /// Last time each window had focus (window events and app switches): orders windows that are not on
    /// screen (minimized, hidden apps), which have no stacking order.
    private static var lastFocus: [CGWindowID: Date] = [:]
    private static var icons: [pid_t: NSImage] = [:]
    private static var started = false

    static func startTracking() {
        guard !started, WindowEvents.shared.isRunning else { return }
        started = true
        WindowEvents.shared.subscribe { kind, pid, el in
            guard kind == .focused else { return }
            let w = AX.windowID(el) ?? AX.focusedWindow(pid).flatMap(AX.windowID)
            if let w { WindowList.touch(w) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { n in
            guard let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            else { return }
            MainActor.assumeIsolated {
                if let w = AX.focusedWindow(pid).flatMap(AX.windowID) { WindowList.touch(w) }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { n in
            guard let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            else { return }
            MainActor.assumeIsolated { WindowList.icons[pid] = nil }
        }
    }

    static func touch(_ id: CGWindowID) {
        lastFocus[id] = Date()
        if lastFocus.count > 300 {        // forget the oldest half (closed windows)
            let keep = lastFocus.sorted { $0.value > $1.value }.prefix(150)
            lastFocus = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    static func icon(_ pid: pid_t) -> NSImage {
        if let i = icons[pid] { return i }
        let i = NSRunningApplication(processIdentifier: pid)?.icon ?? NSWorkspace.shared.icon(for: .application)
        icons[pid] = i
        return i
    }

    /// All switchable windows: on-screen ones in stacking order (front first), then minimized windows and
    /// windows of hidden apps by last use. Windows on other Spaces (full-screen apps) are left out.
    static func all() -> [SwitchWindow] {
        var order: [CGWindowID: (index: Int, bounds: CGRect)] = [:]
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] {
            for (i, w) in list.enumerated() where (w[kCGWindowLayer as String] as? Int) == 0 {
                guard let n = w[kCGWindowNumber as String] as? CGWindowID,
                      let bd = w[kCGWindowBounds as String] as? NSDictionary,
                      let b = CGRect(dictionaryRepresentation: bd) else { continue }
                order[n] = (i, b)
            }
        }
        let own = ProcessInfo.processInfo.processIdentifier
        var visible: [(Int, SwitchWindow)] = []
        var other: [SwitchWindow] = []
        for (pid, wins) in WindowTracker.shared.windows where pid != own {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                  app.activationPolicy == .regular else { continue }
            let name = app.localizedName ?? ""
            for w in wins {
                guard let id = w.windowID else { continue }
                if let o = order[id], !w.minimized {
                    visible.append((o.index, SwitchWindow(id: id, pid: pid, element: w.element, title: w.title,
                                                          appName: name, frame: o.bounds, minimized: false,
                                                          onScreen: true)))
                } else if w.minimized || app.isHidden {
                    let f = AX.frame(w.element) ?? CGRect(x: 0, y: 0, width: 800, height: 500)
                    other.append(SwitchWindow(id: id, pid: pid, element: w.element, title: w.title, appName: name,
                                              frame: f, minimized: w.minimized, onScreen: false))
                }
            }
        }
        visible.sort { $0.0 < $1.0 }
        other.sort { (lastFocus[$0.id] ?? .distantPast) > (lastFocus[$1.id] ?? .distantPast) }
        return visible.map(\.1) + other
    }

    /// Brings a window forward (un-hiding its app and restoring it if minimized).
    static func focus(_ w: SwitchWindow) {
        NSRunningApplication(processIdentifier: w.pid)?.unhide()
        AX.focus(pid: w.pid, window: w.element)
        touch(w.id)
    }

    /// Closes a window with its own close button (the app decides, so it can still ask to save).
    static func close(_ w: SwitchWindow) {
        AX.close(w.element)
    }
}

extension ThumbnailCapture {
    /// Captures many windows at once (each capture is about 15 ms; one after another they would add up),
    /// handing each image over as soon as it is ready. Minimized windows can't be captured: their last
    /// image is reused.
    func captureEach(_ ids: [CGWindowID], maxSize: CGSize, update: @escaping @MainActor (CGWindowID, NSImage) -> Void) async {
        for id in ids { if let c = cached(id) { update(id, c) } }
        guard CGPreflightScreenCaptureAccess(), !ids.isEmpty,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return }
        let backing = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                guard let w = content.windows.first(where: { $0.windowID == id }) else { continue }
                let scale = min(maxSize.width / max(w.frame.width, 1), maxSize.height / max(w.frame.height, 1), 1)
                let cfg = SCStreamConfiguration()
                cfg.width = max(Int(w.frame.width * scale * backing), 2)
                cfg.height = max(Int(w.frame.height * scale * backing), 2)
                cfg.showsCursor = false
                cfg.ignoreShadowsSingleWindow = true
                let filter = SCContentFilter(desktopIndependentWindow: w)
                group.addTask { @MainActor in
                    guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                    else { return }
                    let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / backing,
                                                                height: CGFloat(cg.height) / backing))
                    ThumbnailCapture.shared.store(id, img)
                    update(id, img)
                }
            }
        }
    }
}
