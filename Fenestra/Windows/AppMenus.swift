import AppKit
import ApplicationServices

/// Menu item that runs a closure (window menu commands, tray icon menus).
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, symbol: String? = nil, enabled: Bool = true, key: String = "",
         modifiers: NSEvent.ModifierFlags = .command, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        isEnabled = enabled
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func run() { handler() }
}

/// Wraps an AX element so it can ride along as an NSMenuItem's representedObject.
private final class AXRef: NSObject {
    let element: AXUIElement
    init(_ e: AXUIElement) { element = e }
}

/// Phase 6: an app's menu bar (Apple menu, app menu, File, Edit, ...) as a native dropdown, for when the macOS
/// menu bar is hidden. Read through Accessibility (`kAXMenuBarAttribute`). The dropdown itself costs ~1 ms; its
/// menus are then read in the background in order (`MenuPrefetch`), each item in one AX call (`MenuReader`), so a
/// menu is usually ready before the pointer reaches it. Reading each menu on the main thread only as it opened
/// (8 AX calls per item) made the dropdown stutter when swept across quickly and each menu open late.
/// Choosing an item presses the real menu item (AXPress), so the app runs its own command, with its own enabled
/// state. Also mirrors menu bar icons' menus above the tray (MenuExtras) and builds the caption's window menu.
@MainActor
final class AppMenus: NSObject, NSMenuDelegate {
    static let shared = AppMenus()

    /// Submenu -> the AX element whose AXMenu child it mirrors. Cleared each time a new dropdown opens.
    private var sources: [ObjectIdentifier: AXUIElement] = [:] { didSet { if sources.isEmpty { filled.removeAll() } } }
    /// Submenus already filled in this dropdown. AppKit asks again every time one reopens; refilling it threw away
    /// AppKit's cached layout, so sweeping back and forth rebuilt each submenu window from scratch (profiled
    /// 2026-11-16: submenu window setup was most of the main thread's time while the dropdown was open).
    private var filled: Set<ObjectIdentifier> = []
    /// Background reads of the open dropdown's menus; cancelled when it closes.
    private var prefetch: MenuPrefetch?
    private let trace = MenuTrace()
    var traceRef: MenuTrace { trace }

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated { trace.opened(menu) }
    }

    nonisolated func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        MainActor.assumeIsolated { trace.highlighted() }
    }

    // MARK: Opening

    /// The dropdown for the menu button and Option tap. `point` is the menu's top-left in screen coordinates.
    func popUpAppMenu(pid: pid_t, at point: NSPoint) {
        sources.removeAll()
        guard let menu = appMenu(pid: pid) else { Log.write("appmenus: pid \(pid) has no menu bar"); return }
        startPrefetch(menu)
        menu.delegate = self
        trace.begin()
        menu.popUp(positioning: nil, at: point, in: nil)
        trace.end()
        endPrefetch()
        sources.removeAll()
    }

    /// Right-click on the caption buttons: the Windows window menu (Restore, Minimize, Maximize, Close)
    /// followed by the app's menus.
    /// Windows order: Restore, Move, Size, Minimize, Maximize, Close. Move and Size are off while maximized.
    func popUpWindowMenu(pid: pid_t, maximized: Bool, canMinimize: Bool, canMaximize: Bool, canResize: Bool = true,
                         at point: NSPoint, mover: ((WindowMover.Mode) -> Void)? = nil,
                         perform: @escaping (CaptionView.Part) -> Void) {
        sources.removeAll()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem("Restore", symbol: "arrow.down.right.and.arrow.up.left", enabled: maximized) { perform(.maximize) })
        if let mover {
            menu.addItem(ClosureMenuItem("Move", symbol: "arrow.up.and.down.and.arrow.left.and.right",
                                         enabled: !maximized) { mover(.move) })
            menu.addItem(ClosureMenuItem("Size", symbol: "arrow.up.left.and.arrow.down.right",
                                         enabled: !maximized && canResize) { mover(.size) })
        }
        menu.addItem(ClosureMenuItem("Minimize", symbol: "minus", enabled: canMinimize) { perform(.minimize) })
        menu.addItem(ClosureMenuItem("Maximize", symbol: "square", enabled: canMaximize && !maximized) { perform(.maximize) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Close", symbol: "xmark") { perform(.close) })
        if let app = appMenu(pid: pid), !app.items.isEmpty {
            menu.addItem(.separator())
            for item in app.items { app.removeItem(item); menu.addItem(item) }
        }
        startPrefetch(menu)
        menu.popUp(positioning: nil, at: point, in: nil)
        endPrefetch()
        sources.removeAll()
    }

    /// Option tap (Alt on Windows): the front app's menus, under its focused window's caption buttons.
    func openForFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let pid = app.processIdentifier
        var point: NSPoint
        if let w = AX.focusedWindow(pid), let id = AX.windowID(w), let e = CaptionController.shared.entry(id), e.shown {
            let r = e.showsMenu ? e.view.screenRect(of: .menu) : e.panel.frame
            point = NSPoint(x: r.minX, y: r.minY - 2)
        } else if let w = AX.focusedWindow(pid), let f = AX.frame(w), f.width > 0 {
            let r = CaptionController.shared.cocoaRect(f)
            point = NSPoint(x: r.minX + 8, y: r.maxY - 30)
        } else {
            let s = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
            let v = s?.frame ?? .zero
            point = NSPoint(x: v.minX + 8, y: v.maxY - 8)
        }
        popUpAppMenu(pid: pid, at: point)
    }

    /// A menu bar icon's menu above the tray, if its menu can be read while closed (apps that attach an NSMenu
    /// to their status item). nil when the app builds its menu on click or shows a panel: the caller then
    /// presses the icon itself, which opens it under the (revealed) menu bar.
    func extraMenu(_ extra: AXUIElement) -> NSMenu? {
        sources.removeAll()
        guard let axMenu = Self.menuChild(of: extra),
              let kids: [AXUIElement] = AX.attr(axMenu, kAXChildrenAttribute), !kids.isEmpty else { return nil }
        // Items drawn with custom views have no title: those menus can't be mirrored faithfully.
        for k in kids {
            let title: String = AX.attr(k, kAXTitleAttribute) ?? ""
            let sub: [AXUIElement] = AX.attr(k, kAXChildrenAttribute) ?? []
            if title.isEmpty && !sub.isEmpty && Self.menuChild(of: k) == nil { return nil }
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        fill(menu, items: MenuReader.items(of: axMenu, depth: 0))
        return menu.items.isEmpty ? nil : menu
    }

    // MARK: Building

    func appMenu(pid: pid_t) -> NSMenu? {
        guard let bar = AX.elementAttr(AX.app(pid), kAXMenuBarAttribute),
              let tops: [AXUIElement] = AX.attr(bar, kAXChildrenAttribute), !tops.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (i, top) in tops.enumerated() {
            let title: String = AX.attr(top, kAXTitleAttribute) ?? ""
            guard i == 0 || !title.isEmpty else { continue }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = AX.attr(top, kAXEnabledAttribute) ?? true
            if i == 0 {
                item.title = "Apple"
                item.image = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: "Apple")
            } else if i == 1 {
                item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0).bold])
            }
            item.submenu = lazySubmenu(title: title, for: top)
            menu.addItem(item)
        }
        return menu
    }

    private func lazySubmenu(title: String, for parent: AXUIElement) -> NSMenu {
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        sub.delegate = self
        sub.addItem(NSMenuItem(title: "…", action: nil, keyEquivalent: ""))   // placeholder until it opens
        sources[ObjectIdentifier(sub)] = parent
        return sub
    }

    // MARK: Prefetch

    /// Starts reading every lazy submenu of `menu` (the app's top-level menus) in the background, in order.
    private func startPrefetch(_ menu: NSMenu) {
        endPrefetch()
        let jobs = menu.items.compactMap { item -> (ObjectIdentifier, AXUIElement)? in
            guard let sub = item.submenu, let parent = sources[ObjectIdentifier(sub)] else { return nil }
            return (ObjectIdentifier(sub), parent)
        }
        guard !jobs.isEmpty else { return }
        let p = MenuPrefetch(jobs.map { (MenuPrefetch.Key($0.0), $0.1) })
        prefetch = p
        p.start()
    }

    /// Diagnostics: the dropdown's background reads without opening it.
    func debugStartPrefetch(_ menu: NSMenu) { startPrefetch(menu) }
    func debugEndPrefetch() { endPrefetch() }

    private func endPrefetch() {
        prefetch?.cancel()
        prefetch = nil
    }

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            let id = ObjectIdentifier(menu)
            guard let parent = sources[id], !filled.contains(id) else { return }
            filled.insert(id)
            let t0 = CFAbsoluteTimeGetCurrent()
            defer { trace.built(CFAbsoluteTimeGetCurrent() - t0) }
            // Prefetched (or being read right now: wait for it rather than ask the app twice); else read it here.
            var items = prefetch?.take(MenuPrefetch.Key(id))
            let ready = items != nil
            if items == nil { items = Self.menuChild(of: parent).map { MenuReader.items(of: $0, depth: 0) } ?? [] }
            menu.removeAllItems()
            fill(menu, items: items ?? [])
            if menu.items.isEmpty {
                let none = NSMenuItem(title: "(empty)", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
            }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            if ms > 30, trace.active == false { Log.write("appmenus: '\(menu.title)' took \(Int(ms)) ms (\(ready ? "prefetched" : "read on open"))") }
        }
    }

    private static func menuChild(of el: AXUIElement) -> AXUIElement? { MenuReader.menuChild(of: el) }

    private func fill(_ menu: NSMenu, items: [MenuReader.Item]) {
        var lastWasSeparator = true
        var primary: MenuReader.Item?
        for el in items {
            let title = el.title
            // Option alternates ("Restart" next to "Restart...", "Close All" next to "Close Window") are listed by AX
            // like any other item: no flag marks them. AppKit only allows them right after their primary, with the
            // same key plus more modifiers, and they are nearly always the Option variant. Those are left out.
            if let p = primary, !title.isEmpty, el.isAlternate(of: p) { continue }
            if !title.isEmpty { primary = el }
            if title.isEmpty && el.submenu == nil {
                if !lastWasSeparator { menu.addItem(.separator()); lastWasSeparator = true }
                continue
            }
            let item = NSMenuItem(title: title.isEmpty ? " " : title, action: nil, keyEquivalent: "")
            item.isEnabled = el.enabled
            if !el.mark.isEmpty { item.state = el.mark == "-" ? .mixed : .on }
            if el.submenu != nil {
                if let children = el.children {
                    // Read ahead with its parent: built now, nothing to wait for when it opens.
                    let m = NSMenu(title: title)
                    m.autoenablesItems = false
                    fill(m, items: children)
                    if m.items.isEmpty {
                        let none = NSMenuItem(title: "(empty)", action: nil, keyEquivalent: "")
                        none.isEnabled = false
                        m.addItem(none)
                    }
                    item.submenu = m
                } else {
                    item.submenu = lazySubmenu(title: title, for: el.element)
                }
            } else {
                item.action = #selector(pick(_:))
                item.target = self
                item.representedObject = AXRef(el.element)
                applyShortcut(item, el)
            }
            menu.addItem(item)
            lastWasSeparator = false
        }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }

    /// Shows the item's keyboard shortcut (display only: the app still handles the real shortcut).
    private func applyShortcut(_ item: NSMenuItem, _ el: MenuReader.Item) {
        let ch = el.cmdChar
        guard let c = ch.first, ch.count == 1, !c.isWhitespace,
              c.unicodeScalars.first.map({ $0.value >= 0x20 }) == true else { return }
        let mods = el.mods
        var m: NSEvent.ModifierFlags = []
        if mods & 8 == 0 { m.insert(.command) }          // kAXMenuItemModifierNoCommand
        if mods & 1 != 0 { m.insert(.shift) }
        if mods & 2 != 0 { m.insert(.option) }
        if mods & 4 != 0 { m.insert(.control) }
        guard !m.isEmpty else { return }
        item.keyEquivalent = ch.lowercased()
        item.keyEquivalentModifierMask = m
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? AXRef else { return }
        // After the menu has closed, so the app sees an idle menu bar.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let ok = AX.perform(ref.element, kAXPressAction)
                Log.write("appmenus: pressed an item, ok=\(ok)")   // not its title: it can be a document name
            }
        }
    }
}

/// One log line per Option-tap dropdown: how long after the Option release it appeared, how often the highlight
/// moved and the longest gap between moves, time spent building submenus, and main-thread run loop passes that
/// took over 20 ms while it was open (in the run loop mode the menu tracks in).
@MainActor
final class MenuTrace {
    nonisolated(unsafe) static var tapAt: CFTimeInterval = 0
    private(set) var active = false
    private var started: CFTimeInterval = 0
    private var shownAt: CFTimeInterval?
    private var tapDelay: CFTimeInterval?
    private var highlights = 0
    private var lastHighlight: CFTimeInterval = 0
    private var maxGap: CFTimeInterval = 0
    private var opens = 0
    private var buildTime: CFTimeInterval = 0
    private var maxBuild: CFTimeInterval = 0
    private var observer: CFRunLoopObserver?
    private var observedMode: CFRunLoopMode?
    fileprivate var passStart: CFTimeInterval = 0
    fileprivate var slowPasses = 0
    fileprivate var maxPass: CFTimeInterval = 0
    fileprivate var passes = 0

    func begin() {
        active = true
        started = CACurrentMediaTime()
        tapDelay = MenuTrace.tapAt > 0 && started - MenuTrace.tapAt < 2 ? started - MenuTrace.tapAt : nil
        MenuTrace.tapAt = 0
        shownAt = nil; highlights = 0; lastHighlight = 0; maxGap = 0; opens = 0; buildTime = 0; maxBuild = 0
        slowPasses = 0; maxPass = 0; passes = 0
    }

    func opened(_ menu: NSMenu) {
        guard active else { return }
        opens += 1
        if shownAt == nil { shownAt = CACurrentMediaTime() }
        watchRunLoop()
    }

    func highlighted() {
        guard active else { return }
        let now = CACurrentMediaTime()
        if lastHighlight > 0 { maxGap = max(maxGap, now - lastHighlight) }
        lastHighlight = now
        highlights += 1
    }

    func built(_ t: CFTimeInterval) {
        guard active else { return }
        buildTime += t
        maxBuild = max(maxBuild, t)
    }

    /// Times each pass of the main run loop in the common modes (menu tracking runs in NSEventTrackingRunLoopMode).
    private func watchRunLoop() {
        guard observer == nil else { return }
        let mode = CFRunLoopMode.commonModes
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue
                                                   | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, activity in
            MainActor.assumeIsolated {
                let t = AppMenus.shared.traceRef
                let now = CACurrentMediaTime()
                if activity == .afterWaiting { t.passStart = now; return }
                guard t.passStart > 0 else { return }
                let d = now - t.passStart
                t.passes += 1
                t.maxPass = max(t.maxPass, d)
                if d > 0.02 { t.slowPasses += 1 }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, mode)
        observer = o
        observedMode = mode
    }

    func end() {
        guard active else { return }
        active = false
        if let o = observer, let m = observedMode { CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, m) }
        let mode = observedMode.map { $0.rawValue as String } ?? "?"
        observer = nil; observedMode = nil
        let ms = { (t: CFTimeInterval) in Int((t * 1000).rounded()) }
        let open = CACurrentMediaTime() - started
        Log.write("appmenus: trace: shown \(tapDelay.map { "\(ms($0)) ms after Option up, " } ?? "")"
                  + "\(shownAt.map { "\(ms($0 - started)) ms after popUp" } ?? "never"), open \(ms(open)) ms, "
                  + "\(highlights) highlights (longest gap \(ms(maxGap)) ms), \(opens) menus opened, "
                  + "building \(ms(buildTime)) ms (max \(ms(maxBuild))), run loop [\(mode)] \(passes) passes, "
                  + "\(slowPasses) over 20 ms (max \(ms(maxPass)))")
    }
}

/// Reads menus through Accessibility on any thread: one AX call per item (`AXUIElementCopyMultipleAttributeValues`)
/// instead of one per attribute.
enum MenuReader {
    struct Item: @unchecked Sendable {        // AXUIElement is a thread-safe CF type
        let element: AXUIElement
        let title: String
        let enabled: Bool
        let mark: String
        let cmdChar: String
        let key: String           // char, glyph or virtual key; "" = no shortcut (for spotting Option alternates)
        let mods: Int             // kAXMenuItemModifier bits: 1 Shift, 2 Option, 4 Control, 8 No Command
        let submenu: AXUIElement? // its AXMenu child
        var children: [Item]?     // the submenu's items, when read ahead

        func isAlternate(of p: Item) -> Bool {
            let a = mods & 7, b = p.mods & 7
            guard key == p.key, a != b, a & b == b else { return false }
            return (a & ~b) & 2 != 0 || b & 2 != 0
        }
    }

    private static let names = [kAXRoleAttribute, kAXTitleAttribute, kAXEnabledAttribute, kAXMenuItemMarkCharAttribute,
                                kAXMenuItemCmdCharAttribute, kAXMenuItemCmdGlyphAttribute,
                                kAXMenuItemCmdVirtualKeyAttribute, kAXMenuItemCmdModifiersAttribute,
                                kAXChildrenAttribute] as CFArray

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
        return v as? [AXUIElement] ?? []
    }

    static func role(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    static func menuChild(of el: AXUIElement) -> AXUIElement? {
        children(el).first { role($0) == kAXMenuRole }
    }

    /// The menu's items; submenus `depth` levels down are read too (0 = this menu only).
    static func items(of axMenu: AXUIElement, depth: Int, cancelled: () -> Bool = { false }) -> [Item] {
        var out: [Item] = []
        for el in children(axMenu) {
            if cancelled() { return out }
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(el, names, AXCopyMultipleAttributeOptions(), &raw) == .success,
                  let v = raw as? [Any], v.count == 9 else { continue }
            // Missing attributes come back as AXValue errors: the casts below turn them into defaults.
            guard (v[0] as? String) == kAXMenuItemRole else { continue }
            let ch = v[4] as? String ?? ""
            let glyph = (v[5] as? NSNumber)?.intValue ?? 0
            let vk = (v[6] as? NSNumber)?.intValue ?? -1
            let key = !ch.isEmpty ? ch.lowercased() : (glyph != 0 ? "g\(glyph)" : (vk >= 0 ? "v\(vk)" : ""))
            let kids = v[8] as? [AXUIElement] ?? []
            let sub = kids.first { role($0) == kAXMenuRole }
            var item = Item(element: el, title: v[1] as? String ?? "", enabled: (v[2] as? NSNumber)?.boolValue ?? true,
                            mark: v[3] as? String ?? "", cmdChar: ch, key: key,
                            mods: (v[7] as? NSNumber)?.intValue ?? 0, submenu: sub, children: nil)
            if let sub, depth > 0 { item.children = items(of: sub, depth: depth - 1, cancelled: cancelled) }
            out.append(item)
        }
        return out
    }
}

/// Reads an open dropdown's menus on a background thread, in order. A menu the pointer reaches first is read on
/// the spot by the main thread instead (claimed, so the app isn't asked twice); one being read is waited for.
final class MenuPrefetch: @unchecked Sendable {
    struct Key: Hashable, @unchecked Sendable {
        let raw: ObjectIdentifier
        init(_ id: ObjectIdentifier) { raw = id }
    }
    private enum Slot { case pending(AXUIElement), reading, done([MenuReader.Item]) }
    private let cond = NSCondition()
    private var slots: [Key: Slot] = [:]
    private let order: [Key]
    private var cancelled = false

    init(_ jobs: [(Key, AXUIElement)]) {
        order = jobs.map(\.0)
        for (k, el) in jobs { slots[k] = .pending(el) }
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            for k in order {
                guard let el = claim(k) else { continue }
                let items = MenuReader.menuChild(of: el).map {
                    MenuReader.items(of: $0, depth: 1, cancelled: { [self] in isCancelled })
                } ?? []
                finish(k, items)
                if isCancelled { return }
            }
        }
    }

    func cancel() {
        cond.lock(); cancelled = true; cond.broadcast(); cond.unlock()
    }

    private var isCancelled: Bool { cond.lock(); defer { cond.unlock() }; return cancelled }

    private func claim(_ k: Key) -> AXUIElement? {
        cond.lock(); defer { cond.unlock() }
        guard !cancelled, case .pending(let el) = slots[k] else { return nil }
        slots[k] = .reading
        return el
    }

    private func finish(_ k: Key, _ items: [MenuReader.Item]) {
        cond.lock(); slots[k] = .done(items); cond.broadcast(); cond.unlock()
    }

    /// The menu's items for the main thread: ready ones at once, one being read after it finishes (at most 0.5 s),
    /// one not started yet read right here. nil if this dropdown doesn't know the menu.
    func take(_ k: Key) -> [MenuReader.Item]? {
        cond.lock()
        let deadline = Date().addingTimeInterval(0.5)
        while case .reading = slots[k], !cancelled {
            if !cond.wait(until: deadline) { break }
        }
        switch slots[k] {
        case .done(let items)?:
            cond.unlock()
            return items
        case .pending(let el)?:
            slots[k] = .reading
            cond.unlock()
            // Read on the spot: this menu only (its submenus are read when they open).
            let items = MenuReader.menuChild(of: el).map { MenuReader.items(of: $0, depth: 0) } ?? []
            finish(k, items)
            return items
        default:
            cond.unlock()
            return nil
        }
    }
}

private extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}
