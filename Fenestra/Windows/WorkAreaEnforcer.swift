import AppKit
import ApplicationServices

/// macOS has no API to reserve screen space for a taskbar (no equivalent of Windows' SHAppBarMessage),
/// and your portable display below the main one means the Dock can't be used as a spacer.
/// So when an app zooms, fills or tiles a window into the taskbar area of a display with a taskbar,
/// this shortens it to stop at the taskbar (public AX API). Windows you drag partly behind the taskbar
/// are left alone, as on Windows. With "Automatically hide the taskbar" on, windows may use the full height.
@MainActor
final class WorkAreaEnforcer {
    static let shared = WorkAreaEnforcer()
    private var pending: [AXUIElement] = []
    private var flushScheduled = false
    private var lastClamp: [CGWindowID: Date] = [:]
    private var started = false
    private var lastDoubleClick: TimeInterval = -100

    /// A double-click anywhere (from DragSnap's global click monitor). A title bar double-click runs macOS's Fill
    /// (`AppleActionOnDoubleClick = Fill`): the window covers the whole display and the taskbar hides, the user's
    /// choice. Shortening that window here a moment later (the taskbar then came back) made it work only when
    /// clicked again within the 1 s clamp throttle: about 8 clicks (user report 2026-11-16).
    func doubleClicked() { lastDoubleClick = ProcessInfo.processInfo.systemUptime }

    func start() {
        guard !started else { return }
        started = true
        WindowEvents.shared.subscribe { kind, _, el in
            switch kind {
            case .resized, .created, .deminimized: WorkAreaEnforcer.shared.enqueue(el)
            default: break
            }
        }
    }

    /// Coalesces bursts (live resizes send many events) and waits for the mouse button to be released.
    private func enqueue(_ el: AXUIElement) {
        if !pending.contains(where: { CFEqual($0, el) }) { pending.append(el) }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            MainActor.assumeIsolated {
                let e = WorkAreaEnforcer.shared
                e.flushScheduled = false
                if NSEvent.pressedMouseButtons != 0 { e.scheduleFlush(); return }
                let els = e.pending
                e.pending = []
                els.forEach(e.check)
            }
        }
    }

    private func check(_ w: AXUIElement) {
        let reserved = TaskbarController.shared.reservedHeight
        guard reserved > 0 else { return }
        let role: String? = AX.attr(w, kAXRoleAttribute)
        let sub: String? = AX.attr(w, kAXSubroleAttribute)
        guard role == kAXWindowRole, sub == kAXStandardWindowSubrole, !AX.isMinimized(w),
              AX.attr(w, "AXFullScreen") != true,
              var f = AX.frame(w),
              let screen = Displays.screen(forAX: f), TaskbarController.shared.hasTaskbar(screen) else { return }

        // AX coordinates: origin at the top-left of the primary display, y downward.
        let primaryHeight = NSScreen.screens[0].frame.height
        let screenTop = primaryHeight - screen.frame.maxY
        let screenBottom = primaryHeight - screen.frame.minY
        let taskbarTop = screenBottom - reserved
        let workTop = screenTop + CaptionController.menuBarInset(screen)   // below the menu bar, if shown

        guard f.midX >= screen.frame.minX, f.midX <= screen.frame.maxX,
              f.midY >= screenTop, f.midY <= screenBottom else { return }
        guard f.maxY > taskbarTop + 1 else { return }

        // Right after a double-click: wait for Fill's animation to end, then leave a window that covers the whole
        // display alone (it counts as full screen and the taskbar hides). Anything else is checked as usual.
        let sinceDouble = ProcessInfo.processInfo.systemUptime - lastDoubleClick
        if sinceDouble < 0.5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + (0.5 - sinceDouble)) {
                MainActor.assumeIsolated { WorkAreaEnforcer.shared.enqueue(w) }
            }
            return
        }
        if sinceDouble < 3, f.minX <= screen.frame.minX + 2, f.maxX >= screen.frame.maxX - 2,
           f.minY <= screenTop + 2, f.maxY >= screenBottom - 2 {
            Log.write("workarea: window fills the display after a double-click, taskbar hides (not shortened)")
            return
        }

        // Zoom / Fill / tiling: the window touches the top of the work area, or its bottom edge
        // was resized onto the screen edge. A plain move doesn't trigger this (no resize event).
        let fillsDown = f.minY <= workTop + 2 && f.height >= screen.frame.height * 0.5
        let bottomOnEdge = abs(f.maxY - screenBottom) <= 2
        guard fillsDown || bottomOnEdge else { return }

        if let id = AX.windowID(w) {
            if let last = lastClamp[id], Date().timeIntervalSince(last) < 1 { return }
            lastClamp[id] = Date()
        }
        f.size.height = taskbarTop - f.minY
        AX.setSize(w, f.size)
    }
}
