import AppKit
import ApplicationServices
import SwiftUI

/// Windows 11 drag snapping: drag a window until the pointer touches a display edge and a translucent
/// preview shows where it will go (left/right edge: half, corner: quarter, top edge: maximize); let go and it
/// snaps there, then Snap Assist offers the other windows. Dragging toward the top center shows the snap
/// layouts bar; drop on one of its zones. Dragging a window Fenestra snapped or maximized gives it its earlier
/// size back.
///
/// A drag is recognized the same way the caption buttons hide (`CaptionController.windowMoved`): a window
/// moves (shared `WindowEvents` hub) while the left button is down. Only during such a drag a listen-only
/// event tap follows the pointer. Nothing runs otherwise.
@MainActor
final class DragSnap {
    static let shared = DragSnap()

    private struct Session {
        let target: WindowSnap.Target
        var size: CGSize
        var resized = false
        var ignoreResizeUntil = Date.distantPast
        // One log line per drag (user report 2026-11-15, quick drags not snapping): how it ended.
        var started = Date()
        var events = 0
        var last: CGPoint = .zero
        /// Recent pointer positions with their event time (ns), for throws.
        var samples: [(point: CGPoint, time: UInt64)] = []
    }

    struct Zone: Equatable {
        let unit: CGRect
        let workArea: CGRect
        let layout: [CGRect]?
        /// Picked in the snap bar at the top: the dragged window covers most of the screen there, so the preview
        /// goes in front of it (user, 2026-11-15). Edge and corner drags keep it behind, as on Windows 11.
        var fromBar = false
    }

    private var session: Session?
    private var zone: Zone?
    private var pending: Zone?
    private var pendingTimer: Timer?
    private var tap: CFMachPort?
    private var upTimer: Timer?
    private let preview = SnapPreview()
    private let bar = SnapBar()
    /// Diagnostics: the snap layouts bar's expanded frame (AX) and tile size.
    var debugBar: (CGRect, CGSize) { bar.debugGeometry }
    private var started = false
    private let ownPid = ProcessInfo.processInfo.processIdentifier

    /// Pointer distance from an edge that counts as touching it (the pointer stops at an outer edge).
    private let edge: CGFloat = 3
    /// At an edge shared with another display the pointer passes straight through, so there it has to rest
    /// within 6 pt for a moment.
    private let sharedEdge: CGFloat = 6
    private let sharedDwell: TimeInterval = 0.3
    /// How close to a corner (along the edge) gives a quarter instead of a half.
    private let corner: CGFloat = 64

    /// Last left-button press and release in other apps (AX coordinates, uptime), for quick flicks: macOS reports
    /// window moves in batches about every 0.1 s, so a window flicked to an edge and released faster than that
    /// reports its first move after the release (user report 2026-11-15: quick drags didn't snap).
    private struct Click { let point: CGPoint; let time: TimeInterval }
    private var lastDown: Click?
    private var lastUp: Click?
    private var handledUp: TimeInterval = 0
    private var clickMonitor: Any?
    /// Pointer positions while the left button is held and moving, from the moment it was pressed (the last 32).
    /// Only drag events reach this, so it costs nothing while you aren't dragging. Lets a drag whose first window
    /// move arrives late (after a few idle seconds macOS reports it after the release) still be judged as a throw.
    private var pressSamples: [(point: CGPoint, time: UInt64)] = []
    /// The window under the pointer when the button went down (window list, no Accessibility round trip), and
    /// when a drag was last handled. After a few idle seconds an app may report its window's move seconds late,
    /// or not before the next one: the release itself then checks whether that window moved with the pointer.
    private var downWindow: (id: CGWindowID, pid: pid_t, bounds: CGRect)?
    private var handledAt: TimeInterval = 0

    func start() {
        guard !started, WindowEvents.shared.isRunning else { return }
        started = true
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { e in
            let p = e.locationInWindow              // global events: screen coordinates at the time of the event
            let c = Click(point: CGPoint(x: p.x, y: CaptionController.primaryHeight - p.y), time: e.timestamp)
            MainActor.assumeIsolated {
                let d = DragSnap.shared
                switch e.type {
                case .leftMouseDown:
                    d.lastDown = c
                    d.pressSamples.removeAll(keepingCapacity: true)
                    d.downWindow = AppSettings.shared.snapWindows ? DragSnap.windowAt(c.point, own: d.ownPid) : nil
                case .leftMouseUp:
                    d.lastUp = c
                    if d.downWindow != nil {
                        // After the normal drag handling and the late-report rescue had their chance.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            MainActor.assumeIsolated { DragSnap.shared.releaseCheck(c) }
                        }
                    }
                default:
                    d.pressSamples.append((c.point, UInt64(e.timestamp * 1e9)))
                    if d.pressSamples.count > 32 { d.pressSamples.removeFirst() }
                }
            }
        }
        WindowEvents.shared.subscribe { kind, pid, el in
            switch kind {
            case .moved: DragSnap.shared.moved(pid, el)
            case .resized: DragSnap.shared.resized(el)
            default: break
            }
        }
    }

    // MARK: Drag recognition

    private func moved(_ pid: pid_t, _ el: AXUIElement) {
        guard session == nil, pid != ownPid, AppSettings.shared.snapWindows else { return }
        guard NSEvent.pressedMouseButtons & 1 != 0 else { quickDrag(pid, el); return }
        guard
              (AX.attr(el, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole,
              AX.isSettable(el, kAXSizeAttribute),
              let id = AX.windowID(el), let f = AX.frame(el) else { return }
        // Windows snaps windows dragged by the title bar. The grab point stays put relative to the window
        // during a drag, so it must be in the top band and not on an edge (that would be a resize).
        let m = Self.mouse()
        let dy = m.y - f.minY
        guard dy >= 4, dy <= 100, m.x - f.minX >= 6, f.maxX - m.x >= 6 else { return }
        SnapAssist.shared.dismiss()
        var s = Session(target: .init(pid: pid, element: el, id: id), size: f.size)
        s.samples = Array(pressSamples.suffix(16))     // movement before the late first window move
        restoreSizeForDrag(&s, f)
        session = s
        enableTap()
    }

    /// The first move of a window arrived after the button was already released: a quick flick. If it was dragged by
    /// its title bar and released at a screen edge or corner, snap it there (no preview: it's over already).
    private func quickDrag(_ pid: pid_t, _ el: AXUIElement) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let up = lastUp, let down = lastDown, down.time < up.time, up.time != handledUp,
              now - up.time < 1.0, up.time - down.time < 1.5,
              hypot(up.point.x - down.point.x, up.point.y - down.point.y) > 30,
              (AX.attr(el, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole,
              AX.isSettable(el, kAXSizeAttribute),
              let id = AX.windowID(el), let f = AX.frame(el) else { return }
        if let e = lastEnded, e.id == id, now - e.time < 1.0 { return }      // its drag session handled it
        // Grabbed by the title bar: the release point sits in the top band of where the window ended up.
        let dy = up.point.y - f.minY
        guard dy >= 4, dy <= 100, up.point.x - f.minX >= 6, f.maxX - up.point.x >= 6 else { return }
        handledUp = up.time
        handledAt = now
        let ms = Int((now - up.time) * 1000)
        var note = "released at the edge"
        var zone = edgeZone(at: up.point)
        if zone == nil, AppSettings.shared.snapThrow, let m = magnetZone(up.point) {
            zone = m
            note = "\(Int(topMagnet)) pt top magnet"
        } else if zone == nil, AppSettings.shared.snapThrow, let t = throwZone(pressSamples) {
            zone = t.zone
            note = t.note
        }
        guard let z = zone else {
            Log.write("drag: \(id) first move came \(ms) ms after the release at \(Int(up.point.x)),\(Int(up.point.y)), "
                      + "no zone (\(throwMiss))")
            return
        }
        Log.write("snap (drag): quick drag of \(id), first move came \(ms) ms after the release (\(note))")
        WindowSnap.shared.snap(.init(pid: pid, element: el, id: id), zone: z.unit, workArea: z.workArea,
                               layout: z.layout, source: "quick drag")
    }

    /// CGEvent timestamps are documented as nanoseconds but are mach ticks on some Macs (24 MHz on Apple silicon):
    /// whichever clock the value is closer to now decides, and ticks are converted.
    nonisolated static func nanos(_ ts: UInt64) -> UInt64 {
        let ticks = mach_absolute_time(), ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let dTicks = ts > ticks ? ts - ticks : ticks - ts
        let dNs = ts > ns ? ts - ns : ns - ts
        guard dTicks < dNs else { return ts }
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return ts &* UInt64(tb.numer) / UInt64(max(tb.denom, 1))
    }

    /// Quick snap top magnet: letting go within `topMagnet` below the top of a display counts as touching it, at
    /// any speed (the menu bar is hidden there). Thresholds: `QuickSnap.Tuning`.
    private func magnetZone(_ p: CGPoint) -> Zone? {
        guard let screen = NSScreen.screens.first(where: { CaptionController.axRect($0.frame).contains(p) }) else {
            return nil
        }
        let sf = CaptionController.axRect(screen.frame)
        guard p.y - sf.minY <= topMagnet else { return nil }
        return edgeZone(at: CGPoint(x: p.x, y: sf.minY))
    }
    /// Quick snap thresholds from Settings (Normal: misses were released 260 to 450 pt short at 2000+ pt/s, or
    /// slowed to 900 to 1100 pt/s 81 to 99 pt short, or stopped 24 to 37 pt below the top).
    private var tune: QuickSnap.Tuning { AppSettings.shared.quickSnap.tuning }
    private var throwAhead: Double { tune.throwAhead }
    private var throwReach: CGFloat { tune.throwReach }
    private var throwSpeed: CGFloat { tune.throwSpeed }
    private var nearEdge: CGFloat { tune.nearEdge }
    private var nearSpeed: CGFloat { tune.nearSpeed }
    private var nearTravel: CGFloat { tune.nearTravel }
    private var topMagnet: CGFloat { tune.topMagnet }
    /// Why the last throw check found nothing (for the drag log line).
    private var throwMiss = ""
    /// The window whose drag session just ended, and when (uptime): the rescue skips it.
    private var lastEnded: (id: CGWindowID, time: TimeInterval)?

    /// Where a window released mid-drag was heading: the pointer's speed over the last 0.1 s, followed for up to
    /// 0.3 s (at most 600 pt). If that reaches an outer edge of the same display, the zone there. Windows has no
    /// throw; the user asked for it (2026-11-15) because fast drags were released just short of the edge.
    private func throwZone(_ samples: [(point: CGPoint, time: UInt64)]) -> (zone: Zone, note: String)? {
        throwMiss = "no pointer samples"
        guard let b = samples.last else { return nil }
        let recent = samples.filter { b.time &- $0.time <= 100_000_000 && $0.time <= b.time }
        throwMiss = "\(recent.count) recent samples"
        guard recent.count >= 3, let a = recent.first else { return nil }
        let dt = Double(b.time &- a.time) / 1e9
        guard dt >= 0.015 else { return nil }
        let vx = (b.point.x - a.point.x) / dt, vy = (b.point.y - a.point.y) / dt
        let speed = hypot(vx, vy)
        throwMiss = "moving \(Int(vx)),\(Int(vy)) pt/s"
        guard let screen = NSScreen.screens.first(where: { CaptionController.axRect($0.frame).contains(b.point) })
        else { return nil }
        let sf = CaptionController.axRect(screen.frame)
        // Close call: near an outer edge and still heading for it, or having come toward it over the last
        // 0.25 s (throws slow down or veer sideways in the last instant: misses at 66 to 115 pt short).
        let span = samples.filter { b.time &- $0.time <= 250_000_000 && $0.time <= b.time }
        let o = span.first?.point ?? b.point
        let up = o.y - b.point.y, left = o.x - b.point.x, right = b.point.x - o.x
        var close: [(d: CGFloat, point: CGPoint)] = []
        if -vy >= nearSpeed || up >= nearTravel { close.append((b.point.y - sf.minY, CGPoint(x: b.point.x, y: sf.minY))) }
        if -vx >= nearSpeed || left >= nearTravel { close.append((b.point.x - sf.minX, CGPoint(x: sf.minX, y: b.point.y))) }
        if vx >= nearSpeed || right >= nearTravel { close.append((sf.maxX - 1 - b.point.x, CGPoint(x: sf.maxX - 1, y: b.point.y))) }
        for c in close.filter({ $0.d >= 0 && $0.d <= nearEdge }).sorted(by: { $0.d < $1.d }) {
            if let z = edgeZone(at: c.point) {
                return (z, "let go \(Int(c.d)) pt short of the edge, moving \(Int(speed)) pt/s, "
                        + "\(Int(up)) pt up in 0.25 s")
            }
        }
        guard speed >= throwSpeed else { return nil }
        // Time until the path meets each edge it is heading to; the first one wins.
        var hits: [(t: Double, point: CGPoint)] = []
        if vx < 0 { let t = (sf.minX - b.point.x) / vx; hits.append((t, CGPoint(x: sf.minX, y: b.point.y + vy * t))) }
        if vx > 0 { let t = (sf.maxX - 1 - b.point.x) / vx; hits.append((t, CGPoint(x: sf.maxX - 1, y: b.point.y + vy * t))) }
        if vy < 0 { let t = (sf.minY - b.point.y) / vy; hits.append((t, CGPoint(x: b.point.x + vx * t, y: sf.minY))) }
        guard let hit = hits.filter({ $0.t >= 0 }).min(by: { $0.t < $1.t }) else { return nil }
        throwMiss += ", edge \(Int(speed * hit.t)) pt / \(Int(hit.t * 1000)) ms ahead"
        guard hit.t <= throwAhead, speed * hit.t <= throwReach else { return nil }
        let p = CGPoint(x: min(max(hit.point.x, sf.minX), sf.maxX - 1), y: min(max(hit.point.y, sf.minY), sf.maxY - 1))
        guard let z = edgeZone(at: p) else { return nil }
        return (z, "thrown at \(Int(speed)) pt/s, \(Int(speed * hit.t)) pt short of the edge")
    }

    /// Frontmost normal window of another app under `p` (AX coordinates), from the window list.
    nonisolated static func windowAt(_ p: CGPoint, own: pid_t) -> (id: CGWindowID, pid: pid_t, bounds: CGRect)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bd), b.width > 100, b.height > 60, b.contains(p) else { continue }
            return (id, pid, b)
        }
        return nil
    }

    /// 0.15 s after a release no drag handling picked up: did the window under the press move with the pointer
    /// (a title bar drag whose move macOS hasn't reported)? Then the same edge, magnet and throw rules apply.
    private func releaseCheck(_ up: Click) {
        guard let dw = downWindow, let down = lastDown, AppSettings.shared.snapWindows,
              handledAt < up.time - 0.05, session == nil else { return }
        downWindow = nil
        let delta = CGPoint(x: up.point.x - down.point.x, y: up.point.y - down.point.y)
        let grab = down.point.y - dw.bounds.minY
        guard hypot(delta.x, delta.y) > 30, grab >= 4, grab <= 100,
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], dw.id) as? [[String: Any]])?.first,
              let bd = info[kCGWindowBounds as String] as? NSDictionary,
              let now = CGRect(dictionaryRepresentation: bd) else { return }
        let moved = CGPoint(x: now.minX - dw.bounds.minX, y: now.minY - dw.bounds.minY)
        // Moved with the pointer (allowing for the menu bar and edges holding it back a little).
        guard abs(moved.x - delta.x) < 60, abs(moved.y - delta.y) < 60 else { return }
        var note = "released at the edge"
        var zone = edgeZone(at: up.point)
        if zone == nil, AppSettings.shared.snapThrow {
            if let m = magnetZone(up.point) { zone = m; note = "\(Int(topMagnet)) pt top magnet" }
            else if let t = throwZone(pressSamples) { zone = t.zone; note = t.note }
        }
        guard let z = zone else { return }
        guard let el = AX.windows(dw.pid).first(where: { AX.windowID($0) == dw.id }),
              (AX.attr(el, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole,
              AX.isSettable(el, kAXSizeAttribute) else { return }
        handledAt = ProcessInfo.processInfo.systemUptime
        Log.write("snap (drag): \(dw.id) caught at the release, its move not reported yet (\(note))")
        WindowSnap.shared.snap(.init(pid: dw.pid, element: el, id: dw.id), zone: z.unit, workArea: z.workArea,
                               layout: z.layout, source: "release")
    }

    /// The zone for a release at `p`: a screen edge or corner the pointer touches. Edges shared with another display
    /// need a rest there, which a quick flick doesn't have, so they don't count here.
    private func edgeZone(at p: CGPoint) -> Zone? {
        guard let screen = NSScreen.screens.first(where: { CaptionController.axRect($0.frame).contains(p) }) else {
            return nil
        }
        let sf = CaptionController.axRect(screen.frame)
        let wa = CaptionController.workArea(screen: screen)
        let Z = WindowSnap.Zones.self
        func outer(_ d: CGFloat, _ e: Edge) -> Bool { d <= edge && !edgeShared(screen, e, at: p) }
        var unit: CGRect?
        if outer(p.x - sf.minX, .left) || outer(sf.maxX - 1 - p.x, .right) {
            let left = p.x - sf.minX < sf.maxX - p.x
            if p.y - sf.minY < corner { unit = left ? Z.topLeft : Z.topRight }
            else if sf.maxY - p.y < corner { unit = left ? Z.bottomLeft : Z.bottomRight }
            else { unit = left ? Z.left : Z.right }
        } else if outer(p.y - sf.minY, .top) {
            if p.x - sf.minX < corner { unit = Z.topLeft }
            else if sf.maxX - p.x < corner { unit = Z.topRight }
            else { unit = Z.full }
        }
        guard let unit else { return nil }
        return Zone(unit: unit, workArea: wa, layout: Z.layout(for: unit))
    }

    /// A size change during the drag means it's a resize from the top or left edge, not a move.
    private func resized(_ el: AXUIElement) {
        guard var s = session, !s.resized, CFEqual(s.target.element, el), Date() > s.ignoreResizeUntil,
              let f = AX.frame(el), abs(f.width - s.size.width) > 2 || abs(f.height - s.size.height) > 2 else { return }
        s.resized = true
        session = s
        setZone(nil)
        bar.hide()
    }

    /// Windows: dragging a snapped or maximized window gives it back its size from before, under the pointer
    /// at the same relative position along the title bar.
    private func restoreSizeForDrag(_ s: inout Session, _ f: CGRect) {
        guard let r = WindowSnap.shared.restoreFrameForDrag(s.target.id, size: f.size), r.width > 50, r.height > 50,
              abs(r.width - f.width) > 2 || abs(r.height - f.height) > 2 else { return }
        let m = Self.mouse()
        var x = m.x - (m.x - f.minX) * (r.width / max(f.width, 1))
        x = min(max(x, m.x - r.width + 40), m.x - 40)
        let target = CGRect(x: x.rounded(), y: f.minY, width: r.width, height: r.height)
        s.ignoreResizeUntil = Date().addingTimeInterval(0.6)
        s.size = r.size
        WindowSnap.shared.forget(s.target.id)
        Log.write("snap (drag): restore size of \(s.target.id) -> \(CaptionController.describe(target))")
        AX.setSize(s.target.element, target.size)
        AX.setPosition(s.target.element, target.origin)
        if let now = AX.frame(s.target.element) { s.size = now.size }      // apps may keep a minimum size
    }

    private static func mouse() -> CGPoint {
        let m = NSEvent.mouseLocation
        return CGPoint(x: m.x, y: CaptionController.primaryHeight - m.y)
    }

    // MARK: Pointer tracking (event tap on only while dragging)

    private func enableTap() {
        if tap == nil {
            let mask = CGEventMask(1 << CGEventType.leftMouseDragged.rawValue) | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
            let cb: CGEventTapCallBack = { _, type, event, _ in
                let loc = event.location
                MainActor.assumeIsolated {
                    let d = DragSnap.shared
                    switch type {
                    case .leftMouseDragged: d.dragged(to: loc, time: DragSnap.nanos(event.timestamp))
                    case .leftMouseUp:
                        DispatchQueue.main.async { MainActor.assumeIsolated { d.mouseUp(source: "release") } }
                    case .tapDisabledByTimeout, .tapDisabledByUserInput:
                        if d.session != nil, let t = d.tap { CGEvent.tapEnable(tap: t, enable: true) }
                    default: break
                    }
                }
                return Unmanaged.passUnretained(event)
            }
            guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                            eventsOfInterest: mask, callback: cb, userInfo: nil) else {
                Log.write("snap: drag event tap unavailable")
                session = nil
                return
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
            tap = t
        }
        CGEvent.tapEnable(tap: tap!, enable: true)
        upTimer?.invalidate()
        // Backstop in case the release never reaches the tap.
        upTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                if NSEvent.pressedMouseButtons & 1 == 0 { DragSnap.shared.mouseUp(source: "button found released") }
            }
        }
        dragged(to: Self.mouse())
    }

    private func stopTap() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        upTimer?.invalidate()
        upTimer = nil
    }

    private func dragged(to p: CGPoint, time: UInt64? = nil) {
        guard var s = session else { stopTap(); return }
        s.events += 1
        s.last = p
        if let time {
            s.samples.append((p, time))
            if s.samples.count > 16 { s.samples.removeFirst(s.samples.count - 16) }
        }
        session = s
        guard !s.resized else { return }
        evaluate(p)
    }

    private func mouseUp(source: String = "?") {
        guard let s = session else { stopTap(); return }
        let held = NSEvent.pressedMouseButtons & 1 != 0
        if held {
            Log.write("drag: \(s.target.id) release signal (\(source)) while the button is still held, ignored")
            return
        }
        stopTap()
        session = nil
        var z = zone
        zone = nil
        // Released short of an edge while moving fast toward it: snap as if it got there.
        var thrown: String?
        if z == nil, !s.resized, AppSettings.shared.snapThrow {
            if let m = magnetZone(Self.mouse()) {
                z = m
                thrown = "let go \(Int(Self.mouse().y)) pt from the top (\(Int(topMagnet)) pt magnet)"
            } else if let t = throwZone(s.samples) {
                z = t.zone
                thrown = t.note
            }
        }
        pending = nil
        pendingTimer?.invalidate()
        preview.hide()
        bar.hide()
        let ms = Int(Date().timeIntervalSince(s.started) * 1000)
        Log.write("drag: \(s.target.id) ended (\(source)) after \(ms) ms, \(s.events) pointer updates, last at "
                  + "\(Int(s.last.x)),\(Int(s.last.y)), up at \(Int(Self.mouse().x)),\(Int(Self.mouse().y)), "
                  + (s.resized ? "resize" : z.map { "zone \(CaptionController.describe($0.unit))" } ?? "no zone")
                  + (thrown.map { " (\($0))" } ?? (z == nil && !s.resized ? " (\(throwMiss))" : "")))
        // The late-report rescue (quickDrag) must not handle this release a second time.
        lastEnded = (s.target.id, ProcessInfo.processInfo.systemUptime)
        handledAt = ProcessInfo.processInfo.systemUptime
        guard let z, !s.resized else { return }
        // Let the window server finish the drag before moving the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            MainActor.assumeIsolated {
                WindowSnap.shared.snap(s.target, zone: z.unit, workArea: z.workArea, layout: z.layout, source: "drag")
            }
        }
    }

    // MARK: Zones

    private enum Edge { case left, right, top }

    private func evaluate(_ p: CGPoint) {
        guard let screen = NSScreen.screens.first(where: { CaptionController.axRect($0.frame).contains(p) }) else {
            setZone(nil); bar.hide(); return
        }
        let sf = CaptionController.axRect(screen.frame)
        let wa = CaptionController.workArea(screen: screen)

        // Snap layouts bar at the top center.
        if AppSettings.shared.snapBarOnDrag, let hit = bar.track(p, screenTop: sf.minY + edge, workArea: wa) {
            if case .zone(let layout, let unit) = hit {
                setZone(Zone(unit: unit, workArea: wa, layout: layout, fromBar: true))
            }
            else { setZone(nil) }
            return
        }
        bar.hide()

        let Z = WindowSnap.Zones.self
        let shared: (Edge) -> Bool = { self.edgeShared(screen, $0, at: p) }
        func near(_ d: CGFloat, _ e: Edge) -> Bool { d <= (shared(e) ? sharedEdge : edge) }
        var hit: (CGRect, Edge)?
        if near(p.x - sf.minX, .left) || near(sf.maxX - 1 - p.x, .right) {
            let left = p.x - sf.minX < sf.maxX - p.x
            let e: Edge = left ? .left : .right
            if p.y - sf.minY < corner { hit = (left ? Z.topLeft : Z.topRight, e) }
            else if sf.maxY - p.y < corner { hit = (left ? Z.bottomLeft : Z.bottomRight, e) }
            else { hit = (left ? Z.left : Z.right, e) }
        } else if near(p.y - sf.minY, .top) {
            if p.x - sf.minX < corner { hit = (Z.topLeft, .top) }
            else if sf.maxX - p.x < corner { hit = (Z.topRight, .top) }
            else { hit = (Z.full, .top) }
        }
        guard let h = hit else { setZone(nil); return }
        let (unit, e) = h
        let z = Zone(unit: unit, workArea: wa, layout: Z.layout(for: unit))
        if shared(e) { setPending(z) } else { setZone(z) }
    }

    /// Another display continues past this edge where the pointer is.
    private func edgeShared(_ screen: NSScreen, _ e: Edge, at p: CGPoint) -> Bool {
        let sf = CaptionController.axRect(screen.frame)
        return NSScreen.screens.contains { s in
            guard s != screen else { return false }
            let o = CaptionController.axRect(s.frame)
            switch e {
            case .left: return abs(o.maxX - sf.minX) <= 1 && p.y >= o.minY && p.y < o.maxY
            case .right: return abs(o.minX - sf.maxX) <= 1 && p.y >= o.minY && p.y < o.maxY
            case .top: return abs(o.maxY - sf.minY) <= 1 && p.x >= o.minX && p.x < o.maxX
            }
        }
    }

    private func setPending(_ z: Zone) {
        if zone == z || pending == z { return }
        if zone != nil { setZone(nil) }
        pending = z
        pendingTimer?.invalidate()
        pendingTimer = Timer.scheduledTimer(withTimeInterval: sharedDwell, repeats: false) { _ in
            MainActor.assumeIsolated {
                let d = DragSnap.shared
                guard d.session != nil, let p = d.pending, p == z else { return }
                // Still resting at that edge?
                d.pending = nil
                d.evaluateDwell(z)
            }
        }
    }

    private func evaluateDwell(_ z: Zone) {
        let p = Self.mouse()
        guard let screen = NSScreen.screens.first(where: { CaptionController.axRect($0.frame).contains(p) }),
              CaptionController.workArea(screen: screen) == z.workArea else { return }
        let sf = CaptionController.axRect(screen.frame)
        let atEdge = p.x - sf.minX <= sharedEdge || sf.maxX - 1 - p.x <= sharedEdge || p.y - sf.minY <= sharedEdge
        if atEdge { applyZone(z) }
    }

    private func setZone(_ z: Zone?) {
        pending = nil
        pendingTimer?.invalidate()
        applyZone(z)
    }

    private func applyZone(_ z: Zone?) {
        guard z != zone else { return }
        zone = z
        guard let z, let s = session else { preview.hide(); return }
        let target = WindowSnap.rect(z.unit, in: z.workArea)
        // Edge drags: behind the dragged window, above every other window (Windows 11; user's choice 2026-11-15).
        // Snap bar: in front, where the window would otherwise hide it.
        let from = AX.frame(s.target.element), icon = WindowList.icon(s.target.pid)
        if z.fromBar { preview.show(target, from: from, icon: icon, above: s.target.id) }
        else { preview.show(target, from: from, icon: icon, below: s.target.id) }
    }
}

/// The translucent rounded rectangle that shows where a window will snap (acrylic with the app's icon in the
/// middle). It glides between zones. While dragging it sits just below the dragged window, as on Windows 11; the
/// Snap Layouts flyout puts it above the window, which isn't moving then.
@MainActor
final class SnapPreview {
    private var panel: OverlayPanel?
    private var tint: NSView?
    private var iconView: NSImageView?
    private var visible = false

    func show(_ frame: CGRect, from start: CGRect?, icon: NSImage, below id: CGWindowID) {
        show(frame, from: start, icon: icon, relativeTo: id, place: .below)
    }

    func show(_ frame: CGRect, from start: CGRect?, icon: NSImage, above id: CGWindowID) {
        show(frame, from: start, icon: icon, relativeTo: id, place: .above)
    }

    private func show(_ frame: CGRect, from start: CGRect?, icon: NSImage, relativeTo id: CGWindowID,
                      place: NSWindow.OrderingMode) {
        let p = panel ?? make()
        let target = CaptionController.shared.cocoaRect(frame).insetBy(dx: 6, dy: 6)
        iconView?.image = icon
        styleTint()
        if !visible {
            visible = true
            let from = start.map { CaptionController.shared.cocoaRect($0) } ?? target
            p.setFrame(from, display: false)
            p.alphaValue = 0
        }
        // Every time: an app may raise its window after the preview appeared.
        p.order(place, relativeTo: Int(id))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.1, 0.9, 0.2, 1)
            p.animator().setFrame(target, display: true)
            p.animator().alphaValue = 1
        }
    }

    func hide() {
        guard visible, let p = panel else { return }
        visible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Unless it was shown again meanwhile (a new zone right after leaving the old one).
            MainActor.assumeIsolated { if self?.visible != true { p.orderOut(nil) } }
        })
    }

    private func make() -> OverlayPanel {
        let p = OverlayPanel(level: .normal)
        p.ignoresMouseEvents = true
        let root = NSView()
        root.wantsLayer = true
        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.maskImage = VisualEffect.mask(8)
        fx.autoresizingMask = [.width, .height]
        root.addSubview(fx)
        let t = NSView()
        t.wantsLayer = true
        t.layer?.cornerRadius = 8
        t.layer?.cornerCurve = .continuous
        t.layer?.borderWidth = 1
        t.autoresizingMask = [.width, .height]
        root.addSubview(t)
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.frame = NSRect(x: 0, y: 0, width: 56, height: 56)
        iv.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        root.addSubview(iv)
        p.contentView = root
        p.setFrame(NSRect(x: 0, y: 0, width: 200, height: 200), display: false)
        fx.frame = root.bounds
        t.frame = root.bounds
        iv.frame.origin = NSPoint(x: 72, y: 72)
        panel = p
        tint = t
        iconView = iv
        return p
    }

    private func styleTint() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        tint?.layer?.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 1, alpha: 0.35)).cgColor
        tint?.layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.12)).cgColor
    }
}

/// Snap layouts bar shown while dragging a window toward the top center of a display (Windows 11 22H2+):
/// a small handle first, the layouts once the pointer reaches it. The pointer is tracked by DragSnap (the
/// bar never takes the mouse; the drag belongs to the window server).
@MainActor
final class SnapBar {
    enum Hit { case bar, zone([CGRect], CGRect) }

    private var panel: OverlayPanel?
    private let model = SnapBarModel()
    private var workArea: CGRect = .zero
    private var expandedFrame: CGRect = .zero        // AX
    private static let pad: CGFloat = 10, spacing: CGFloat = 10
    var debugGeometry: (CGRect, CGSize) { (expandedFrame, model.tile) }

    func track(_ p: CGPoint, screenTop: CGFloat, workArea wa: CGRect) -> Hit? {
        if wa != workArea { configure(wa) }
        // The very top edge is "maximize", left to DragSnap.
        guard p.y > screenTop else { if model.expanded { model.expanded = false; model.highlight = nil }; return nil }
        let e = expandedFrame
        let inExpanded = p.x >= e.minX - 16 && p.x <= e.maxX + 16 && p.y <= e.maxY + 16
        let reveal = p.y <= wa.minY + 48 && abs(p.x - wa.midX) <= 100
        let nearTop = p.y <= wa.minY + 140 && abs(p.x - wa.midX) <= max(e.width / 2 + 40, wa.width * 0.15)
        if (model.expanded && inExpanded) || reveal {
            show(expanded: true)
            for (i, layout) in model.layouts.enumerated() {
                let tile = CGRect(x: e.minX + Self.pad + CGFloat(i) * (model.tile.width + Self.spacing), y: e.minY + Self.pad,
                                  width: model.tile.width, height: model.tile.height)
                for (z, unit) in layout.enumerated() {
                    let r = CGRect(x: tile.minX + unit.minX * tile.width, y: tile.minY + unit.minY * tile.height,
                                   width: unit.width * tile.width, height: unit.height * tile.height).insetBy(dx: 1.5, dy: 1.5)
                    if r.contains(p) {
                        model.highlight = SnapBarModel.Key(layout: i, zone: z)
                        return .zone(layout, unit)
                    }
                }
            }
            model.highlight = nil
            return .bar
        }
        if nearTop {
            show(expanded: false)
            model.highlight = nil
            return .bar
        }
        hide()
        return nil
    }

    private func configure(_ wa: CGRect) {
        workArea = wa
        model.layouts = SnapLayouts.layouts(for: wa.size)
        let t = SnapLayouts.tileSize(for: wa.size)
        model.tile = CGSize(width: (t.width * 0.8).rounded(), height: (t.height * 0.8).rounded())
        let n = CGFloat(model.layouts.count)
        let w = Self.pad * 2 + n * model.tile.width + (n - 1) * Self.spacing
        let h = Self.pad * 2 + model.tile.height
        expandedFrame = CGRect(x: (wa.midX - w / 2).rounded(), y: wa.minY + 8, width: w, height: h)
        if let p = panel { p.setFrame(CaptionController.shared.cocoaRect(expandedFrame), display: false) }
    }

    private func show(expanded: Bool) {
        if model.expanded != expanded { model.expanded = expanded }
        let p = panel ?? make()
        if !p.isVisible {
            p.setFrame(CaptionController.shared.cocoaRect(expandedFrame), display: false)
            p.alphaValue = 1
            p.orderFrontRegardless()
        }
    }

    func hide() {
        guard let p = panel, p.isVisible else { return }
        model.expanded = false
        model.highlight = nil
        p.orderOut(nil)
    }

    private func make() -> OverlayPanel {
        let p = OverlayPanel(level: .floating)
        p.ignoresMouseEvents = true
        let host = NSHostingView(rootView: SnapBarView(model: model, pad: Self.pad, spacing: Self.spacing))
        host.sizingOptions = []
        p.contentView = host
        p.setFrame(CaptionController.shared.cocoaRect(expandedFrame), display: false)
        panel = p
        return p
    }
}

@MainActor
final class SnapBarModel: ObservableObject {
    struct Key: Equatable { let layout: Int; let zone: Int }
    @Published var expanded = false
    @Published var highlight: Key?
    @Published var layouts: [[CGRect]] = []
    @Published var tile = CGSize(width: 66, height: 37)
}

struct SnapBarView: View {
    @ObservedObject var model: SnapBarModel
    let pad: CGFloat
    let spacing: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .top) {
            if model.expanded {
                HStack(spacing: spacing) {
                    ForEach(model.layouts.indices, id: \.self) { i in tile(i) }
                }
                .padding(pad)
                .background(chrome(RoundedRectangle(cornerRadius: 8, style: .continuous)))
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            } else {
                Capsule().fill(Theme.text(scheme).opacity(0.45)).frame(width: 36, height: 4)
                    .padding(.horizontal, 22).padding(.vertical, 6)
                    .background(chrome(Capsule()))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.15), value: model.expanded)
    }

    private func chrome<S: InsettableShape>(_ shape: S) -> some View {
        shape.fill(Theme.flyoutTint(scheme))
            .background(VisualEffect(material: .hudWindow, cornerRadius: 8).clipShape(shape))
            .overlay(shape.strokeBorder(Theme.border(scheme), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }

    private func tile(_ i: Int) -> some View {
        let t = model.tile
        return ZStack(alignment: .topLeading) {
            ForEach(model.layouts[i].indices, id: \.self) { z in
                let unit = model.layouts[i][z]
                let r = CGRect(x: unit.minX * t.width, y: unit.minY * t.height,
                               width: unit.width * t.width, height: unit.height * t.height).insetBy(dx: 1.5, dy: 1.5)
                let on = model.highlight == SnapBarModel.Key(layout: i, zone: z)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(on ? Theme.accent : (scheme == .dark ? Color.white.opacity(0.09) : Color.white.opacity(0.85)))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(on ? Theme.accent : Theme.border(scheme).opacity(2), lineWidth: 1))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
            }
        }
        .frame(width: t.width, height: t.height, alignment: .topLeading)
    }
}
