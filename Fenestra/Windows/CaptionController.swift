import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Phase 3: Windows 11 caption buttons in place of the traffic lights, for every window of every app.
///
/// macOS has no public way to restyle another app's title bar (and SIP stays on), so each window gets a
/// small transparent panel of ours, ordered directly above it (`order(.above, relativeTo:)`), covering the
/// traffic lights. Its position comes from the window's `kAXCloseButtonAttribute` / minimize / zoom frames.
/// Everything is event driven through the shared `WindowEvents` hub: nothing runs while idle.
/// While you drag a window the panel hides, and it comes back when the mouse button is released.
@MainActor
final class CaptionController {
    static let shared = CaptionController()

    @MainActor final class Entry {
        let id: CGWindowID
        let pid: pid_t
        let element: AXUIElement
        let view = CaptionView(frame: NSRect(x: 0, y: 0, width: 138, height: 32))
        lazy var panel = CaptionPanel(view: view)
        var frame: CGRect = .zero              // window frame, AX coordinates (top-left origin, y down)
        var lights: CGRect = .zero             // traffic lights, relative to the window's top-left
        var lightsSize: CGSize = .zero         // window size the lights / button size were measured at
        var panelSize: CGSize = .zero
        var buttonWidth: CGFloat = 46
        /// Phase 6: the menu button sits right of close (setting on, and it doesn't cover app controls).
        var showsMenu = false
        var shown = false
        var hiddenForDrag = false
        var lastSample = Date.distantPast
        init(id: CGWindowID, pid: pid_t, element: AXUIElement) {
            self.id = id; self.pid = pid; self.element = element
        }
    }

    private(set) var entries: [CGWindowID: Entry] = [:]
    private var started = false
    private var dirty: Set<pid_t> = []
    private var dirtyAll = false
    private var flushScheduled = false
    private var lastFrontPid: pid_t?

    /// Frame to go back to from maximized (per CGWindowID, AX coordinates), and the frame we maximized to.
    private var normalFrames: [CGWindowID: CGRect] = [:]
    private var maximizedFrames: [CGWindowID: CGRect] = [:]
    /// Apps whose window was closed with our close button: quit them once their last window is gone.
    private var pendingQuit: [pid_t: Date] = [:]

    private var downMonitor: Any?
    private var dragMonitor: Any?
    /// Listen-only event tap, enabled only while a title bar press is being watched. It sees drag events
    /// before the window server routes them (an NSEvent global monitor only gets them afterwards, a frame
    /// late), so the buttons move in the same frame as the window.
    private var dragTap: CFMachPort?
    private var upMonitor: Any?
    private var upSafetyTimer: Timer?
    /// A press in a title bar. The buttons hide as soon as the window starts moving and come back on
    /// release. (Following a dragged window can't be done cleanly: the buttons are a separate window and
    /// macOS reports another app's window position 1 to 3 frames late, so they wobbled around it.)
    private struct Drag {
        let id: CGWindowID
        let origin: CGPoint            // window origin at mouse-down (AX)
        let mouse: CGPoint             // mouse at mouse-down (AX)
        var checks = 0
        var speculative = false        // hidden at the first drag event, before the window list confirms it
        var hidden = false
    }
    private var drag: Drag?
    private var refreshOnUp: Set<pid_t> = []
    private var validatePending: Set<Int> = []
    private var chromiumCache: [String: Bool] = [:]

    private var enabled: Bool { AppSettings.shared.captionButtons }

    // MARK: Start / settings

    func start() {
        guard !started, WindowEvents.shared.isRunning else { return }
        started = true
        WindowEvents.shared.subscribe { kind, pid, el in CaptionController.shared.handle(kind, pid, el) }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { CaptionController.shared.activated(pid) }
        }
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { n in
                guard let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                else { return }
                MainActor.assumeIsolated { CaptionController.shared.markDirty(pid) }
            }
        }
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                CaptionController.shared.hideOffscreen()
                CaptionController.shared.markAll(delay: 0.3)      // after the Space animation
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CaptionController.shared.markAll(delay: 0.3) }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                for e in CaptionController.shared.entries.values { e.lastSample = .distantPast; e.view.setBackground(nil) }
                CaptionController.shared.markAll(delay: 0.2)
            }
        }
        lastFrontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if enabled { installDownMonitor() }
        if debug { DragDiagnostics.install() }
        markAll(delay: 0)
        Log.write("captions: started (enabled=\(enabled), size=\(AppSettings.shared.captionSize.rawValue), " +
                  "screenRecording=\(CGPreflightScreenCaptureAccess()))")
    }

    func settingsChanged() {
        guard started else { return }
        if enabled {
            installDownMonitor()
            for e in entries.values { e.lightsSize = .zero }          // re-measure button size
            markAll(delay: 0)
        } else {
            SnapController.shared.dismiss()
            removeAll()
            if let m = downMonitor { NSEvent.removeMonitor(m); downMonitor = nil }
        }
    }

    func entry(_ id: CGWindowID) -> Entry? { entries[id] }

    /// `defaults write local.fenestra.Fenestra captionDebug -bool true` logs every window event (diagnostics).
    private let debug = UserDefaults.standard.bool(forKey: "captionDebug")

    // MARK: Events

    private func handle(_ kind: WindowEvents.Kind, _ pid: pid_t, _ el: AXUIElement) {
        if debug { Log.write("captions event: \(kind) pid=\(pid) mouse=\(NSEvent.pressedMouseButtons)") }
        guard enabled else {
            if kind == .destroyed { checkQuit(pid) }
            return
        }
        switch kind {
        case .created:
            markDirty(pid)
            markDirty(pid, delay: 0.3)            // close button and frame settle a moment after creation
        case .destroyed:
            if CFEqual(el, AX.app(pid)) {
                for e in entries.values where e.pid == pid { remove(e) }
            } else if let e = entry(for: el) {
                normalFrames[e.id] = nil
                maximizedFrames[e.id] = nil
                remove(e)
            }
            markDirty(pid)
            checkQuit(pid)
        case .minimized, .deminimized:
            if kind == .minimized, let e = entry(for: el) { hide(e) }
            markDirty(pid)
        case .focused:
            markDirty(pid, delay: 0)
        case .moved, .resized:
            windowMoved(kind, pid, el)
        case .title:
            break
        }
    }

    private func activated(_ pid: pid_t?) {
        guard enabled else { return }
        // Activation raises all of the app's windows above our panels: put them back on top right away.
        if let pid { reorder(pid) }
        if let old = lastFrontPid, old != pid { markDirty(old, delay: 0) }    // its windows turn inactive
        lastFrontPid = pid
        if let pid {
            markDirty(pid, delay: 0)
            markDirty(pid, delay: 0.15)        // some apps raise their windows a little later
        }
        scheduleValidate()
    }

    /// Fenestra raised one of the app's windows itself (AX.focus). If the app was already in front there is
    /// no activation event, so put its panels back on top now and check again once the raise has landed.
    func afterRaise(_ pid: pid_t) {
        guard enabled else { return }
        reorder(pid)
        scheduleValidate()
    }

    private func windowMoved(_ kind: WindowEvents.Kind, _ pid: pid_t, _ el: AXUIElement) {
        let mouseDown = NSEvent.pressedMouseButtons & 1 != 0
        guard let e = entry(for: el) else {
            if !mouseDown { markDirty(pid) }
            return
        }
        if mouseDown {
            if drag?.id == e.id { hideForDrag(e); return }   // a title bar drag: hidden until release
            // Moved some other way while the button is down (resized from the top/left edge):
            // hide until the mouse button comes up.
            if kind == .moved || AX.frame(e.element)?.origin != e.frame.origin { hideForDrag(e) }
            else { refreshOnUp.insert(pid); watchMouseUp() }
            return
        }
        if kind == .resized { markDirty(pid); return }
        // Programmatic move (tiling, another app, animation): follow it at once.
        guard let f = AX.frame(e.element) else { return }
        e.frame = f
        if e.shown { e.panel.setFrame(cocoaRect(panelRect(e)), display: false) }
        updateMaximized(e)
    }

    // MARK: Reconcile

    /// Coalesced re-read of one app's windows. Delays above 50 ms are separate later passes
    /// (the pid is only queued when the delay ends, so an earlier pass can't swallow it).
    func markDirty(_ pid: pid_t, delay: Double = 0.03) {
        if delay > 0.05 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { CaptionController.shared.markDirty(pid, delay: 0) }
            }
            return
        }
        dirty.insert(pid)
        scheduleFlush(delay)
    }

    func markAll(delay: Double) {
        if delay > 0.05 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { CaptionController.shared.markAll(delay: 0) }
            }
            return
        }
        dirtyAll = true
        scheduleFlush(delay)
    }

    private func scheduleFlush(_ delay: Double) {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { CaptionController.shared.flush() }
        }
    }

    private func flush() {
        flushScheduled = false
        guard enabled else { dirty = []; dirtyAll = false; return }
        var pids = dirty
        if dirtyAll {
            pids.formUnion(entries.values.map(\.pid))
            pids.formUnion(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
                .map(\.processIdentifier))
        }
        dirty = []
        dirtyAll = false
        pids.remove(ProcessInfo.processInfo.processIdentifier)
        guard !pids.isEmpty else { return }
        let onscreen = Self.onscreenWindowIDs()
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if debug { Log.write("captions flush: \(pids.sorted())") }
        for pid in pids { reconcile(pid, onscreen: onscreen, front: front) }
    }

    private func reconcile(_ pid: pid_t, onscreen: Set<CGWindowID>, front: pid_t?) {
        var seen = Set<CGWindowID>()
        if let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated, !app.isHidden,
           app.activationPolicy == .regular {
            let focusedID = pid == front ? AX.focusedWindow(pid).flatMap(AX.windowID) : nil
            for w in AX.windows(pid) {
                guard let id = AX.windowID(w), onscreen.contains(id),
                      !AX.isMinimized(w), AX.attr(w, "AXFullScreen") != true,
                      let f = AX.frame(w), f.width > 100, f.height > 60 else { continue }
                if let e = entries[id], e.hiddenForDrag, NSEvent.pressedMouseButtons & 1 != 0 { seen.insert(id); continue }
                let e = entries[id] ?? Entry(id: id, pid: pid, element: w)
                guard update(e, window: w, frame: f, active: id == focusedID) else { continue }
                entries[id] = e
                seen.insert(id)
            }
        }
        for e in entries.values where e.pid == pid && !seen.contains(e.id) { remove(e) }
    }

    /// Positions, styles and orders one window's panel. Returns false if the window has no traffic lights.
    private func update(_ e: Entry, window w: AXUIElement, frame f: CGRect, active: Bool) -> Bool {
        let resized = abs(e.lightsSize.width - f.width) > 0.5 || abs(e.lightsSize.height - f.height) > 0.5
        if resized {
            guard let lights = Self.lights(of: w, frame: f) else { return false }
            e.lights = lights.rect
            e.view.enabledParts = [lights.canMinimize, lights.canZoom, true, true]
        }
        e.frame = f
        if resized {
            let widthChanged = abs(e.lightsSize.width - f.width) > 40
            e.lightsSize = f.size
            let mid = e.lights.midY
            var h = min(max((mid * 2).rounded(), 32), 48)            // 32 pt title bar, up to 48 for tall toolbars
            h = max(h, ceil(e.lights.maxY) + 3)
            if widthChanged || e.panelSize == .zero {
                e.buttonWidth = chooseButtonWidth(e, height: h)
                e.showsMenu = menuButtonFits(e)
            }
            e.view.showsMenu = e.showsMenu
            e.panelSize = CGSize(width: e.buttonWidth * (e.showsMenu ? 4 : 3), height: h - 1)
            // Tahoe draws the traffic lights concentric with the window corner: radius ~ their center height.
            e.view.configure(buttonWidth: e.buttonWidth, radius: min(max(mid + 2, 8), 30),
                             maximizeTip: !AppSettings.shared.snapLayoutsOnHover)
            e.lastSample = .distantPast
        }
        e.view.active = active
        updateMaximized(e)
        e.view.onClick = { [id = e.id] part in CaptionController.shared.clicked(id, part) }
        e.view.onMenu = { [id = e.id] rect in CaptionController.shared.menuButtonPressed(id, rect) }
        e.view.onRightClick = { [id = e.id] point in CaptionController.shared.windowMenu(id, at: point) }
        e.view.onMaximizeHover = { [id = e.id] inside, rect in
            if inside { SnapController.shared.hoverBegan(window: id, button: rect) }
            else { SnapController.shared.hoverEnded() }
        }
        if !e.hiddenForDrag {
            let target = cocoaRect(panelRect(e))
            if e.panel.frame != target { e.panel.setFrame(target, display: false) }
            e.panel.order(.above, relativeTo: Int(e.id))
            e.shown = true
        }
        if Date().timeIntervalSince(e.lastSample) > 3 {
            e.lastSample = Date()
            TitleBarSampler.shared.sample(e)
        }
        return true
    }

    private func panelRect(_ e: Entry) -> CGRect {
        CGRect(x: e.frame.minX + 1, y: e.frame.minY + 1, width: e.panelSize.width, height: e.panelSize.height)
    }

    /// Re-orders an app's panels above their windows without re-reading anything.
    private func reorder(_ pid: pid_t) {
        for e in entries.values where e.pid == pid && e.shown && !e.hiddenForDrag {
            e.panel.order(.above, relativeTo: Int(e.id))
        }
    }

    private func hide(_ e: Entry) {
        if SnapController.shared.windowID == e.id { SnapController.shared.dismiss() }
        e.view.resetInteraction()
        e.panel.orderOut(nil)
        e.shown = false
    }

    private func remove(_ e: Entry) {
        hide(e)
        e.panel.close()
        entries[e.id] = nil
    }

    private func removeAll() {
        entries.values.forEach(remove)
    }

    private func entry(for el: AXUIElement) -> Entry? {
        entries.values.first { CFEqual($0.element, el) }
    }

    /// Hides panels whose window left the screen without telling us (ordered out, other Space).
    private func hideOffscreen() {
        guard !entries.isEmpty else { return }
        let onscreen = Self.onscreenWindowIDs()
        for e in entries.values where !onscreen.contains(e.id) { remove(e) }
    }

    /// One window-list read: drops panels whose window is gone from the screen, and puts back on top any
    /// panel that ended up behind its window. Apps can raise their own windows without any Accessibility
    /// event (Electron apps such as Claude do), so this runs shortly after every click and app switch.
    private func validate() {
        guard !entries.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return }
        var index: [CGWindowID: Int] = [:]
        for (i, w) in list.enumerated() { if let n = w[kCGWindowNumber as String] as? CGWindowID { index[n] = i } }
        var fixed = 0
        for e in entries.values {
            guard let wi = index[e.id] else { remove(e); continue }
            guard e.shown, !e.hiddenForDrag else { continue }
            if index[CGWindowID(e.panel.windowNumber)] != wi - 1 {
                e.panel.order(.above, relativeTo: Int(e.id))
                fixed += 1
            }
        }
        if debug && fixed > 0 { Log.write("captions: re-ordered \(fixed) panel(s) above their windows") }
    }

    private func scheduleValidate() {
        guard !entries.isEmpty else { return }
        for ms in [30, 400] where !validatePending.contains(ms) {
            validatePending.insert(ms)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) {
                MainActor.assumeIsolated {
                    CaptionController.shared.validatePending.remove(ms)
                    CaptionController.shared.validate()
                }
            }
        }
    }

    // MARK: Traffic lights and button size

    struct Lights { var rect: CGRect; var canMinimize: Bool; var canZoom: Bool }

    /// Union of the close, minimize and zoom buttons relative to the window's top-left, if they sit
    /// where traffic lights belong (apps that draw their own title bar controls are left alone).
    static func lights(of w: AXUIElement, frame f: CGRect) -> Lights? {
        guard let close = AX.elementAttr(w, kAXCloseButtonAttribute), let cf = AX.frame(close),
              cf.width > 0, cf.height > 0 else { return nil }
        var rect = cf
        var canMin = false, canZoom = false
        if let b = AX.elementAttr(w, kAXMinimizeButtonAttribute), let bf = AX.frame(b) {
            rect = rect.union(bf)
            canMin = AX.attr(b, kAXEnabledAttribute) ?? true
        }
        if let b = AX.elementAttr(w, kAXZoomButtonAttribute), let bf = AX.frame(b) {
            rect = rect.union(bf)
            canZoom = (AX.attr(b, kAXEnabledAttribute) ?? true) && AX.isSettable(w, kAXSizeAttribute)
        }
        let rel = rect.offsetBy(dx: -f.minX, dy: -f.minY)
        guard rel.minX >= 0, rel.minY >= 0, rel.maxX <= 130, rel.maxY <= 60 else { return nil }
        return Lights(rect: rel, canMinimize: canMin, canZoom: canZoom)
    }

    /// Windows size (46 pt) unless that would cover the app's own controls next to the traffic lights:
    /// then the buttons shrink to the traffic lights' width. Chromium/Electron apps (tabs right beside the
    /// lights, and no AX tree unless forced on) always get the compact size in Automatic mode.
    private func chooseButtonWidth(_ e: Entry, height: CGFloat) -> CGFloat {
        let compact = max(24, ceil((e.lights.maxX + 5) / 3))
        switch AppSettings.shared.captionSize {
        case .windows: return 46
        case .compact: return compact
        case .automatic:
            if isChromiumLike(e.pid) { return compact }
            return controlsBeside(e) ? compact : 46
        }
    }

    /// Phase 6: the menu button goes right of close, one button wide. In Automatic size it is left out where it
    /// would cover the app's own controls, and for Chromium/Electron apps (no AX tree to check, tabs or
    /// toolbar buttons right there): their menus stay one right-click or Option tap away.
    private func menuButtonFits(_ e: Entry) -> Bool {
        guard AppSettings.shared.menuButton else { return false }
        guard AppSettings.shared.captionSize == .automatic else { return true }
        if isChromiumLike(e.pid) { return false }
        let from = max(e.buttonWidth * 3, e.lights.maxX + 4)
        return !controlsBeside(e, from: from, to: e.buttonWidth * 4 + 4)
    }

    private static let controlRoles: Set<String> = [
        kAXButtonRole, kAXRadioButtonRole, kAXCheckBoxRole, kAXPopUpButtonRole, kAXMenuButtonRole,
        kAXTextFieldRole, kAXComboBoxRole, kAXRadioGroupRole, kAXSliderRole, kAXStaticTextRole, kAXImageRole,
        "AXLink", "AXTab", "AXSearchField", "AXSegmentedControl", kAXDisclosureTriangleRole, kAXIncrementorRole,
    ]
    private static let lightSubroles: Set<String> = [
        kAXCloseButtonSubrole, kAXMinimizeButtonSubrole, kAXZoomButtonSubrole, kAXFullScreenButtonSubrole,
    ]

    /// AX hit tests along the band the Windows-size buttons would cover. Our own panel is made
    /// click-through meanwhile so the window server's hit testing sees the app underneath.
    private func controlsBeside(_ e: Entry) -> Bool {
        controlsBeside(e, from: e.lights.maxX + 4, to: 46 * 3 + 4)
    }

    /// `from` and `to` are x offsets from the window's left edge.
    private func controlsBeside(_ e: Entry, from: CGFloat, to: CGFloat) -> Bool {
        let app = AX.app(e.pid)
        let y = Float(e.frame.minY + e.lights.midY)
        let wasIgnoring = e.panel.ignoresMouseEvents
        if e.shown { e.panel.ignoresMouseEvents = true }
        defer { e.panel.ignoresMouseEvents = wasIgnoring }
        var x = e.frame.minX + from
        let end = e.frame.minX + to
        while x <= end {
            var el: AXUIElement?
            if AXUIElementCopyElementAtPosition(app, Float(x), y, &el) == .success, let el,
               let role: String = AX.attr(el, kAXRoleAttribute), Self.controlRoles.contains(role) {
                let sub: String? = AX.attr(el, kAXSubroleAttribute)
                if !Self.lightSubroles.contains(sub ?? "") { return true }
            }
            x += 10
        }
        return false
    }

    private func isChromiumLike(_ pid: pid_t) -> Bool {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
        if let v = chromiumCache[url.path] { return v }
        let fw = url.appendingPathComponent("Contents/Frameworks")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: fw.path)) ?? []
        // Chromium shells ship "<Product> Framework.framework" (Chrome, Brave, Edge, Electron, ...).
        let v = names.contains { $0.hasSuffix(" Framework.framework") }
        chromiumCache[url.path] = v
        return v
    }

    // MARK: Drag detection

    /// A global left-mouse-down monitor (system clicks only, no polling): lifts the clicked window's buttons
    /// above the coming raise, and if the press is in the title band, watches for a window drag.
    private func installDownMonitor() {
        guard downMonitor == nil else { return }
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            MainActor.assumeIsolated { CaptionController.shared.globalMouseDown() }
        }
    }

    private func globalMouseDown() {
        scheduleValidate()
        guard !entries.isEmpty else { return }
        let m = NSEvent.mouseLocation
        let p = CGPoint(x: m.x, y: Self.primaryHeight - m.y)
        let under = entries.values.filter { $0.shown && $0.frame.contains(p) }
        guard !under.isEmpty else { return }
        var clicked = under[0]
        if under.count > 1 {
            // Overlapping windows: the frontmost one under the mouse is the one clicked.
            let order = Self.onscreenOrder()
            clicked = under.min { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }!
        }
        // A click brings the window to the front, and apps raise it again themselves (Claude/Electron do,
        // ~40 ms later): either way it lands above our panel and the traffic lights flash. So lift the panel
        // one level above normal windows *before* that happens; it goes back down shortly after release.
        elevate(clicked)
        watchMouseUp()
        guard p.y - clicked.frame.minY <= max(clicked.lights.midY * 2 + 4, 30) else { return }
        let target = clicked
        drag = Drag(id: target.id, origin: target.frame.origin, mouse: p)
        // Pressed on empty title bar (not a control)? Then it's a window drag: hide at the very first drag
        // event instead of waiting to see the window move (that wait let the traffic lights flash).
        if isChromiumLike(target.pid) {
            drag?.speculative = true            // no usable AX tree: undone if the window stays put
        } else {
            var el: AXUIElement?
            if AXUIElementCopyElementAtPosition(AX.app(target.pid), Float(p.x), Float(p.y), &el) == .success, let el,
               let role: String = AX.attr(el, kAXRoleAttribute),
               [kAXWindowRole, kAXToolbarRole, kAXUnknownRole].contains(role) {
                drag?.speculative = true
            }
        }
        if !enableDragTap(), dragMonitor == nil {
            dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { _ in
                MainActor.assumeIsolated {
                    let m = NSEvent.mouseLocation
                    CaptionController.shared.dragged(to: CGPoint(x: m.x, y: CaptionController.primaryHeight - m.y))
                }
            }
        }
        watchMouseUp()
    }

    /// Creates the tap once (disabled), then just switches it on and off. Returns false if unavailable.
    private func enableDragTap() -> Bool {
        if dragTap == nil {
            let mask = CGEventMask(1 << CGEventType.leftMouseDragged.rawValue) | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
            let cb: CGEventTapCallBack = { _, type, event, _ in
                let loc = event.location                  // global, top-left origin: same space as AX
                MainActor.assumeIsolated {
                    let c = CaptionController.shared
                    switch type {
                    case .leftMouseDragged: c.dragged(to: loc)
                    case .leftMouseUp: DispatchQueue.main.async { MainActor.assumeIsolated { c.mouseReleased() } }
                    case .tapDisabledByTimeout, .tapDisabledByUserInput:
                        if c.drag != nil, let t = c.dragTap { CGEvent.tapEnable(tap: t, enable: true) }
                    default: break
                    }
                }
                return Unmanaged.passUnretained(event)
            }
            guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                            eventsOfInterest: mask, callback: cb, userInfo: nil) else {
                Log.write("captions: drag event tap unavailable, using a global monitor")
                return false
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
            dragTap = t
        }
        CGEvent.tapEnable(tap: dragTap!, enable: true)
        return true
    }

    /// Drag events (from the tap, seen before the window server routes them): hide the buttons the moment
    /// the window starts to move. A press on empty title bar is a window drag for sure, so it hides on the
    /// very first event; otherwise it waits until the window list shows the window moved.
    private func dragged(to mouse: CGPoint) {
        guard var d = drag, let e = entries[d.id] else { stopDragWatch(); return }
        d.checks += 1
        if !d.hidden {
            let moved = Self.bounds(of: d.id).map { abs($0.minX - d.origin.x) > 1 || abs($0.minY - d.origin.y) > 1 } ?? false
            if d.speculative || moved {
                d.hidden = true
                hideForDrag(e)
            } else if d.checks > 60 {
                stopDragWatch()                 // a text selection or slider, not a window drag
                return
            }
        } else if d.speculative && d.checks >= 6 {
            d.speculative = false
            let moved = Self.bounds(of: d.id).map { abs($0.minX - d.origin.x) > 1 || abs($0.minY - d.origin.y) > 1 } ?? true
            if !moved && abs(mouse.x - d.mouse.x) + abs(mouse.y - d.mouse.y) > 3 {
                // The mouse moved but the window didn't (dragging a tab, say): show the buttons again.
                e.hiddenForDrag = false
                markDirty(e.pid, delay: 0)
                stopDragWatch()
                return
            }
        }
        if d.hidden && !d.speculative { drag = d; stopDragTap(); return }   // nothing more to watch until release
        drag = d
    }

    private func stopDragTap() {
        if let m = dragMonitor { NSEvent.removeMonitor(m); dragMonitor = nil }
        if let t = dragTap { CGEvent.tapEnable(tap: t, enable: false) }
    }

    private func stopDragWatch() {
        stopDragTap()
        drag = nil
    }

    private func hideForDrag(_ e: Entry) {
        if !e.hiddenForDrag {
            e.hiddenForDrag = true
            hide(e)
        }
        watchMouseUp()
    }

    private func watchMouseUp() {
        if upMonitor == nil {
            upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
                MainActor.assumeIsolated { CaptionController.shared.mouseReleased() }
            }
        }
        if upSafetyTimer == nil {
            // Backstop in case the release isn't delivered (e.g. it ended inside a modal tracking loop).
            upSafetyTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
                MainActor.assumeIsolated {
                    if NSEvent.pressedMouseButtons & 1 == 0 { CaptionController.shared.mouseReleased() }
                }
            }
        }
    }

    private var elevated: Set<CGWindowID> = []
    private var lowerWork: DispatchWorkItem?

    private func elevate(_ e: Entry) {
        lowerWork?.cancel()
        lowerElevated(except: e.id)
        if !elevated.contains(e.id) {
            e.panel.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
            e.panel.orderFrontRegardless()
            elevated.insert(e.id)
        }
    }

    /// Back to normal level, directly above its window (where other windows can cover it again).
    private func lowerElevated(except keep: CGWindowID? = nil) {
        for id in elevated where id != keep {
            elevated.remove(id)
            guard let e = entries[id] else { continue }
            e.panel.level = .normal
            if e.shown && !e.hiddenForDrag { e.panel.order(.above, relativeTo: Int(id)) }
        }
    }

    private func scheduleLower() {
        lowerWork?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated { CaptionController.shared.lowerElevated() } }
        lowerWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    private func mouseReleased() {
        scheduleLower()
        if let m = upMonitor { NSEvent.removeMonitor(m); upMonitor = nil }
        upSafetyTimer?.invalidate()
        upSafetyTimer = nil
        var pids = refreshOnUp
        if let d = drag, d.hidden, let e = entries[d.id] {
            pids.insert(e.pid)                  // show again at the window's final frame
            if debug { Log.write("captions drag: window \(d.id) hidden for the drag, events=\(d.checks)") }
        }
        stopDragWatch()
        refreshOnUp = []
        for e in entries.values where e.hiddenForDrag {
            e.hiddenForDrag = false
            pids.insert(e.pid)
        }
        // Let the window settle (macOS tiling may animate it into place after the release).
        for pid in pids { markDirty(pid, delay: 0.06) }
    }

    // MARK: Actions

    /// Phase 6: menu button. The window comes forward first, so the app's commands apply to it (as on Windows).
    private func menuButtonPressed(_ id: CGWindowID, _ rect: NSRect) {
        guard let e = entries[id] else { return }
        SnapController.shared.dismiss()
        AX.focus(pid: e.pid, window: e.element)
        AppMenus.shared.popUpAppMenu(pid: e.pid, at: NSPoint(x: rect.minX, y: rect.minY - 2))
    }

    /// Phase 6: right-click on the buttons = Windows' window menu, then the app's menus.
    private func windowMenu(_ id: CGWindowID, at point: NSPoint) {
        guard let e = entries[id] else { return }
        SnapController.shared.dismiss()
        AX.focus(pid: e.pid, window: e.element)
        let enabled = e.view.enabledParts
        AppMenus.shared.popUpWindowMenu(pid: e.pid, maximized: e.view.maximized, canMinimize: enabled[0],
                                        canMaximize: enabled[1], canResize: AX.isSettable(e.element, kAXSizeAttribute),
                                        at: point, mover: { [pid = e.pid, el = e.element] mode in
            WindowMover.shared.begin(mode, pid: pid, element: el)
        }) { part in
            CaptionController.shared.clicked(id, part)
        }
    }

    /// Option+Space (Alt+Space): the window menu of the focused window, at its top-left corner. Windows without
    /// Fenestra's buttons (custom title bars) get the same menu, acting through Accessibility.
    func windowMenuForFocusedWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let w = AX.focusedWindow(app.processIdentifier), let f = AX.frame(w) else { return }
        let pid = app.processIdentifier
        if let id = AX.windowID(w), let e = entries[id], e.shown {
            windowMenu(id, at: NSPoint(x: e.panel.frame.minX, y: e.panel.frame.minY - 2))
            return
        }
        let r = cocoaRect(f)
        let id = AX.windowID(w)
        let maximized = id.map { isMaximized($0, f) } ?? false
        let canResize = AX.isSettable(w, kAXSizeAttribute)
        AppMenus.shared.popUpWindowMenu(pid: pid, maximized: maximized,
                                        canMinimize: AX.elementAttr(w, kAXMinimizeButtonAttribute) != nil,
                                        canMaximize: canResize && id != nil, canResize: canResize,
                                        at: NSPoint(x: r.minX + 8, y: r.maxY - 30),
                                        mover: { mode in WindowMover.shared.begin(mode, pid: pid, element: w) }) { part in
            switch part {
            case .minimize: AX.setMinimized(w, true)
            case .maximize:
                guard let id else { return }
                if maximized { CaptionController.shared.restore(pid: pid, element: w, id: id) }
                else { CaptionController.shared.maximize(pid: pid, element: w, id: id) }
            case .close: AX.close(w)
            case .menu: break
            }
        }
    }

    private func clicked(_ id: CGWindowID, _ part: CaptionView.Part) {
        guard let e = entries[id] else { return }
        SnapController.shared.dismiss()
        switch part {
        case .minimize:
            hide(e)
            AX.setMinimized(e.element, true)
        case .maximize:
            toggleMaximize(e)
        case .close:
            close(e)
        case .menu:
            menuButtonPressed(id, e.view.screenRect(of: .menu))
        }
    }

    private func close(_ e: Entry) {
        let app = NSRunningApplication(processIdentifier: e.pid)
        let name = app?.localizedName ?? "?"
        if let b = AX.elementAttr(e.element, kAXCloseButtonAttribute) { AX.perform(b, kAXPressAction) }
        markDirty(e.pid, delay: 0.25)
        guard app?.bundleIdentifier != "com.apple.finder" else { Log.write("caption close: \(name) (Finder stays open)"); return }
        guard AppSettings.shared.quitOnLastWindow else { Log.write("caption close: \(name) (keeps running, setting)"); return }
        Log.write("caption close: \(name)")
        pendingQuit[e.pid] = Date()
        // A "Save changes?" sheet keeps the window open; the app then quits once the window really goes.
        for d in [0.4, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                MainActor.assumeIsolated { CaptionController.shared.checkQuit(e.pid) }
            }
        }
    }

    /// Windows behavior: an app ends when its last window is closed.
    private func checkQuit(_ pid: pid_t) {
        guard let t = pendingQuit[pid] else { return }
        guard Date().timeIntervalSince(t) < 120,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            pendingQuit[pid] = nil
            return
        }
        let remaining = AX.windows(pid).filter { w in
            guard let f = AX.frame(w) else { return false }
            return f.width > 60 && f.height > 40
        }
        guard remaining.isEmpty, !Self.hasFullScreenWindow(pid) else { return }
        pendingQuit[pid] = nil
        Log.write("caption close: last window of \(app.localizedName ?? "?") closed, quitting it")
        app.terminate()
    }

    private func toggleMaximize(_ e: Entry) {
        guard let f = AX.frame(e.element) else { return }
        if isMaximized(e.id, f) { restore(pid: e.pid, element: e.element, id: e.id) }
        else { maximize(pid: e.pid, element: e.element, id: e.id) }
    }

    /// Maximize (fill the work area, never a full-screen Space). Also used by Control+Option+Up and by
    /// dragging a window to the top edge (`workArea` is then the display under the pointer).
    func maximize(pid: pid_t, element: AXUIElement, id: CGWindowID, workArea: CGRect? = nil) {
        guard let f = AX.frame(element) else { return }
        WindowSnap.shared.willMaximize(id, f)
        if !isMaximized(id, f) { normalFrames[id] = f }
        let wa = workArea ?? Self.workArea(for: f)
        Log.write("caption maximize: \(id) -> \(Self.describe(wa))")
        Self.setFrame(pid, element, wa)
        maximizedFrames[id] = AX.frame(element) ?? wa
        AX.focus(pid: pid, window: element)
        markDirty(pid, delay: 0.05)
    }

    /// Restore Down: back to the frame from before maximize (Control+Option+Down on a maximized window too).
    func restore(pid: pid_t, element: AXUIElement, id: CGWindowID) {
        guard let f = AX.frame(element) else { return }
        let wa = Self.workArea(for: f)
        var target = normalFrames[id] ?? .zero
        // A saved frame reaching into the taskbar would be shortened right back to "maximized"
        // by WorkAreaEnforcer, so compare it as it would end up.
        var clamped = target
        if clamped.maxY > wa.maxY { clamped.size.height = wa.maxY - clamped.minY }
        if target == .zero || (clamped.width >= wa.width * 0.95 && clamped.height >= wa.height * 0.95) {
            target = Self.defaultRestoreFrame(in: wa)      // maximized before we saw it, or saved at full size
        }
        maximizedFrames[id] = nil
        Log.write("caption restore: \(id) -> \(Self.describe(target))")
        Self.setFrame(pid, element, target)
        markDirty(pid, delay: 0.05)
    }

    /// Phase 5: put a window back maximized on a display that was reconnected, keeping its Restore Down frame
    /// (no focus change: it isn't something the user did right now).
    func restoreMaximized(pid: pid_t, element: AXUIElement, id: CGWindowID, normal: CGRect?, workArea wa: CGRect) {
        Self.setFrame(pid, element, wa)
        maximizedFrames[id] = AX.frame(element) ?? wa
        if let normal { normalFrames[id] = normal }
        markDirty(pid, delay: 0.05)
    }

    /// Windows-like size for a window that has no earlier frame to go back to: centered, 70% x 80%.
    static func defaultRestoreFrame(in wa: CGRect) -> CGRect {
        CGRect(x: wa.minX + wa.width * 0.15, y: wa.minY + wa.height * 0.1,
               width: wa.width * 0.7, height: wa.height * 0.8).integral
    }

    /// Snap Layouts: put the window into a zone (unit rect, y down) of its display's work area, then
    /// Snap Assist offers other windows for the layout's remaining zones.
    func snap(_ id: CGWindowID, zone: CGRect, layout: [CGRect]) {
        guard let e = entries[id], let f = AX.frame(e.element) else { return }
        WindowSnap.shared.snap(.init(pid: e.pid, element: e.element, id: id), zone: zone,
                               workArea: Self.workArea(for: f), layout: layout, source: "layouts")
    }

    /// Called by WindowSnap before it snaps a window: a snapped window is no longer "maximized".
    func noteSnapped(_ id: CGWindowID, from f: CGRect) {
        if !isMaximized(id, f) { normalFrames[id] = f }
        maximizedFrames[id] = nil
    }

    /// Phase 5: a window put back into a snap zone is not maximized any more.
    func forgetMaximized(_ id: CGWindowID) { maximizedFrames[id] = nil }

    /// True if the window is maximized (fills its work area, or sits where Fenestra maximized it).
    func isMaximizedFrame(_ id: CGWindowID, _ f: CGRect) -> Bool { isMaximized(id, f) }

    /// Maximized by Fenestra (not by an app or macOS Fill), and still there: dragging it away restores it.
    func maximizedByUs(_ id: CGWindowID, _ f: CGRect) -> Bool {
        maximizedFrames[id].map { Self.approx($0, f) } == true
    }

    /// Where Fenestra last maximized the window, if it did.
    func maximizedFrame(_ id: CGWindowID) -> CGRect? { maximizedFrames[id] }

    /// Frame from before the window was maximized, if known.
    func normalFrame(_ id: CGWindowID) -> CGRect? { normalFrames[id] }

    private func isMaximized(_ id: CGWindowID, _ f: CGRect) -> Bool {
        Self.approx(f, Self.workArea(for: f)) || maximizedFrames[id].map { Self.approx($0, f) } == true
    }

    private func updateMaximized(_ e: Entry) {
        let m = isMaximized(e.id, e.frame)
        e.view.maximized = m
        if !m { normalFrames[e.id] = e.frame }
    }

    // MARK: Geometry helpers

    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// AX rect (top-left origin) to Cocoa screen rect (bottom-left origin).
    func cocoaRect(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: Self.primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Windows "work area" of the display a window is on, in AX coordinates: the visible frame, minus the
    /// taskbar on the main display (0 when the taskbar auto-hides). Never a full-screen Space.
    static func workArea(for f: CGRect) -> CGRect {
        let ph = primaryHeight
        let center = NSPoint(x: f.midX, y: ph - f.midY)
        let screens = NSScreen.screens
        let screen = screens.first { $0.frame.contains(center) }
            ?? screens.max { a, b in
                let ra = a.frame.intersection(NSRect(x: f.minX, y: ph - f.maxY, width: f.width, height: f.height))
                let rb = b.frame.intersection(NSRect(x: f.minX, y: ph - f.maxY, width: f.width, height: f.height))
                return ra.width * ra.height < rb.width * rb.height
            } ?? screens[0]
        return workArea(screen: screen)
    }

    /// Work area of one display, AX coordinates.
    /// Whether macOS auto-hides the menu bar, read from the global preference (cached, refreshed when it changes).
    /// `NSScreen.visibleFrame` keeps the menu bar's 30 pt when Fenestra started while the menu bar was shown (after
    /// a quit restored it) and then hid it: maximize and snaps left a gap at the top (user report 2026-11-15).
    static var menuBarHidden: Bool = readMenuBarHidden()
    private static var menuBarObserver: NSObjectProtocol?

    static func readMenuBarHidden() -> Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return (CFPreferencesCopyAppValue("_HIHideMenuBar" as CFString, kCFPreferencesAnyApplication) as? Bool) ?? false
    }

    /// Called at launch and after Fenestra applies its macOS changes; also follows the system notification.
    static func refreshMenuBarHidden() {
        menuBarHidden = readMenuBarHidden()
        guard menuBarObserver == nil else { return }
        menuBarObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceMenuBarHidingChangedNotification"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                CaptionController.menuBarHidden = CaptionController.readMenuBarHidden()
                MenuBarBlocker.shared.update(reason: "menu bar setting changed")
            }
        }
    }

    /// Height the menu bar takes at the top of `screen` (0 while it auto-hides), not trusting a stale visibleFrame.
    static func menuBarInset(_ screen: NSScreen) -> CGFloat {
        menuBarHidden ? 0 : max(screen.frame.maxY - screen.visibleFrame.maxY, 0)
    }

    static func workArea(screen: NSScreen) -> CGRect {
        let ph = primaryHeight
        var vf = screen.visibleFrame
        // Menu bar auto-hidden: the work area reaches the top of the screen, whatever visibleFrame still says.
        if menuBarHidden, vf.maxY < screen.frame.maxY { vf.size.height = screen.frame.maxY - vf.minY }
        if TaskbarController.shared.hasTaskbar(screen) {
            let bottom = screen.frame.minY + TaskbarController.shared.reservedHeight
            if vf.minY < bottom { vf.size.height -= bottom - vf.minY; vf.origin.y = bottom }
        }
        return CGRect(x: vf.minX, y: ph - vf.maxY, width: vf.width, height: vf.height)
    }

    /// Cocoa screen rect to AX rect (top-left origin).
    static func axRect(_ r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func approx(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }

    /// Size, position, size: the second size applies once the window is on the target display
    /// (a window too big for its current display gets clamped otherwise).
    static func setFrame(_ pid: pid_t, _ w: AXUIElement, _ r: CGRect) {
        let app = AX.app(pid)
        let enhanced: Bool = AX.attr(app, "AXEnhancedUserInterface") ?? false
        if enhanced { AX.set(app, "AXEnhancedUserInterface", kCFBooleanFalse) }      // avoids slow animated resizes
        AX.setSize(w, r.size)
        AX.setPosition(w, r.origin)
        AX.setSize(w, r.size)
        if enhanced { AX.set(app, "AXEnhancedUserInterface", kCFBooleanTrue) }
    }

    static func describe(_ r: CGRect) -> String {
        "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))"
    }

    static func onscreenWindowIDs() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var out = Set<CGWindowID>()
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            if let n = w[kCGWindowNumber as String] as? CGWindowID { out.insert(n) }
        }
        return out
    }

    /// Front-to-back index of on-screen windows.
    static func onscreenOrder() -> [CGWindowID: Int] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [:] }
        var out: [CGWindowID: Int] = [:]
        for (i, w) in list.enumerated() { if let n = w[kCGWindowNumber as String] as? CGWindowID { out[n] = i } }
        return out
    }

    static func bounds(of id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let bd = list.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bd)
    }

    /// A window of the app filling a whole display (a full-screen Space elsewhere): don't quit it.
    static func hasFullScreenWindow(_ pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let displays = NSScreen.screens.compactMap { s -> CGRect? in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            return CGDisplayBounds(n)
        }
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bd) else { continue }
            if displays.contains(where: { approx($0, b) }) { return true }
        }
        return false
    }
}

/// Matches each panel's background to the window's own title bar (Screen Recording only; without it the
/// system window color is used). One small capture of the window itself (our panel isn't in it) when a
/// window first appears or changes size, then per row the most common color of the title bar the panel
/// covers (around the traffic lights), stretched across the panel, so gradients and separator lines line up.
@MainActor
final class TitleBarSampler {
    static let shared = TitleBarSampler()
    private var content: SCShareableContent?
    private var contentDate = Date.distantPast
    private var inflight: Set<CGWindowID> = []

    func sample(_ e: CaptionController.Entry) {
        guard CGPreflightScreenCaptureAccess(), !inflight.contains(e.id) else { return }
        inflight.insert(e.id)
        let id = e.id
        let stripX = e.panelSize.width + 3
        let stripH = e.panelSize.height
        let lights = e.lights
        Task { @MainActor in
            defer { TitleBarSampler.shared.inflight.remove(id) }
            guard let img = await TitleBarSampler.shared.capture(id, stripX: stripX, stripH: stripH, lights: lights),
                  let entry = CaptionController.shared.entry(id) else { return }
            if UserDefaults.standard.bool(forKey: "captionDebug"), let d = img.dataProvider?.data as Data? {
                let rows = (0..<img.height).map { r in "\(d[r * 4]),\(d[r * 4 + 1]),\(d[r * 4 + 2])" }
                Log.write("sampler: window \(id) rows top/mid/bottom \(rows.first ?? "") / \(rows[rows.count / 2]) / \(rows.last ?? "")")
            }
            entry.view.setBackground(img)
        }
    }

    private func capture(_ id: CGWindowID, stripX: CGFloat, stripH: CGFloat, lights: CGRect) async -> CGImage? {
        if content == nil || Date().timeIntervalSince(contentDate) > 2
            || content?.windows.contains(where: { $0.windowID == id }) != true {
            content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            contentDate = Date()
        }
        guard let w = content?.windows.first(where: { $0.windowID == id }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        // Only the window's top strip beside the buttons (sourceRect is window-relative for a single-window
        // filter; checked against a full capture), at 1 pixel per point.
        let width = min(stripX + 260, w.frame.width)
        guard width > stripX + 20 else { return nil }
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = CGRect(x: 0, y: 0, width: width, height: stripH + 2)
        cfg.width = Int(width)
        cfg.height = Int(stripH + 2)
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        else { return nil }
        return Self.backgroundStrip(cg, lights: lights, panelRight: stripX - 3, top: 1, height: stripH)
    }

    /// 1 px wide image of the title bar's own background, per row the most common color among:
    /// the columns the panel itself covers left of and right of the traffic lights (exactly what the buttons
    /// hide), plus a few just past the panel. Only if a row has too few opaque pixels there (rounded corner)
    /// does it widen to 260 pt on the right. Icons and title text (Terminal's blue folder, a tab label) are a
    /// minority, so they can't tint the strip; separator lines and gradients span the row and are kept.
    private static func backgroundStrip(_ img: CGImage, lights: CGRect, panelRight: CGFloat,
                                        top: CGFloat, height: CGFloat) -> CGImage? {
        let y0 = Int(top), rows = max(Int(height), 1), width = img.width
        guard width > Int(panelRight) + 8, y0 + rows <= img.height,
              let crop = img.cropping(to: CGRect(x: 0, y: y0, width: width, height: rows)) else { return nil }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var px = [UInt8](repeating: 0, count: width * rows * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &px, width: width, height: rows, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: cs, bitmapInfo: info) else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: rows))
        let right = Int(panelRight)
        var near = Array(3..<max(3, Int(lights.minX) - 2))
        if Int(lights.maxX) + 3 <= right + 6 { near += Array((Int(lights.maxX) + 3)...(right + 6)) }
        near = near.filter { $0 < width }
        let wide = Array(stride(from: right + 3, to: width, by: 3))
        var out = [UInt8](repeating: 255, count: rows * 4)
        for r in 0..<rows {
            // Bucket colors at 4 bits per channel, then average the pixels of the biggest bucket.
            func tally(_ cols: [Int]) -> [Int: (n: Int, r: Int, g: Int, b: Int)] {
                var counts: [Int: (n: Int, r: Int, g: Int, b: Int)] = [:]
                for c in cols {
                    let o = (r * width + c) * 4
                    guard px[o + 3] >= 250 else { continue }           // outside the rounded corner
                    let key = Int(px[o] >> 4) << 8 | Int(px[o + 1] >> 4) << 4 | Int(px[o + 2] >> 4)
                    var v = counts[key] ?? (0, 0, 0, 0)
                    v.n += 1; v.r += Int(px[o]); v.g += Int(px[o + 1]); v.b += Int(px[o + 2])
                    counts[key] = v
                }
                return counts
            }
            var counts = tally(near)
            if counts.values.reduce(0, { $0 + $1.n }) < 4 { counts = tally(wide) }
            guard let best = counts.values.max(by: { $0.n < $1.n }) else { continue }
            out[r * 4] = UInt8(best.r / best.n)
            out[r * 4 + 1] = UInt8(best.g / best.n)
            out[r * 4 + 2] = UInt8(best.b / best.n)
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: 1, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
