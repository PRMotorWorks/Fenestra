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
/// menu bar is hidden. Read through Accessibility (`kAXMenuBarAttribute`), one menu at a time: a submenu is read
/// only when it opens (NSMenuDelegate), so opening the dropdown costs ~1 ms and each submenu ~10 ms. Choosing an
/// item presses the real menu item (AXPress), so the app runs its own command, with its own enabled state.
/// Also mirrors menu bar icons' menus above the tray (MenuExtras) and builds the caption's window menu.
@MainActor
final class AppMenus: NSObject, NSMenuDelegate {
    static let shared = AppMenus()

    /// Submenu -> the AX element whose AXMenu child it mirrors. Cleared each time a new dropdown opens.
    private var sources: [ObjectIdentifier: AXUIElement] = [:]

    // MARK: Opening

    /// The dropdown for the menu button and Option tap. `point` is the menu's top-left in screen coordinates.
    func popUpAppMenu(pid: pid_t, at point: NSPoint) {
        sources.removeAll()
        guard let menu = appMenu(pid: pid) else { Log.write("appmenus: pid \(pid) has no menu bar"); return }
        menu.popUp(positioning: nil, at: point, in: nil)
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
        menu.popUp(positioning: nil, at: point, in: nil)
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
        fill(menu, from: axMenu)
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

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            guard let parent = sources[ObjectIdentifier(menu)] else { return }
            menu.removeAllItems()
            if let axMenu = Self.menuChild(of: parent) { fill(menu, from: axMenu) }
            if menu.items.isEmpty {
                let none = NSMenuItem(title: "(empty)", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
            }
        }
    }

    private static func menuChild(of el: AXUIElement) -> AXUIElement? {
        let kids: [AXUIElement] = AX.attr(el, kAXChildrenAttribute) ?? []
        return kids.first { (AX.attr($0, kAXRoleAttribute) as String?) == kAXMenuRole }
    }

    private func fill(_ menu: NSMenu, from axMenu: AXUIElement) {
        let kids: [AXUIElement] = AX.attr(axMenu, kAXChildrenAttribute) ?? []
        var lastWasSeparator = true
        var primary: Shortcut?
        for el in kids {
            guard (AX.attr(el, kAXRoleAttribute) as String?) == kAXMenuItemRole else { continue }
            let title: String = AX.attr(el, kAXTitleAttribute) ?? ""
            // Option alternates ("Restart" next to "Restart...", "Close All" next to "Close Window") are listed by AX
            // like any other item: no flag marks them. AppKit only allows them right after their primary, with the
            // same key plus more modifiers, and they are nearly always the Option variant. Those are left out.
            let sc = Shortcut(el)
            if let p = primary, !title.isEmpty, sc.isAlternate(of: p) { continue }
            if !title.isEmpty { primary = sc }
            let sub = Self.menuChild(of: el)
            if title.isEmpty && sub == nil {
                if !lastWasSeparator { menu.addItem(.separator()); lastWasSeparator = true }
                continue
            }
            let item = NSMenuItem(title: title.isEmpty ? " " : title, action: nil, keyEquivalent: "")
            item.isEnabled = AX.attr(el, kAXEnabledAttribute) ?? true
            if let mark: String = AX.attr(el, kAXMenuItemMarkCharAttribute), !mark.isEmpty {
                item.state = mark == "-" ? .mixed : .on
            }
            if sub != nil {
                item.submenu = lazySubmenu(title: title, for: el)
            } else {
                item.action = #selector(pick(_:))
                item.target = self
                item.representedObject = AXRef(el)
                applyShortcut(item, el)
            }
            menu.addItem(item)
            lastWasSeparator = false
        }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }

    /// An item's key and modifiers as AX reports them (for spotting Option alternates).
    @MainActor private struct Shortcut {
        let key: String           // char, glyph or virtual key; "" = no shortcut
        let mods: Int             // kAXMenuItemModifier bits: 1 Shift, 2 Option, 4 Control (8 No Command dropped)
        init(_ el: AXUIElement) {
            let ch: String = AX.attr(el, kAXMenuItemCmdCharAttribute) ?? ""
            let glyph: Int = AX.attr(el, kAXMenuItemCmdGlyphAttribute) ?? 0
            let vk: Int = AX.attr(el, kAXMenuItemCmdVirtualKeyAttribute) ?? -1
            key = !ch.isEmpty ? ch.lowercased() : (glyph != 0 ? "g\(glyph)" : (vk >= 0 ? "v\(vk)" : ""))
            mods = (AX.attr(el, kAXMenuItemCmdModifiersAttribute) ?? 0) & 7
        }
        func isAlternate(of p: Shortcut) -> Bool {
            guard key == p.key, mods != p.mods, mods & p.mods == p.mods else { return false }
            return (mods & ~p.mods) & 2 != 0 || p.mods & 2 != 0
        }
    }

    /// Shows the item's keyboard shortcut (display only: the app still handles the real shortcut).
    private func applyShortcut(_ item: NSMenuItem, _ el: AXUIElement) {
        guard let ch: String = AX.attr(el, kAXMenuItemCmdCharAttribute), let c = ch.first,
              ch.count == 1, !c.isWhitespace, c.unicodeScalars.first.map({ $0.value >= 0x20 }) == true else { return }
        let mods: Int = AX.attr(el, kAXMenuItemCmdModifiersAttribute) ?? 0
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
        let title = sender.title
        // After the menu has closed, so the app sees an idle menu bar.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let ok = AX.perform(ref.element, kAXPressAction)
                Log.write("appmenus: pressed '\(title)' ok=\(ok)")
            }
        }
    }
}

private extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}
