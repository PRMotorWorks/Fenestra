import AppKit

/// Middle-click a link in a web browser: opens it in a new window, as the user asked (browsers on their own open a
/// background tab). Middle-click a tab is left to the browser: Safari, Chrome, Brave, Edge and Firefox already
/// close it (checked on 2026-11-18 in Safari 26 and Brave).
///
/// An active `CGEventTap` on middle presses only, on its own thread. A press whose topmost window under the pointer
/// is a known browser's normal window (window list, about 3 ms) is held back. Accessibility then says what is under
/// the pointer (20 to 60 ms, on `queue`, never on the tap thread):
///   - a link with an http, https or file address (not an anchor in the same page, nor `javascript:`) gets the
///     browser's own new-window click: Shift+click, or Command+Option+Shift+click in Safari (new window in front);
///   - anything else gets the held press (and release) replayed, so tabs close and pages behave as before.
/// Events Fenestra posts carry `marker` and pass the tap untouched. Other apps' middle presses (Blender or CAD
/// panning, for example) are never held, and nothing is held while the setting is off.
final class MiddleClick: @unchecked Sendable {
    static let shared = MiddleClick()
    private static let marker: Int64 = 0x4645_4E4D           // "FENM"

    enum Kind { case safari, shiftClick }
    private enum Decision { case waiting, link, native }
    private struct Held {
        let id: Int
        let pid: pid_t
        let kind: Kind
        let point: CGPoint
        let down: CGEvent
        var up: CGEvent?
        var decision: Decision
    }

    private let lock = NSLock()
    // Guarded by `lock`.
    private var enabled = true
    private var browsers: [pid_t: Kind] = [:]
    private var held: Held?
    private var nextID = 0

    nonisolated(unsafe) private static var tap: CFMachPort?
    private let queue = DispatchQueue(label: "Fenestra middle click", qos: .userInteractive)
    private var started = false

    /// Browsers whose "open link in new window" click is known. Chromium and Firefox: Shift+click.
    static func kind(_ bundleID: String) -> Kind? {
        if bundleID == "com.apple.Safari" || bundleID == "com.apple.SafariTechnologyPreview" { return .safari }
        let shift = ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
                     "com.operasoftware.Opera", "org.chromium.Chromium", "org.mozilla.firefox",
                     "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"]
        return shift.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") } ? .shiftClick : nil
    }

    @MainActor
    func start() {
        guard !started, AXIsProcessTrusted() else { return }
        started = true
        configure()
        refreshBrowsers()
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MiddleClick.shared.refreshBrowsers() }
            }
        }
        let t = Thread {
            let mask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
                | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
            let cb: CGEventTapCallBack = { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let t = MiddleClick.tap { CGEvent.tapEnable(tap: t, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                return MiddleClick.shared.handle(type, event) ? nil : Unmanaged.passUnretained(event)
            }
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: mask, callback: cb, userInfo: nil) else {
                Log.write("middleclick: event tap unavailable (Accessibility?)")
                return
            }
            MiddleClick.tap = tap
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            Log.write("middleclick: started (links open in a new window: \(MiddleClick.shared.isEnabled))")
            CFRunLoopRun()
        }
        t.name = "Fenestra middle click"
        t.qualityOfService = .userInteractive
        t.start()
    }

    @MainActor
    func configure() {
        let on = AppSettings.shared.browserMiddleClick
        lock.withLock { enabled = on; if !on { held = nil } }
    }

    private var isEnabled: Bool { lock.withLock { enabled } }

    @MainActor
    private func refreshBrowsers() {
        var found: [pid_t: Kind] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier, let k = Self.kind(id) { found[app.processIdentifier] = k }
        }
        lock.withLock { browsers = found }
    }

    // MARK: Tap thread

    /// Returns true to swallow the event.
    private func handle(_ type: CGEventType, _ e: CGEvent) -> Bool {
        guard e.getIntegerValueField(.mouseEventButtonNumber) == 2,
              e.getIntegerValueField(.eventSourceUserData) != Self.marker else { return false }
        if type == .otherMouseUp {
            return lock.withLock {
                guard var h = held else { return false }
                switch h.decision {
                case .waiting: h.up = e.copy(); held = h; return true     // replayed or dropped with the decision
                case .link: held = nil; return true
                case .native: held = nil; return false                    // the replayed press is already out
                }
            }
        }
        guard type == .otherMouseDown else { return false }
        let (on, known) = lock.withLock { (enabled, browsers) }
        guard on, !known.isEmpty, let (pid, kind) = Self.browserWindow(at: e.location, known),
              let copy = e.copy() else {
            lock.withLock { held = nil }
            return false
        }
        let id: Int = lock.withLock {
            nextID += 1
            held = Held(id: nextID, pid: pid, kind: kind, point: e.location, down: copy, up: nil, decision: .waiting)
            return nextID
        }
        queue.async { self.decide(id) }
        return true
    }

    /// The topmost window under `p` takes the click: a known browser's normal window, or nothing for Fenestra.
    private static func browserWindow(at p: CGPoint, _ known: [pid_t: Kind]) -> (pid_t, Kind)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for w in list {
            guard (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bd), b.contains(p) else { continue }
            guard (w[kCGWindowLayer as String] as? Int) == 0, let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let kind = known[pid] else { return nil }
            return (pid, kind)
        }
        return nil
    }

    // MARK: Decision (on `queue`)

    private func decide(_ id: Int) {
        guard let h = lock.withLock({ held?.id == id ? held : nil }) else { return }
        let link = Self.linkAt(h.point, pid: h.pid, kind: h.kind)
        let current: Bool = lock.withLock {
            guard var cur = held, cur.id == id else { return false }
            if link != nil {
                cur.decision = .link
                held = cur.up == nil ? cur : nil
            } else {
                // Replayed inside the lock, so a release arriving now can't overtake the press.
                Self.post(cur.down)
                if let up = cur.up { Self.post(up); held = nil } else { cur.decision = .native; held = cur }
            }
            return true
        }
        guard current, let link else { return }
        Self.newWindowClick(at: h.point, kind: h.kind)
        Log.write("middleclick: new window for a \(link.scheme ?? "?") link (pid \(h.pid))")   // no host: browsing stays private
    }

    private static func post(_ e: CGEvent) {
        e.setIntegerValueField(.eventSourceUserData, value: marker)
        e.post(tap: .cghidEventTap)
    }

    /// The browser's own "open in new window" click at `p`.
    private static func newWindowClick(at p: CGPoint, kind: Kind) {
        let flags: CGEventFlags = kind == .safari ? [.maskCommand, .maskAlternate, .maskShift] : .maskShift
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            else { continue }
            e.flags = flags
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            post(e)
            if type == .leftMouseDown { usleep(15_000) }
        }
    }

    // MARK: Accessibility

    /// The address of the link under `p`, if it is one a new window can open.
    private static func linkAt(_ p: CGPoint, pid: pid_t, kind: Kind) -> URL? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var el = hit(app, p)
        // Chromium builds a page's accessibility tree only once something asks: the first hit then stops at the
        // scroll area around the page. Ask once more after it has had a moment.
        if kind == .shiftClick, let e = el, string(e, kAXRoleAttribute) == kAXScrollAreaRole as String {
            usleep(120_000)
            el = hit(app, p)
        }
        guard var cur = el else { return nil }
        for _ in 0..<6 {
            let role = string(cur, kAXRoleAttribute)
            if role == "AXLink" { return usable(url(cur), in: cur) }
            if role == "AXWebArea" || role == kAXWindowRole as String { return nil }
            guard let parent = element(cur, kAXParentAttribute) else { return nil }
            cur = parent
        }
        return nil
    }

    /// http, https or file, and not an anchor in the page itself (those are often script buttons).
    private static func usable(_ u: URL?, in link: AXUIElement) -> URL? {
        guard let u, let scheme = u.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { return nil }
        if u.fragment != nil, let page = pageURL(link), sansFragment(page) == sansFragment(u) { return nil }
        return u
    }

    private static func pageURL(_ el: AXUIElement) -> URL? {
        var cur = el
        for _ in 0..<40 {
            guard let parent = element(cur, kAXParentAttribute) else { return nil }
            if string(parent, kAXRoleAttribute) == "AXWebArea" { return url(parent) }
            cur = parent
        }
        return nil
    }

    private static func sansFragment(_ u: URL) -> String {
        u.absoluteString.split(separator: "#", maxSplits: 1).first.map(String.init) ?? u.absoluteString
    }

    private static func hit(_ app: AXUIElement, _ p: CGPoint) -> AXUIElement? {
        var el: AXUIElement?
        return AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &el) == .success ? el : nil
    }

    private static func value(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private static func string(_ el: AXUIElement, _ name: String) -> String? { value(el, name) as? String }

    private static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = value(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func url(_ el: AXUIElement) -> URL? {
        guard let v = value(el, "AXURL") else { return nil }
        if CFGetTypeID(v) == CFURLGetTypeID() { return (v as! URL) }
        return (v as? String).flatMap(URL.init(string:))
    }
}
