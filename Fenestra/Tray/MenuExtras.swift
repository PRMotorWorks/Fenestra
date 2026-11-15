import AppKit
import ApplicationServices

/// One menu bar icon (NSStatusItem or system menu extra) mirrored into the tray.
struct MenuExtra: Identifiable, Equatable {
    /// "bundleID|identifier" (or "|index" when the item has no identifier). Stable across launches.
    let id: String
    let pid: pid_t
    let bundleID: String
    let name: String           // tooltip: the item's accessibility description, else the app's name
    let symbol: String?        // SF Symbol for system items; nil = the app's icon
    let order: CGFloat         // x position in the menu bar, keeps the menu bar's order
}

/// Phase 6: finds the menu bar's icons through Accessibility and shows them in the tray (pinned) or in the
/// overflow flyout. On Tahoe every icon's window belongs to Control Center, but each app still exposes its own
/// items as `AXExtrasMenuBar` > `AXMenuBarItem` (subrole `AXMenuExtra`) with `AXPress`.
///
/// Event driven, no polling: everything is read once at start (on a background queue: about 0.8 s of AX
/// round trips over every process), then per app when it launches (1.5 s and 5 s later, as apps add their
/// icon after launching), dropped when it quits, and re-read when the overflow flyout opens.
///
/// Icons are the app's own icon (a Windows tray shows app icons) or an SF Symbol for system items: the real
/// glyphs can't be captured while the menu bar is hidden (their windows are off screen then).
@MainActor
final class MenuExtras: ObservableObject {
    static let shared = MenuExtras()

    @Published private(set) var items: [MenuExtra] = []
    private var elements: [String: AXUIElement] = [:]
    private var started = false
    private let queue = DispatchQueue(label: "local.fenestra.menuextras", qos: .utility)
    private var fullScanRunning = false
    private var lastFullScan = Date.distantPast

    /// Items Fenestra already replaces with its own tray (Quick Settings, clock, keyboard layout, Start search).
    private static let replaced: Set<String> = [
        "com.apple.controlcenter|com.apple.menuextra.battery",
        "com.apple.controlcenter|com.apple.menuextra.clock",
        "com.apple.controlcenter|com.apple.menuextra.wifi",
        "com.apple.controlcenter|com.apple.menuextra.controlcenter",
        "com.apple.controlcenter|com.apple.menuextra.sound",
        "com.apple.controlcenter|com.apple.menuextra.bluetooth",
        "com.apple.controlcenter|com.apple.menuextra.display",
    ]
    private static let replacedApps: Set<String> = ["com.apple.Spotlight", "com.apple.TextInputMenuAgent"]

    private static let systemSymbols: [String: String] = [
        "com.apple.menuextra.screen-mirroring": "rectangle.on.rectangle",
        "com.apple.menuextra.focusmodes": "moon.fill",
        "com.apple.menuextra.now-playing": "play.circle",
        "com.apple.menuextra.nowplaying": "play.circle",
        "com.apple.menuextra.airdrop": "dot.radiowaves.up.forward",
        "com.apple.menuextra.user": "person.crop.circle",
        "com.apple.menuextra.keyboardbrightness": "light.max",
        "com.apple.menuextra.accessibility": "accessibility",
        "com.apple.menuextra.hearing": "ear",
        "com.apple.menuextra.timemachine": "clock.arrow.circlepath",
        "com.apple.menuextra.vpn": "network.badge.shield.half.filled",
        "com.apple.menuextra.stagemanager": "squares.leading.rectangle",
        "com.apple.menuextra.battery": "battery.75percent",
    ]

    func start() {
        guard !started, AXIsProcessTrusted() else { return }
        started = true
        scanAll()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                for delay in [1.5, 5.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        MainActor.assumeIsolated { MenuExtras.shared.scan(pids: [pid]) }
                    }
                }
            }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { MenuExtras.shared.merge(pids: [pid], found: []) }
        }
    }

    /// Re-reads every app (the overflow flyout calls this when it opens). At most every 3 s.
    func refresh() {
        guard started, !fullScanRunning, Date().timeIntervalSince(lastFullScan) > 3 else { return }
        scanAll()
    }

    // MARK: Scanning (background queue)

    private struct Found: @unchecked Sendable {
        let extra: MenuExtra
        let element: AXUIElement
    }

    private struct AppRef: Sendable { let pid: pid_t; let bundleID: String; let name: String }

    private func scanAll() {
        fullScanRunning = true
        lastFullScan = Date()
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated && $0.processIdentifier != me }
            .map { AppRef(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier ?? "", name: $0.localizedName ?? "") }
        let t0 = Date()
        queue.async {
            let found = apps.flatMap(Self.read)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let s = MenuExtras.shared
                    s.fullScanRunning = false
                    s.merge(pids: Set(apps.map(\.pid)), found: found, replaceAll: true)
                    Log.write("menuextras: \(s.items.count) icon(s) from \(Set(found.map(\.extra.pid)).count) app(s) in \(ms) ms: "
                              + s.items.map { "\($0.name)" }.joined(separator: ", "))
                }
            }
        }
    }

    func scan(pids: [pid_t]) {
        let apps = pids.compactMap { pid -> AppRef? in
            guard let a = NSRunningApplication(processIdentifier: pid), !a.isTerminated else { return nil }
            return AppRef(pid: pid, bundleID: a.bundleIdentifier ?? "", name: a.localizedName ?? "")
        }
        guard !apps.isEmpty else { return }
        queue.async {
            let found = apps.flatMap(Self.read)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { MenuExtras.shared.merge(pids: Set(pids), found: found) }
            }
        }
    }

    /// Plain AX calls (thread safe), so this can run off the main thread. Each call times out after 0.25 s.
    nonisolated private static func read(_ app: AppRef) -> [Found] {
        guard !replacedApps.contains(app.bundleID) else { return [] }
        let el = AXUIElementCreateApplication(app.pid)
        func attr<T>(_ e: AXUIElement, _ name: String) -> T? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
            return v as? T
        }
        guard let barRef: CFTypeRef = attr(el, "AXExtrasMenuBar"), CFGetTypeID(barRef) == AXUIElementGetTypeID() else { return [] }
        let bar = barRef as! AXUIElement
        guard let kids: [AXUIElement] = attr(bar, kAXChildrenAttribute as String) else { return [] }
        var out: [Found] = []
        for (i, item) in kids.enumerated() {
            var size = CGSize.zero, pos = CGPoint.zero
            if let v: CFTypeRef = attr(item, kAXSizeAttribute as String), CFGetTypeID(v) == AXValueGetTypeID() {
                AXValueGetValue(v as! AXValue, .cgSize, &size)
            }
            if let v: CFTypeRef = attr(item, kAXPositionAttribute as String), CFGetTypeID(v) == AXValueGetTypeID() {
                AXValueGetValue(v as! AXValue, .cgPoint, &pos)
            }
            guard size.width > 0, size.height > 0 else { continue }      // hidden in System Settings > Menu Bar
            let ident: String = attr(item, kAXIdentifierAttribute as String) ?? ""
            let key = "\(app.bundleID)|\(ident.isEmpty ? String(i) : ident)"
            guard !replaced.contains(key) else { continue }
            let desc: String = attr(item, kAXDescriptionAttribute as String) ?? ""
            let title: String = attr(item, kAXTitleAttribute as String) ?? ""
            let isSystem = app.bundleID == "com.apple.controlcenter" || app.bundleID == "com.apple.systemuiserver"
            let name = !desc.isEmpty ? (isSystem || desc == app.name ? desc : "\(app.name): \(desc)")
                : (!title.isEmpty ? title : app.name)
            let symbol = isSystem ? (systemSymbols[ident] ?? "circle.grid.2x2") : nil
            out.append(Found(extra: MenuExtra(id: key, pid: app.pid, bundleID: app.bundleID, name: name,
                                              symbol: symbol, order: pos.x),
                             element: item))
        }
        return out
    }

    private func merge(pids: Set<pid_t>, found: [Found], replaceAll: Bool = false) {
        var list = replaceAll ? [] : items.filter { !pids.contains($0.pid) }
        if replaceAll { elements.removeAll() } else { for i in items where pids.contains(i.pid) { elements[i.id] = nil } }
        for f in found where !list.contains(where: { $0.id == f.extra.id }) {
            list.append(f.extra)
            elements[f.extra.id] = f.element
        }
        list.sort { $0.order < $1.order }
        if list != items { items = list }
    }

    // MARK: Using

    func isPinned(_ e: MenuExtra) -> Bool { AppSettings.shared.trayPinned.contains(e.id) }
    var pinned: [MenuExtra] { items.filter(isPinned) }
    var overflow: [MenuExtra] { items.filter { !isPinned($0) } }

    /// Click: the item's own menu above the tray when it can be read closed, otherwise press the item itself
    /// (its menu or panel opens at the top of the main display, where the menu bar slides in).
    func open(_ e: MenuExtra, anchor: NSRect) {
        FlyoutManager.shared.close(animated: false)
        guard let el = elements[e.id] else { scan(pids: [e.pid]); return }
        if let menu = AppMenus.shared.extraMenu(el) {
            Log.write("menuextras: \(e.id) menu shown above the tray")
            PowerActions.popUp(menu, above: anchor)
            return
        }
        let ok = AX.perform(el, kAXPressAction)
        Log.write("menuextras: pressed \(e.id) ok=\(ok) at \(AX.frame(el).map(CaptionController.describe) ?? "?")")
        if !ok { scan(pids: [e.pid]) }
    }

    /// Right-click: open it, or move it between the taskbar and the overflow.
    func contextMenu(_ e: MenuExtra, anchor: NSRect) {
        FlyoutManager.shared.close(animated: false)
        Log.write("menuextras: \(e.id) context menu")
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Open", symbol: "arrow.up.forward.app") { MenuExtras.shared.open(e, anchor: anchor) })
        menu.addItem(.separator())
        if isPinned(e) {
            menu.addItem(ClosureMenuItem("Hide in the overflow menu", symbol: "chevron.up") { AppSettings.shared.setTrayPinned(e.id, false) })
        } else {
            menu.addItem(ClosureMenuItem("Show on the taskbar", symbol: "pin") { AppSettings.shared.setTrayPinned(e.id, true) })
        }
        menu.addItem(ClosureMenuItem("Taskbar settings", symbol: "gearshape") { SettingsWindow.show() })
        PowerActions.popUp(menu, above: anchor)
    }

    func icon(for e: MenuExtra) -> NSImage {
        if let app = NSRunningApplication(processIdentifier: e.pid), let i = app.icon { return i }
        return NSWorkspace.shared.icon(for: .application)
    }
}
