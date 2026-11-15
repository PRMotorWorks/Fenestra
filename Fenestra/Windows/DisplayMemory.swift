import AppKit
import ApplicationServices

/// Display identity helpers shared by the taskbars and DisplayMemory.
@MainActor
enum Displays {
    static func id(_ s: NSScreen) -> CGDirectDisplayID {
        s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }

    /// Stable across unplug/replug and reboots (ColorSync display UUID), unlike CGDirectDisplayID.
    static func uuid(_ id: CGDirectDisplayID) -> String {
        guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "display-\(id)" }
        return (CFUUIDCreateString(nil, u) as String?) ?? "display-\(id)"
    }

    /// The display holding the center of an AX rect (top-left origin), else the one it overlaps most.
    static func screen(forAX f: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        let c = CGPoint(x: f.midX, y: f.midY)
        if let s = screens.first(where: { CaptionController.axRect($0.frame).contains(c) }) { return s }
        return screens.max { a, b in
            let ia = CaptionController.axRect(a.frame).intersection(f), ib = CaptionController.axRect(b.frame).intersection(f)
            return ia.width * ia.height < ib.width * ib.height
        }
    }
}

/// Phase 5: Windows 11 Settings > System > Display > Multiple displays.
///
/// "Remember window locations based on monitor connection": when a display goes away, macOS moves its
/// windows onto the remaining displays. Fenestra remembers where each window was (frame relative to its
/// display, plus snapped zone or maximized state) and puts it back when that display returns.
/// "Minimize windows when a monitor is disconnected": those windows are minimized instead of piling up on
/// the remaining display, and come back on reconnect.
///
/// Event driven: the record is refreshed from one CGWindowList read, 0.5 s after window activity settles,
/// and only while two or more displays are connected. It is frozen the moment macOS announces a display
/// change (CGDisplayRegisterReconfigurationCallback, begin flag), before any window is moved.
@MainActor
final class DisplayMemory {
    static let shared = DisplayMemory()

    struct Display {
        let uuid: String
        let name: String
        let screen: NSScreen
        let frame: CGRect                   // AX coordinates
    }

    /// Where a window was, relative to its display.
    struct Placement {
        let id: CGWindowID
        let pid: pid_t
        var display: String
        var displayFrame: CGRect            // AX frame of that display when recorded
        var frame: CGRect                   // AX
        var maximized: Bool
        var zone: CGRect?                   // WindowSnap zone (unit rect)
        var normal: CGRect?                 // Restore Down frame
        var preSnap: CGRect?                // frame from before snapping
        var minimizedByUs = false
    }

    private var displays: [String: Display] = [:]          // the set as of the last settled change
    private var placements: [CGWindowID: Placement] = [:]
    /// Windows whose display is gone, waiting for it to come back.
    private var displaced: [CGWindowID: Placement] = [:]
    /// Displaced windows the user had minimized themselves: put back when they are restored.
    private var onDeminimize: [CGWindowID: Placement] = [:]
    private var frozen = false
    private var snapshotScheduled = false
    private var settleWork: DispatchWorkItem?
    private var started = false
    private let me = ProcessInfo.processInfo.processIdentifier

    func start() {
        guard !started, WindowEvents.shared.isRunning else { return }
        started = true
        displays = Self.currentDisplays()
        CGDisplayRegisterReconfigurationCallback(Self.reconfigured, nil)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DisplayMemory.shared.screensChanged() }
        }
        WindowEvents.shared.subscribe { kind, _, el in
            switch kind {
            case .title, .focused: return
            case .deminimized: DisplayMemory.shared.deminimized(el)
            default: break
            }
            DisplayMemory.shared.scheduleSnapshot()
        }
        snapshot()
        Log.write("displays: memory started, \(displays.count) display(s): " +
                  displays.values.map(\.name).sorted().joined(separator: ", "))
    }

    // MARK: Record

    private func scheduleSnapshot(after delay: Double = 0.5) {
        guard !frozen, displays.count > 1, !snapshotScheduled else { return }
        snapshotScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                let m = DisplayMemory.shared
                m.snapshotScheduled = false
                if NSEvent.pressedMouseButtons != 0 { m.scheduleSnapshot(); return }   // mid-drag: wait for release
                m.snapshot()
            }
        }
    }

    private func snapshot() {
        guard !frozen, displays.count > 1 else { return }
        let now = Self.currentDisplays()
        guard Set(now.keys) == Set(displays.keys) else { return }       // a change is pending: keep the old record
        displays = now                                                     // same displays, maybe rearranged
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return }
        var fresh: [CGWindowID: Placement] = [:]
        let byScreen = Dictionary(now.values.map { (Displays.id($0.screen), $0) }, uniquingKeysWith: { a, _ in a })
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bd), b.width > 60, b.height > 40,
                  let s = Displays.screen(forAX: b), let d = byScreen[Displays.id(s)] else { continue }
            let maximized = CaptionController.shared.isMaximizedFrame(id, b)
            fresh[id] = Placement(id: id, pid: pid, display: d.uuid, displayFrame: d.frame, frame: b,
                                  maximized: maximized,
                                  zone: maximized ? nil : WindowSnap.shared.snappedZone(id, b),
                                  normal: CaptionController.shared.normalFrame(id),
                                  preSnap: WindowSnap.shared.preSnapFrame(id))
        }
        // Windows not on screen right now (minimized, app hidden) keep their last known place.
        for (id, p) in placements where fresh[id] == nil {
            if let app = NSRunningApplication(processIdentifier: p.pid), !app.isTerminated { fresh[id] = p }
        }
        placements = fresh
    }

    // MARK: Display changes

    /// Called by CoreGraphics before a reconfiguration is applied (and again after, per display).
    private static let reconfigured: CGDisplayReconfigurationCallBack = { _, flags, _ in
        guard flags.contains(.beginConfigurationFlag) else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { DisplayMemory.shared.freeze() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { DisplayMemory.shared.freeze() } }
        }
    }

    private func freeze() {
        if !frozen && placements.count > 0 { Log.write("displays: change starting, record of \(placements.count) windows kept") }
        frozen = true
    }

    private func screensChanged() {
        frozen = true
        settleWork?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated { DisplayMemory.shared.settle() } }
        settleWork = w
        // Short: macOS has already moved the gone display's windows onto the others, so minimize them quickly.
        // A burst of notifications just runs settle() again, which then finds nothing new.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    private func settle() {
        let now = Self.currentDisplays()
        let removed = Set(displays.keys).subtracting(now.keys)
        let added = Set(now.keys).subtracting(displays.keys)
        let s = AppSettings.shared

        var toMinimize: [Placement] = []
        for uuid in removed {
            let name = displays[uuid]?.name ?? uuid
            let gone = placements.values.filter { $0.display == uuid }
            for p in gone {
                placements[p.id] = nil
                if s.rememberWindowLocations || s.minimizeOnDisconnect { displaced[p.id] = p }
            }
            if s.minimizeOnDisconnect { toMinimize += gone }
            Log.write("displays: \(name) disconnected, \(gone.count) of its windows remembered")
        }
        if !toMinimize.isEmpty { minimize(toMinimize, retry: true) }
        displays = now
        frozen = false

        let returning = added.compactMap { now[$0] }
        if !returning.isEmpty {
            for d in returning { Log.write("displays: \(d.name) connected") }
            // Let the taskbar for that display and macOS's own window moves settle first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated { DisplayMemory.shared.restore(to: returning.map(\.uuid)) }
            }
        } else {
            scheduleSnapshot(after: 1.0)
        }
    }

    /// Minimizes windows of a display that went away. Elements are looked up first, per app: an app busy
    /// animating a minimize answers Accessibility too slowly for a lookup in between.
    private func minimize(_ list: [Placement], retry: Bool) {
        let els = Self.elements(list)
        var done = 0, missing: [Placement] = []
        for p in list {
            guard let el = els[p.id] else { missing.append(p); continue }
            if AX.isMinimized(el) { continue }                  // the user had minimized it already
            AX.setMinimized(el, true)
            displaced[p.id]?.minimizedByUs = true
            done += 1
        }
        Log.write("displays: \(done) windows minimized" + (missing.isEmpty ? "" : ", \(missing.count) not reachable yet"))
        if retry && !missing.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    let m = DisplayMemory.shared
                    let still = missing.filter { m.displaced[$0.id] != nil }
                    if !still.isEmpty { m.minimize(still, retry: false) }
                }
            }
        }
    }

    private func restore(to uuids: [String]) {
        let current = Self.currentDisplays()
        for uuid in uuids {
            guard let d = current[uuid] else { continue }
            let waiting = displaced.values.filter { $0.display == uuid }
            let els = Self.elements(waiting)
            var moved = 0
            var toUnminimize: [(Placement, AXUIElement)] = []
            for p in waiting {
                displaced[p.id] = nil
                // Remembering off: windows minimized on disconnect stay minimized, nothing moves.
                guard AppSettings.shared.rememberWindowLocations, let el = els[p.id] else { continue }
                let minimized = AX.isMinimized(el)
                if minimized && !p.minimizedByUs {
                    // The user minimized it: it goes back to this display when they restore it.
                    onDeminimize[p.id] = p
                    continue
                }
                // Minimized windows get their frame first, so they come out of the Dock straight into place
                // instead of landing where macOS parked them on the other display and jumping.
                apply(p, element: el, on: d)
                moved += 1
                if minimized { toUnminimize.append((p, el)) }
            }
            // Second pass: an app animating a restore answers Accessibility slowly, so frames go first.
            for (p, el) in toUnminimize {
                AX.setMinimized(el, false)
                // Some apps ignore a frame set while minimized: check once more after the animation.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    MainActor.assumeIsolated { DisplayMemory.shared.verify(p, element: el, uuid: uuid) }
                }
            }
            let unminimized = toUnminimize.count
            Log.write("displays: \(moved) windows put back on \(d.name)" + (unminimized > 0 ? ", \(unminimized) unminimized" : ""))
        }
        scheduleSnapshot(after: 1.0)
    }

    private func verify(_ p: Placement, element el: AXUIElement, uuid: String) {
        guard let d = Self.currentDisplays()[uuid], let f = AX.frame(el) else { return }
        let want = p.maximized ? CaptionController.workArea(screen: d.screen)
            : p.zone.map { WindowSnap.rect($0, in: CaptionController.workArea(screen: d.screen)) } ?? map(p.frame, p, to: d)
        if !CaptionController.approx(f, want) {
            Log.write("displays: \(p.id) ignored its frame while minimized, placed again")
            apply(p, element: el, on: d)
        }
    }

    /// A displaced window the user had minimized was restored: put it on its display if that is back.
    private func deminimized(_ el: AXUIElement) {
        guard !onDeminimize.isEmpty, let id = AX.windowID(el), let p = onDeminimize.removeValue(forKey: id),
              let d = Self.currentDisplays()[p.display] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {       // after the restore animation
            MainActor.assumeIsolated {
                DisplayMemory.shared.apply(p, element: el, on: d)
                Log.write("displays: \(p.id) restored from minimized onto \(d.name)")
            }
        }
    }

    // MARK: Putting a window back

    private func apply(_ p: Placement, element el: AXUIElement, on d: Display) {
        let wa = CaptionController.workArea(screen: d.screen)
        let normal = p.normal.map { map($0, p, to: d) }
        let pre = p.preSnap.map { map($0, p, to: d) }
        if p.maximized {
            CaptionController.shared.restoreMaximized(pid: p.pid, element: el, id: p.id, normal: normal, workArea: wa)
            WindowSnap.shared.setPreSnap(p.id, pre)
        } else if let z = p.zone {
            WindowSnap.shared.restoreSnap(.init(pid: p.pid, element: el, id: p.id), zone: z, workArea: wa, preSnap: pre)
        } else {
            CaptionController.setFrame(p.pid, el, map(p.frame, p, to: d))
            CaptionController.shared.markDirty(p.pid, delay: 0.05)
        }
    }

    /// A rect recorded on a display, moved along with the display (it may sit elsewhere in the arrangement
    /// now, or have another resolution: then it is scaled to keep its relative place).
    private func map(_ r: CGRect, _ p: Placement, to d: Display) -> CGRect {
        let old = p.displayFrame, new = d.frame
        if abs(old.width - new.width) < 1 && abs(old.height - new.height) < 1 {
            return r.offsetBy(dx: new.minX - old.minX, dy: new.minY - old.minY)
        }
        let sx = new.width / old.width, sy = new.height / old.height
        return CGRect(x: new.minX + (r.minX - old.minX) * sx, y: new.minY + (r.minY - old.minY) * sy,
                      width: r.width * sx, height: r.height * sy).integral
    }

    // MARK: Helpers

    private static func currentDisplays() -> [String: Display] {
        var out: [String: Display] = [:]
        for s in NSScreen.screens {
            let u = Displays.uuid(Displays.id(s))
            out[u] = Display(uuid: u, name: s.localizedName, screen: s, frame: CaptionController.axRect(s.frame))
        }
        return out
    }

    /// AX elements of the placements' windows, one window list read per app.
    private static func elements(_ list: [Placement]) -> [CGWindowID: AXUIElement] {
        var out: [CGWindowID: AXUIElement] = [:]
        for pid in Set(list.map(\.pid)) {
            guard NSRunningApplication(processIdentifier: pid).map({ !$0.isTerminated }) == true else { continue }
            for w in AX.windows(pid) { if let id = AX.windowID(w) { out[id] = w } }
        }
        return out
    }

    /// For the README checklist and the log: what is remembered right now.
    func describe() -> String {
        "displays=\(displays.count) placements=\(placements.count) displaced=\(displaced.count) frozen=\(frozen)"
    }
}
