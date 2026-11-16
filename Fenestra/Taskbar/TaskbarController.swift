import AppKit
import SwiftUI
import Combine

final class TaskbarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the taskbar windows: one on the main display, plus one on every other display when
/// "Show my taskbar on all displays" is on (Phase 5). Secondary taskbars have Start, Search, Task View,
/// app buttons, the clock with the bell and the show-desktop corner, like Windows 11; the tray icons and
/// Quick Settings stay on the main taskbar.
/// Handles: auto-hide, hiding behind full-screen apps and videos (per display), and "smaller taskbar buttons" height.
@MainActor
final class TaskbarController {
    static let shared = TaskbarController()

    @MainActor final class Bar {
        let displayID: CGDirectDisplayID
        var screen: NSScreen
        var isMain: Bool
        let panel: TaskbarPanel
        var trigger: NSPanel?                     // 2 pt strip that reveals an auto-hidden taskbar
        var fullscreenActive = false
        var autoHideShown = false
        var autoHideTimer: Timer?
        var outsideSince: Date?

        init(screen: NSScreen, displayID: CGDirectDisplayID, isMain: Bool) {
            self.screen = screen
            self.displayID = displayID
            self.isMain = isMain
            let p = TaskbarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.hidesOnDeactivate = false
            p.isMovable = false
            panel = p
            setContent()
        }

        func setContent() {
            let host = NSHostingView(rootView: TaskbarView(displayID: displayID, isMain: isMain))
            ArrowCursor.install(on: host, followMoves: true)     // pointer off a window's resize edge
            panel.contentView = host
        }

        var targetFrame: NSRect {
            NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: Theme.taskbarHeight)
        }

        /// Shows or hides the taskbar without ordering it out: ordering it out and back in (around a full-screen
        /// desktop) tied it to one desktop, so hidden means transparent and click-through.
        func setPanel(shown: Bool) {
            if !shown && panel.alphaValue > 0 {
                // A tooltip or thumbnail open over this bar would stay behind on top of the full-screen window.
                TrayTip.shared.hide()
                ThumbnailController.shared.dismiss()
            }
            panel.alphaValue = shown ? 1 : 0
            panel.ignoresMouseEvents = !shown
            if !panel.isVisible { panel.orderFrontRegardless() }
        }

        /// The auto-hide reveal strip, kept ordered in for the same reason; inactive = transparent and click-through.
        func setTrigger(active: Bool) {
            guard let t = trigger else { return }
            t.alphaValue = active ? 1 : 0
            t.ignoresMouseEvents = !active
            if !t.isVisible { t.orderFrontRegardless() }
        }

        func close() {
            autoHideTimer?.invalidate()
            panel.orderOut(nil)
            trigger?.orderOut(nil)
        }
    }

    private(set) var bars: [Bar] = []             // main first
    private var cancellables = Set<AnyCancellable>()
    private var fsCheckScheduled = false
    /// Displays whose taskbar was recreated since the last desktop switch (at most once each per switch).
    private var respawned: Set<CGDirectDisplayID> = []

    private var main: Bar? { bars.first { $0.isMain } }

    /// The main display's screen (where the tray, Quick Settings and Alt+Tab live).
    var screen: NSScreen? { main?.screen }
    var frame: NSRect { main?.panel.frame ?? .zero }
    var fullscreenActive: Bool { main?.fullscreenActive ?? false }

    /// Height other windows must keep clear of (0 when auto-hide is on, as on Windows).
    var reservedHeight: CGFloat { AppSettings.shared.autoHide ? 0 : Theme.taskbarHeight }

    /// Whether this display has a taskbar (its work area then ends above it).
    func hasTaskbar(_ s: NSScreen) -> Bool {
        let id = Displays.id(s)
        return bars.contains { $0.displayID == id }
    }

    func hasTaskbar(display id: CGDirectDisplayID) -> Bool { bars.contains { $0.displayID == id } }

    /// Displays that have a taskbar now, as `Displays.uuid` (for apps pinned to one display's taskbar).
    var taskbarDisplayUUIDs: Set<String> { Set(bars.map { Displays.uuid($0.displayID) }) }
    var taskbarCount: Int { bars.count }

    func bar(on s: NSScreen) -> Bar? {
        let id = Displays.id(s)
        return bars.first { $0.displayID == id }
    }

    /// The display a flyout or Start opened from `point` belongs to: the taskbar under it, else the main one.
    func screen(for point: NSPoint) -> NSScreen {
        bars.first { $0.screen.frame.contains(point) }?.screen ?? screen ?? NSScreen.screens[0]
    }

    func start() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TaskbarController.shared.layout() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                // Full-screen transitions animate; check during and after.
                TaskbarController.shared.respawned = []
                for d in [0.05, 0.4, 1.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                        MainActor.assumeIsolated {
                            TaskbarController.shared.checkFullscreen()
                            if d > 0.3 { TaskbarController.shared.ensureOnActiveSpace() }
                        }
                    }
                }
            }
        }
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TaskbarController.shared.scheduleFullscreenCheck() }
        }
        WindowEvents.shared.subscribe { kind, _, _ in
            if kind != .title && kind != .focused { TaskbarController.shared.scheduleFullscreenCheck() }
        }
        let s = AppSettings.shared
        s.$autoHide.dropFirst().sink { _ in DispatchQueue.main.async { TaskbarController.shared.layout() } }
            .store(in: &cancellables)
        Publishers.Merge3(s.$smallButtons.map { _ in () }, s.$combine.map { _ in () },
                          TaskbarModel.shared.$items.map { _ in () })
            .sink { _ in DispatchQueue.main.async { TaskbarController.shared.updateHeight() } }
            .store(in: &cancellables)
        layout()
    }

    // MARK: Layout

    func layout() {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return }          // primary display = screens[0]
        let mainID = Displays.id(primary)
        let wanted = AppSettings.shared.taskbarAllDisplays ? screens : [primary]
        var keep: [Bar] = []
        for s in wanted {
            let id = Displays.id(s)
            let isMain = id == mainID
            if let b = bars.first(where: { $0.displayID == id }) {
                b.screen = s
                if b.isMain != isMain { b.isMain = isMain; b.setContent() }
                keep.append(b)
            } else {
                keep.append(Bar(screen: s, displayID: id, isMain: isMain))
            }
        }
        for b in bars where !keep.contains(where: { $0 === b }) { b.close() }
        keep.sort { $0.isMain && !$1.isMain }
        let before = bars.map(\.displayID)
        bars = keep
        if before != keep.map(\.displayID) {
            Log.write("taskbar: on \(keep.map { $0.screen.localizedName + ($0.isMain ? " (main)" : "") }.joined(separator: ", "))")
            WindowTracker.shared.displaysNeededChanged()
        }
        updateHeight(force: true)
        bars.forEach(applyVisibility)
        checkFullscreen()
    }

    /// "Show smaller taskbar buttons": Always / When taskbar is full / Never.
    func updateHeight(force: Bool = false) {
        let small = TaskbarModel.shared.useSmallButtons(screenWidth: screen?.frame.width ?? 1920)
        let h: CGFloat = small ? 40 : 48
        guard force || h != Theme.taskbarHeight || bars.contains(where: { $0.panel.frame.height != h }) else { return }
        Theme.taskbarHeight = h
        TaskbarModel.shared.small = small
        for b in bars {
            if !(AppSettings.shared.autoHide && !b.autoHideShown) { b.panel.setFrame(b.targetFrame, display: true) }
            updateTrigger(b)
        }
    }

    // MARK: Visibility (full screen, auto-hide)

    private func applyVisibility(_ b: Bar) {
        // Nothing here orders the panel or the trigger out: ordering the panel out for a full-screen window and back
        // in while macOS was still leaving the full-screen desktop tied it to one desktop (log 2026-11-15 11:56).
        if b.fullscreenActive {
            b.setPanel(shown: false)
            b.setTrigger(active: false)
            return
        }
        if AppSettings.shared.autoHide && !b.autoHideShown {
            b.panel.setFrame(b.targetFrame, display: false)
            b.setPanel(shown: false)
            updateTrigger(b)
            b.setTrigger(active: true)
        } else {
            b.setTrigger(active: false)
            b.panel.setFrame(b.targetFrame, display: true)
            b.setPanel(shown: true)
        }
    }

    func scheduleFullscreenCheck() {
        guard !fsCheckScheduled else { return }
        fsCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MainActor.assumeIsolated {
                TaskbarController.shared.fsCheckScheduled = false
                TaskbarController.shared.checkFullscreen()
            }
        }
    }

    /// Hides a taskbar while the frontmost window on its display covers the whole display
    /// (native full screen, browser video full screen, games). Uses CGWindowList bounds only (public, no permission).
    func checkFullscreen() {
        guard !bars.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        var windows: [(pid: pid_t, bounds: CGRect)] = []        // front to back
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bd),
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  b.width > 100, b.height > 100 else { continue }
            windows.append((pid, b))
        }
        var anyChange = false
        for bar in bars {
            let display = CGDisplayBounds(bar.displayID)
            // The front app on this display may put smaller windows in front of its full-screen one: Brave and
            // Chrome add a 1920 x 109 toolbar strip at the top of a full-screen video. So look at every window
            // of the front app until another app's window comes, not only the first one. Any window that covers the
            // whole display counts, including a normal one filled by a title bar double-click (the user wants the
            // taskbar hidden then too).
            let here = windows.filter { $0.bounds.intersects(display) }
            let front = here.first?.pid
            let full = here.prefix { $0.pid == front }.contains { w in
                let b = w.bounds
                return b.minX <= display.minX + 1 && b.minY <= display.minY + 1
                    && b.maxX >= display.maxX - 1 && b.maxY >= display.maxY - 1
            }
            if full != bar.fullscreenActive {
                bar.fullscreenActive = full
                Log.write("taskbar: \(full ? "hidden for" : "back after") full screen on display \(bar.displayID)")
                anyChange = anyChange || full
                applyVisibility(bar)
            }
        }
        if anyChange { FlyoutManager.shared.close(animated: false); StartController.shared.hide(animated: false) }
    }

    /// The taskbars are meant to be on every desktop (`.canJoinAllSpaces`), but the main one was once found tied to
    /// desktop 1 only (user report 2026-11-15, cause unknown): after switching desktops it slid away with desktop 1.
    /// After each switch, a taskbar that should show but isn't on the current desktop is built again (a new panel
    /// joins all desktops).
    func ensureOnActiveSpace() {
        let broken = bars.filter {
            $0.panel.isVisible && !$0.fullscreenActive && !$0.panel.isOnActiveSpace && !respawned.contains($0.displayID)
        }
        guard !broken.isEmpty else { return }
        for b in broken {
            Log.write("taskbar: not on the current desktop on display \(b.displayID), building it again")
            respawned.insert(b.displayID)
            b.close()
        }
        bars.removeAll { b in broken.contains { $0 === b } }
        layout()
    }

    // MARK: Auto-hide

    private func updateTrigger(_ b: Bar) {
        let s = b.screen
        let f = NSRect(x: s.frame.minX, y: s.frame.minY, width: s.frame.width, height: 2)
        if b.trigger == nil {
            let t = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            t.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
            t.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            t.backgroundColor = NSColor(white: 0, alpha: 0.01)   // must not be fully transparent to get mouse events
            t.isOpaque = false
            t.hasShadow = false
            let v = TriggerView(frame: NSRect(origin: .zero, size: f.size))
            v.displayID = b.displayID
            v.autoresizingMask = [.width, .height]
            t.contentView = v
            b.trigger = t
        }
        b.trigger?.setFrame(f, display: false)
    }

    fileprivate func revealAutoHidden(_ id: CGDirectDisplayID) {
        guard AppSettings.shared.autoHide, let b = bars.first(where: { $0.displayID == id }),
              !b.autoHideShown, !b.fullscreenActive else { return }
        b.autoHideShown = true
        b.setTrigger(active: false)
        let p = b.panel
        let f = b.targetFrame
        p.setFrame(f.offsetBy(dx: 0, dy: -f.height), display: false)
        b.setPanel(shown: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.1, 0.9, 0.2, 1)
            p.animator().setFrame(f, display: true)
        }
        b.autoHideTimer?.invalidate()
        b.autoHideTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            MainActor.assumeIsolated { TaskbarController.shared.autoHideTick(id) }
        }
    }

    private func autoHideTick(_ id: CGDirectDisplayID) {
        guard let b = bars.first(where: { $0.displayID == id }) else { return }
        let inside = b.panel.frame.insetBy(dx: 0, dy: -4).contains(NSEvent.mouseLocation)
        let busy = FlyoutManager.shared.currentID != nil || StartController.shared.isOpen
        if inside || busy { b.outsideSince = nil; return }
        if b.outsideSince == nil { b.outsideSince = Date(); return }
        if Date().timeIntervalSince(b.outsideSince!) > 0.6 { hideAutoHidden(b) }
    }

    private func hideAutoHidden(_ b: Bar) {
        b.autoHideTimer?.invalidate()
        b.outsideSince = nil
        b.autoHideShown = false
        let f = b.targetFrame
        let id = b.displayID
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            b.panel.animator().setFrame(f.offsetBy(dx: 0, dy: -f.height), display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                let c = TaskbarController.shared
                if let b = c.bars.first(where: { $0.displayID == id }) { c.applyVisibility(b) }
            }
        })
    }

    /// Keeps an auto-hidden taskbar visible while Start or a flyout is opening from a shortcut.
    func ensureVisible(on s: NSScreen? = nil) {
        guard AppSettings.shared.autoHide, let b = s.flatMap(bar(on:)) ?? main else { return }
        revealAutoHidden(b.displayID)
    }

    private final class TriggerView: NSView {
        var displayID: CGDirectDisplayID = 0
        private var area: NSTrackingArea?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let a = area { removeTrackingArea(a) }
            let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self, userInfo: nil)
            addTrackingArea(a)
            area = a
        }
        override func mouseEntered(with event: NSEvent) {
            let id = displayID
            MainActor.assumeIsolated { TaskbarController.shared.revealAutoHidden(id) }
        }
    }
}
