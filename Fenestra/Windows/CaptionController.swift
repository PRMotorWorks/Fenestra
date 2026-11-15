import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Phase 3: Windows 11 caption buttons in place of the traffic lights, for every window of every app.
///
/// macOS has no public way to restyle another app's title bar (and SIP stays on), so each window gets a
/// small transparent panel of ours, ordered directly above it (`order(.above, relativeTo:)`), covering the
/// traffic lights. Its position comes from the window's `kAXCloseButtonAttribute` / minimize / zoom frames.
/// Everything is event driven through the shared `WindowEvents` hub: nothing runs while idle.
/// While you drag a window by its title bar the panel moves with it: from the pointer for windows the window
/// server drags (`follow`), from the window's own position for apps that move their windows themselves
/// (`DragChaser`). A window that does neither cleanly gets the old behavior: hidden until release.
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
        var followingDrag = false              // moved by `follow` during a title bar drag
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
    /// Active (not listen-only) event tap, enabled only while a title bar press is being watched. The window
    /// server waits for it before routing each drag event and moving the dragged window, so the panel is
    /// moved first (`follow`) and both are drawn in the same frame as far as possible.
    private var dragTap: CFMachPort?
    private var upMonitor: Any?
    private var upSafetyTimer: Timer?
    /// A press in a title bar. Once the window moves, the buttons follow it (or hide until release when
    /// following is off or the window doesn't track the pointer).
    private struct Drag {
        let id: CGWindowID
        let origin: CGPoint            // window origin at mouse-down (AX)
        let mouse: CGPoint             // mouse at mouse-down (AX)
        var checks = 0
        var speculative = false        // acted on at the first drag event, before the window list confirms it
        var sure = false               // AX says empty title bar: the window will move with the pointer
        var chase = false              // the app moves its window itself (Chromium, Electron): see DragChaser
        var tops: [(x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>, top: CGFloat)] = []   // see topLimits
        var hidden = false
        var following = false
        // Following state, per axis (0 = x, 1 = y): the window sits at mouse - grab offset, within limits
        // where macOS holds it (top of the screen, say), learned from the window list as the drag goes.
        var off: [CGFloat] = [0, 0]
        var lo: [CGFloat?] = [nil, nil]
        var hi: [CGFloat?] = [nil, nil]
        var bad = [0, 0]
        var badValue: [CGFloat] = [.nan, .nan]
        var recent: [CGPoint] = []     // last panel origins set (window origins they assume)
        var lastMouse: CGPoint = .zero
        var lastTime: Double = 0
        var settle = 0                 // generation of the pending settle move
        var misses = 0
        var maxError: CGFloat = 0
        var cost: Double = 0           // seconds spent in `follow`
        var trace: [String] = []       // per event, with `captionDragTrace` on
    }
    private let traceDrags = UserDefaults.standard.bool(forKey: "captionDragTrace")
    private var dragStart = CFAbsoluteTimeGetCurrent()
    private var drag: Drag?
    private var refreshOnUp: Set<pid_t> = []
    private var validatePending: Set<Int> = []
    private var chromiumCache: [String: Bool] = [:]

    private var enabled: Bool { AppSettings.shared.captionButtons }
    /// `defaults write local.fenestra.Fenestra captionHideWhileDragging -bool true` brings back the old
    /// behavior (buttons hidden while a window is dragged). Read at each press.
    private var followDrags: Bool { !UserDefaults.standard.bool(forKey: "captionHideWhileDragging") }

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
            if let d = drag, d.id == e.id {                   // a title bar drag: followed, or hidden until release
                if !d.following { hideForDrag(e) }
                return
            }
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
        if e.shown {
            e.panel.setFrame(cocoaRect(panelRect(e)), display: false)
            _ = Self.movePanel(e.panel, to: panelRect(e).origin)    // now, not a frame later
        }
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
                if let e = entries[id], e.hiddenForDrag || e.followingDrag, NSEvent.pressedMouseButtons & 1 != 0 {
                    seen.insert(id); continue
                }
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
            guard e.shown, !e.hiddenForDrag, !e.followingDrag else { continue }
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
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { ev in
            let at = ev.cgEvent?.location             // where the press happened (the mouse may have moved since)
            MainActor.assumeIsolated { CaptionController.shared.globalMouseDown(at: at) }
        }
    }

    private func globalMouseDown(at pressed: CGPoint? = nil) {
        scheduleValidate()
        guard !entries.isEmpty else { return }
        let m = NSEvent.mouseLocation
        let p = pressed ?? CGPoint(x: m.x, y: Self.primaryHeight - m.y)
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
        drag?.lastMouse = p
        drag?.off = [p.x - target.frame.minX, p.y - target.frame.minY]
        drag?.tops = Self.topLimits()
        dragStart = CFAbsoluteTimeGetCurrent()
        // Tap first: drag events wait for it, so none slip past while the hit test below runs.
        if !enableDragTap(), dragMonitor == nil {
            dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { _ in
                MainActor.assumeIsolated {
                    let m = NSEvent.mouseLocation
                    CaptionController.shared.dragged(to: CGPoint(x: m.x, y: CaptionController.primaryHeight - m.y))
                }
            }
        }
        // Pressed on empty title bar (not a control)? Then it's a window drag: follow (or hide) from the very
        // first drag event instead of waiting to see the window move (that wait let the traffic lights flash).
        if isChromiumLike(target.pid) {
            drag?.speculative = true            // no usable AX tree: undone if the window stays put
            drag?.chase = true
        } else {
            var el: AXUIElement?
            if AXUIElementCopyElementAtPosition(AX.app(target.pid), Float(p.x), Float(p.y), &el) == .success, let el,
               let role: String = AX.attr(el, kAXRoleAttribute),
               [kAXWindowRole, kAXToolbarRole, kAXUnknownRole].contains(role) {
                drag?.speculative = true
                drag?.sure = true
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
                    case .leftMouseUp:
                        c.releasedAt(loc)               // the window makes one last move to the release point
                        DispatchQueue.main.async { MainActor.assumeIsolated { c.mouseReleased() } }
                    case .tapDisabledByTimeout, .tapDisabledByUserInput:
                        if c.drag != nil, let t = c.dragTap { CGEvent.tapEnable(tap: t, enable: true) }
                    default: break
                    }
                }
                return Unmanaged.passUnretained(event)
            }
            guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
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

    /// Drag events (from the tap, before the window server routes them). Once the window moves the buttons
    /// follow it (`follow`); a press on empty title bar is a window drag for sure, so that starts at the very
    /// first event. With following off they hide instead, as before.
    private func dragged(to mouse: CGPoint) {
        guard var d = drag, let e = entries[d.id] else { stopDragWatch(); return }
        d.checks += 1
        if d.following {
            follow(&d, e, mouse: mouse)
        } else if !d.hidden {
            let now = d.sure ? nil : Self.bounds(of: d.id)
            let moved = now.map { abs($0.minX - d.origin.x) > 1 || abs($0.minY - d.origin.y) > 1 } ?? false
            if followDrags && e.shown && e.panelSize != .zero && d.chase {
                d.following = true
                e.followingDrag = true
                DragChaser.shared.start(window: d.id, panel: e.panel.windowNumber, at: now?.origin ?? d.origin, trace: traceDrags)
                if traceDrags, let b = now {
                    d.trace.append("start (chase): window \(Int(b.minX - d.origin.x)),\(Int(b.minY - d.origin.y)) from its press position")
                    DragCapture.shared.start(at: b.origin, lights: e.lights)
                }
                DragChaser.shared.kick()
            } else if followDrags && e.shown && e.panelSize != .zero && (d.sure || moved) {
                d.following = true
                e.followingDrag = true
                if let now {                    // moved before we saw it: the grab offset as it is now
                    d.off = [d.lastMouse.x - now.minX, d.lastMouse.y - now.minY]
                }
                if traceDrags, let b = now ?? Self.bounds(of: d.id) {
                    d.trace.append("start: window \(Int(b.minX - d.origin.x)),\(Int(b.minY - d.origin.y)) from its press position, "
                                   + "\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - dragStart) * 1000)) ms after the press was seen")
                    DragCapture.shared.start(at: b.origin, lights: e.lights)
                }
                follow(&d, e, mouse: mouse)
            } else if !followDrags && (d.speculative || moved) {
                d.hidden = true
                hideForDrag(e)
            } else if d.checks > 60 {
                stopDragWatch()                 // a text selection or slider, not a window drag
                return
            }
        }
        if d.speculative && d.checks >= 6 && (d.hidden || d.following) {
            d.speculative = false
            let moved = Self.bounds(of: d.id).map { abs($0.minX - d.origin.x) > 1 || abs($0.minY - d.origin.y) > 1 } ?? true
            if !moved && abs(mouse.x - d.mouse.x) + abs(mouse.y - d.mouse.y) > 3 {
                // The mouse moved but the window didn't (dragging a tab, say): buttons back where they belong.
                if d.following {
                    if d.chase { _ = DragChaser.shared.stop() }
                    syncAfterDrag(e, at: d.origin)
                }
                e.hiddenForDrag = false
                e.followingDrag = false
                markDirty(e.pid, delay: 0)
                stopDragWatch()
                return
            }
        }
        d.lastMouse = mouse
        if d.hidden && !d.speculative { drag = d; stopDragTap(); return }   // nothing more to watch until release
        drag = d
    }

    /// Moves the panel to where this drag event puts the window, before the window server applies it (the
    /// tap is active, so the event waits for us). A window dragged by its title bar keeps the grab point
    /// under the pointer: origin = mouse - grab offset, within any limit macOS holds it at (`checkFollow`
    /// learns those). Nothing is read from the window server here: each event costs about 0.04 ms.
    /// The move goes straight to the window server (`movePanel`); through AppKit it would be sent only at the
    /// end of the run loop pass and drawn a frame late. That was the old wobble.
    private func follow(_ d: inout Drag, _ e: Entry, mouse: CGPoint, final: Bool = false) {
        if d.chase { DragChaser.shared.kick(); return }     // the window moves when its app gets to it: watch it
        let t0 = CFAbsoluteTimeGetCurrent()
        let exact = place(d, mouse)
        d.recent.append(exact)
        if d.recent.count > 4 { d.recent.removeFirst() }
        // The window is drawn a few ms after its move: place the panel that much back along the motion
        // (never past the previous position), then settle on the exact spot once the pointer stops.
        var next = exact
        let dt = t0 - d.lastTime
        if !final && Self.dragLag > 0 && dt > 0.001 && dt < 0.03 {
            let k = min(1, Self.dragLag / dt)
            next = place(d, CGPoint(x: mouse.x - (mouse.x - d.lastMouse.x) * k, y: mouse.y - (mouse.y - d.lastMouse.y) * k))
            d.settle += 1
            let gen = d.settle, id = d.id
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.dragLag + 0.008) {
                MainActor.assumeIsolated { CaptionController.shared.settleFollow(id, gen) }
            }
        }
        d.lastTime = t0
        if !Self.movePanel(e.panel, to: CGPoint(x: next.x + 1, y: next.y + 1)) {
            let r = CGRect(x: next.x + 1, y: next.y + 1, width: e.panelSize.width, height: e.panelSize.height)
            e.panel.setFrame(cocoaRect(r), display: false)
            CATransaction.flush()
        }
        d.cost += CFAbsoluteTimeGetCurrent() - t0
        if traceDrags {
            DragCapture.shared.setPanel(next)
            d.trace.append(String(format: "%.1f", (t0 - dragStart) * 1000)
                           + " mouse \(Int(mouse.x)),\(Int(mouse.y)) panel \(Int(next.x)),\(Int(next.y))")
        }
        if !checkPending {                      // after the event has gone on, so it doesn't wait for this
            checkPending = true
            DispatchQueue.main.async { MainActor.assumeIsolated { CaptionController.shared.checkFollow() } }
        }
    }
    private var checkPending = false

    /// How long after its move the dragged window is drawn, roughly (`captionDragLagMs`, default 3).
    private static let dragLag: Double = {
        let v = UserDefaults.standard.object(forKey: "captionDragLagMs") as? Double ?? 3
        return max(0, min(v, 16)) / 1000
    }()

    /// Window origin for this mouse position: grab offset, then any limit macOS holds the window at.
    private func place(_ d: Drag, _ mouse: CGPoint) -> CGPoint {
        var p = CGPoint(x: (mouse.x - d.off[0]).rounded(), y: (mouse.y - d.off[1]).rounded())
        if let t = d.tops.first(where: { $0.x.contains(mouse.x) && $0.y.contains(mouse.y) }) { p.y = max(p.y, t.top) }
        if let l = d.lo[0] { p.x = max(p.x, l) }
        if let h = d.hi[0] { p.x = min(p.x, h) }
        if let l = d.lo[1] { p.y = max(p.y, l) }
        if let h = d.hi[1] { p.y = min(p.y, h) }
        return p
    }

    /// macOS keeps a dragged window's top at or below the top of the display under the pointer (below the
    /// menu bar when it shows), unless another display sits above there. Per display: the x span with
    /// nothing above, its y span, and that top (AX coordinates).
    private static func topLimits() -> [(x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>, top: CGFloat)] {
        var out: [(x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>, top: CGFloat)] = []
        for s in NSScreen.screens {
            let f = axRect(s.frame)
            var spans: [ClosedRange<CGFloat>] = [f.minX...f.maxX]
            for o in NSScreen.screens where o != s {
                let g = axRect(o.frame)
                guard abs(g.maxY - f.minY) < 1, g.minX < f.maxX, g.maxX > f.minX else { continue }
                spans = spans.flatMap { r -> [ClosedRange<CGFloat>] in
                    var parts: [ClosedRange<CGFloat>] = []
                    if g.minX > r.lowerBound { parts.append(r.lowerBound...min(g.minX, r.upperBound)) }
                    if g.maxX < r.upperBound { parts.append(max(g.maxX, r.lowerBound)...r.upperBound) }
                    return parts
                }
            }
            for x in spans { out.append((x, f.minY...f.maxY, f.minY + menuBarInset(s))) }
        }
        return out
    }

    /// No newer drag event since: put the panel exactly where the window is.
    private func settleFollow(_ id: CGWindowID, _ gen: Int) {
        guard let d = drag, d.id == id, d.following, d.settle == gen, let e = entries[id], let p = d.recent.last else { return }
        _ = Self.movePanel(e.panel, to: CGPoint(x: p.x + 1, y: p.y + 1))
        if traceDrags { DragCapture.shared.setPanel(p) }
    }

    /// The mouse-up from the tap, before it is routed: one last exact placement.
    fileprivate func releasedAt(_ mouse: CGPoint) {
        guard var d = drag, d.following, let e = entries[d.id] else { return }
        if d.chase { DragChaser.shared.kick(); return }
        if abs(mouse.x - d.lastMouse.x) + abs(mouse.y - d.lastMouse.y) > 0 || Self.dragLag > 0 {
            d.settle += 1
            follow(&d, e, mouse: mouse, final: true)
            d.lastMouse = mouse
            drag = d
        }
    }

    /// PRIVATE: SkyLight's `SLSMoveWindow` on our own panel (AX coordinates, top-left). It takes effect in the
    /// window server at once (0.002 ms, verified with the window list). A move through AppKit, even flushed
    /// with `CATransaction.flush()`, went through a transaction and was drawn a frame late: frame captures
    /// of real drags showed the traffic lights peeking past the buttons (2026-11-15). AppKit's own idea of
    /// the panel's frame goes stale meanwhile; `syncAfterDrag` puts it right on release.
    /// `defaults write local.fenestra.Fenestra captionDragMove appkit` uses the AppKit path instead.
    private typealias MainConn = @convention(c) () -> Int32
    private typealias MoveWindow = @convention(c) (Int32, UInt32, UnsafePointer<CGPoint>) -> Int32
    private nonisolated static let sls: (MainConn, MoveWindow)? = {
        guard UserDefaults.standard.string(forKey: "captionDragMove") != "appkit",
              let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let c = dlsym(h, "SLSMainConnectionID"), let m = dlsym(h, "SLSMoveWindow") else { return nil }
        return (unsafeBitCast(c, to: MainConn.self), unsafeBitCast(m, to: MoveWindow.self))
    }()

    private static func movePanel(_ panel: NSPanel, to p: CGPoint) -> Bool {
        moveWindow(panel.windowNumber, to: p)
    }

    /// Any thread (DragChaser calls it from its own queue).
    nonisolated static func moveWindow(_ number: Int, to p: CGPoint) -> Bool {
        guard let (conn, move) = sls, number > 0 else { return false }
        var pt = p
        return move(conn(), UInt32(number), &pt) == 0
    }

    /// DragSnap gave the dragged window back its size under the pointer, mid-drag. Where macOS then keeps it
    /// relative to the pointer isn't predictable, so from here on watch the window itself (DragChaser).
    func dragWindowMoved(_ id: CGWindowID, to origin: CGPoint) {
        guard var d = drag, d.id == id, d.following, !d.chase, let e = entries[id] else { return }
        d.chase = true
        drag = d
        _ = Self.movePanel(e.panel, to: CGPoint(x: origin.x + 1, y: origin.y + 1))
        DragChaser.shared.start(window: id, panel: e.panel.windowNumber, at: origin, trace: traceDrags)
        DragChaser.shared.kick()
    }

    /// After a followed drag: tell AppKit where the panel really is (SLSMoveWindow bypassed it), so its next
    /// setFrame isn't skipped as "unchanged" and hover tracking uses the right frame.
    private func syncAfterDrag(_ e: Entry, at origin: CGPoint) {
        let r = CGRect(x: origin.x + 1, y: origin.y + 1, width: e.panelSize.width, height: e.panelSize.height)
        e.panel.setFrame(cocoaRect(r), display: false)
        _ = Self.movePanel(e.panel, to: r.origin)      // in case AppKit thought it was there already
    }

    /// Compares where the window server has the window with the panel positions just set (the list can be
    /// an event or two behind, so any of the last four counts). Held on an axis twice running (top of the
    /// screen, another display's edge): that becomes a limit. Moving but elsewhere (its size was restored
    /// under the pointer): a new grab offset. A window that keeps missing (the app moves it itself, late)
    /// gets the old behavior: hidden until release.
    private func checkFollow() {
        checkPending = false
        guard var d = drag, d.following, !d.chase, let e = entries[d.id], let a = Self.bounds(of: d.id)?.origin,
              !d.recent.isEmpty else { return }
        let actual = [a.x, a.y]
        var off: CGFloat = 0
        for i in 0..<2 {
            let v = actual[i]
            if let h = d.hi[i], v > h + 1 { d.hi[i] = nil }
            if let l = d.lo[i], v < l - 1 { d.lo[i] = nil }
            let ps = d.recent.map { i == 0 ? $0.x : $0.y }
            let lo = ps.min()! - 1.5, hi = ps.max()! + 1.5
            if v >= lo && v <= hi { d.bad[i] = 0; d.badValue[i] = .nan; continue }
            off = max(off, v < lo ? lo - v : v - hi)
            d.bad[i] += 1
            if d.bad[i] >= 2 {
                let m = i == 0 ? d.lastMouse.x : d.lastMouse.y
                let raw = m - d.off[i]
                if abs(v - d.badValue[i]) < 0.5 {
                    if raw > v { d.hi[i] = v } else { d.lo[i] = v }     // held there by macOS
                } else {
                    d.off[i] = m - v                                    // moved, with a new grab offset
                }
                d.bad[i] = 0
                d.badValue[i] = .nan
            } else {
                d.badValue[i] = v
            }
        }
        if off > 0 {
            d.misses += 1
            d.maxError = max(d.maxError, off)
        }
        if traceDrags { d.trace.append("  window \(Int(a.x)),\(Int(a.y))" + (off > 0 ? " off by \(Int(off))" : "")) }
        if d.misses >= 8 && d.misses * 3 > d.checks {
            // This window doesn't move with the pointer: hide instead.
            Log.write("captions drag: window \(d.id) doesn't track the pointer (\(d.misses) misses in \(d.checks) events), hiding")
            syncAfterDrag(e, at: a)
            d.following = false
            e.followingDrag = false
            d.hidden = true
            hideForDrag(e)
        }
        drag = d
    }

    private func stopDragTap() {
        if let m = dragMonitor { NSEvent.removeMonitor(m); dragMonitor = nil }
        if let t = dragTap { CGEvent.tapEnable(tap: t, enable: false) }
    }

    private func stopDragWatch() {
        if drag?.chase == true { _ = DragChaser.shared.stop() }
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
        if var d = drag, d.hidden || d.following, let e = entries[d.id] {
            pids.insert(e.pid)                  // show again / settle at the window's final frame
            if d.following {
                if d.chase {
                    // The app may still move its window to where the button came up: keep watching a moment.
                    DragChaser.shared.kick(for: 0.08)
                    let id = d.id, gen = DragChaser.shared.gen
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        MainActor.assumeIsolated {
                            let c = CaptionController.shared
                            let (last, stats) = DragChaser.shared.stop(gen: gen)
                            if last != nil, let e = c.entries[id], c.drag == nil, let now = Self.bounds(of: id)?.origin {
                                c.syncAfterDrag(e, at: now)
                            }
                            if c.traceDrags { Log.write("captions drag: \(stats)") }
                        }
                    }
                    d.chase = false                 // so stopDragWatch below leaves the chase running
                    drag = d
                } else if let now = Self.bounds(of: d.id)?.origin ?? d.recent.last {
                    syncAfterDrag(e, at: now)       // where the window is now (a snap may have moved it already)
                }
                let n = max(d.checks, 1)
                Log.write("captions drag: followed window \(d.id), \(d.checks) events, \(d.misses) checks off by more than 1.5 pt, "
                          + "max \(Int(d.maxError)) pt, \(String(format: "%.2f", d.cost / Double(n) * 1000)) ms per event")
            } else if debug { Log.write("captions drag: window \(d.id) hidden for the drag, events=\(d.checks)") }
            if traceDrags { DragCapture.shared.stop() }
            if traceDrags && !d.trace.isEmpty {
                let name = NSRunningApplication(processIdentifier: e.pid)?.localizedName ?? "?"
                let text = "drag of \(d.id) (\(name)) at \(Date()), misses \(d.misses)\n" + d.trace.joined(separator: "\n") + "\n\n"
                let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Fenestra-follow.txt")
                if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
                else { try? text.write(to: url, atomically: true, encoding: .utf8) }
            }
        }
        stopDragWatch()
        refreshOnUp = []
        for e in entries.values where e.hiddenForDrag || e.followingDrag {
            e.hiddenForDrag = false
            e.followingDrag = false
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
        // Snaps, maximize, restore: keep the buttons on the window while it moves into place (the AX move
        // event comes later, and an AppKit move is drawn a frame late), so the traffic lights don't flash.
        if let id = AX.windowID(w), let e = shared.entries[id], e.shown {
            DragChaser.shared.watch(window: id, panel: e.panel.windowNumber, for: 0.25)
        }
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

/// Follows a window its app moves itself during a drag (Chromium and Electron move theirs a mouse event
/// late, and unevenly, so the pointer can't predict them). While the drag is active and for 40 ms after each
/// drag event, it reads the window's position from the window server every 0.6 ms on its own queue and moves
/// the caption panel there with SLSMoveWindow the moment it changes, so both are drawn in the same frame.
/// Nothing runs between drags.
final class DragChaser: @unchecked Sendable {
    static let shared = DragChaser()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "fenestra.dragchase", qos: .userInteractive)
    private var window: CGWindowID = 0
    private var panel = 0
    private var last: CGPoint?
    private var until: Double = 0
    private var active = false, running = false, trace = false
    private var polls = 0, moves = 0
    private var generation = 0
    var gen: Int { lock.lock(); defer { lock.unlock() }; return generation }

    func start(window id: CGWindowID, panel number: Int, at origin: CGPoint, trace t: Bool) {
        lock.lock()
        generation += 1
        window = id; panel = number; last = origin; active = true; trace = t; polls = 0; moves = 0
        lock.unlock()
    }

    /// Outside a drag (Fenestra just moved the window): follow it for a moment.
    func watch(window id: CGWindowID, panel number: Int, for seconds: Double) {
        lock.lock()
        generation += 1
        window = id; panel = number; last = nil; active = true; trace = false
        lock.unlock()
        kick(for: seconds)
    }

    func kick(for seconds: Double = 0.04) {
        lock.lock()
        until = CFAbsoluteTimeGetCurrent() + seconds
        let go = active && !running
        if go { running = true }
        lock.unlock()
        if go { queue.async { self.loop() } }
    }

    /// Ends the chase; the panel's last position (window origin) and a line of stats.
    func stop(gen g: Int? = nil) -> (CGPoint?, String) {
        lock.lock()
        if let g, g != generation { lock.unlock(); return (nil, "chase: superseded") }
        active = false
        let r = (last, "chase: \(polls) reads, \(moves) moves")
        lock.unlock()
        return r
    }

    private func loop() {
        while true {
            lock.lock()
            guard active, CFAbsoluteTimeGetCurrent() < until else { running = false; lock.unlock(); return }
            let id = window, number = panel, prev = last, t = trace
            polls += 1
            lock.unlock()
            if let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
               let bd = list.first?[kCGWindowBounds as String] as? NSDictionary,
               let b = CGRect(dictionaryRepresentation: bd), b.origin != prev {
                _ = CaptionController.moveWindow(number, to: CGPoint(x: b.minX + 1, y: b.minY + 1))
                if t { DragCapture.shared.setPanel(b.origin) }
                lock.lock()
                if active { last = b.origin; moves += 1 }
                lock.unlock()
            }
            usleep(600)
        }
    }
}
