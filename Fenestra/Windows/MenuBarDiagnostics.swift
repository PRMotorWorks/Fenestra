import AppKit
import ScreenCaptureKit

/// Diagnostics only (Phase 6): logs what Accessibility and the window list expose about menu bar extras
/// and app menus. Triggered by the distributed notification "local.fenestra.debug.menubar":
///   object "dump"            read-only: every app's AXExtrasMenuBar, menu bar layer windows, icon captures
///   object "press <ident>"   presses one extra, logs where its menu opened, then cancels it
///   object "tap <ident> [action]"  performs the action (AXPress) and leaves what opens alone (sends no keys);
///                            logs the AX result and every window that appears, whoever owns it
///   object "menus <App>"     times reading that app's whole menu bar tree
///   object "build <App>"     builds the Phase 6 dropdown for that app (nothing opens) and logs it
/// Results go to the app log (prefix "menubartest:") and ~/Library/Logs/Fenestra-dragtest/extra-*.png.
@MainActor
enum MenuBarDiagnostics {
    static func install() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.fenestra.debug.menubar"), object: nil, queue: .main
        ) { n in
            let parts = (n.object as? String ?? "dump").split(separator: " ", maxSplits: 1).map(String.init)
            MainActor.assumeIsolated {
                Task { @MainActor in
                    switch parts[0] {
                    case "press": await press(parts.count > 1 ? parts[1] : "")
                    case "tap": await tap(parts.count > 1 ? parts[1] : "")
                    case "menus": menus(parts.count > 1 ? parts[1] : "Finder")
                    case "build": build(parts.count > 1 ? parts[1] : "Finder")
                    case "attrs": attrs(parts.count > 1 ? parts[1] : "Finder")
                    default: await dump()
                    }
                }
            }
        }
    }

    private static func log(_ s: String) { Log.write("menubartest: " + s) }

    private static func describe(_ el: AXUIElement) -> String {
        let role: String = AX.attr(el, kAXRoleAttribute) ?? "?"
        let sub: String = AX.attr(el, kAXSubroleAttribute) ?? ""
        let ident: String = AX.attr(el, kAXIdentifierAttribute) ?? ""
        let title: String = AX.attr(el, kAXTitleAttribute) ?? ""
        let desc: String = AX.attr(el, kAXDescriptionAttribute) ?? ""
        let help: String = AX.attr(el, kAXHelpAttribute) ?? ""
        let kids: [AXUIElement] = AX.attr(el, kAXChildrenAttribute) ?? []
        var names: CFArray?
        AXUIElementCopyActionNames(el, &names)
        let actions = (names as? [String] ?? []).joined(separator: ",")
        let f = AX.frame(el).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-"
        return "role=\(role)/\(sub) id='\(ident)' title='\(title)' desc='\(desc)' help='\(help)' frame=\(f) kids=\(kids.count) actions=\(actions)"
    }

    static func dump() async {
        log("dump begins, _HIHideMenuBar=\(UserDefaults(suiteName: ".GlobalPreferences")?.bool(forKey: "_HIHideMenuBar") ?? false)")
        let t0 = Date()
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            let el = AX.app(app.processIdentifier)
            guard let bar = AX.elementAttr(el, "AXExtrasMenuBar"),
                  let items: [AXUIElement] = AX.attr(bar, kAXChildrenAttribute), !items.isEmpty else { continue }
            log("\(app.bundleIdentifier ?? "?") pid=\(app.processIdentifier) policy=\(app.activationPolicy.rawValue): \(items.count) extra(s)")
            for item in items {
                log("  " + describe(item))
                if let kids: [AXUIElement] = AX.attr(item, kAXChildrenAttribute), let m = kids.first {
                    let mk: [AXUIElement] = AX.attr(m, kAXChildrenAttribute) ?? []
                    log("    closed menu: " + describe(m) + " items=\(mk.count)")
                }
            }
        }
        log("AX scan took \(Int(Date().timeIntervalSince(t0) * 1000)) ms")

        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var ids: [CGWindowID] = []
        for w in list where (w[kCGWindowLayer as String] as? Int) == 25 {
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let id = w[kCGWindowNumber as String] as? CGWindowID ?? 0
            log("window \(id) owner=\(w[kCGWindowOwnerName as String] ?? "") pid=\(w[kCGWindowOwnerPID as String] ?? 0) name='\(w[kCGWindowName as String] ?? "")' " +
                "bounds=\(b["X"] ?? 0),\(b["Y"] ?? 0) \(b["Width"] ?? 0)x\(b["Height"] ?? 0) onscreen=\(w[kCGWindowIsOnscreen as String] ?? 0)")
            ids.append(id)
        }
        // Can ScreenCaptureKit see (and capture) those windows, onscreen or not?
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Fenestra-dragtest")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for id in ids {
                guard let w = content.windows.first(where: { $0.windowID == id }) else { log("sck: \(id) not shareable"); continue }
                let cfg = SCStreamConfiguration()
                cfg.width = Int(w.frame.width * 2); cfg.height = Int(w.frame.height * 2)
                cfg.showsCursor = false
                cfg.ignoreShadowsSingleWindow = true
                let filter = SCContentFilter(desktopIndependentWindow: w)
                let t = Date()
                if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) {
                    let rep = NSBitmapImageRep(cgImage: img)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("extra-\(id).png"))
                    log("sck: \(id) '\(w.title ?? "")' captured \(img.width)x\(img.height) onscreen=\(w.isOnScreen) in \(Int(Date().timeIntervalSince(t) * 1000)) ms")
                } else {
                    log("sck: \(id) capture failed")
                }
            }
        } catch {
            log("sck: shareable content failed: \(error)")
        }
        log("dump done")
    }

    private static func findExtra(_ ident: String) -> AXUIElement? {
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            guard let bar = AX.elementAttr(AX.app(app.processIdentifier), "AXExtrasMenuBar"),
                  let items: [AXUIElement] = AX.attr(bar, kAXChildrenAttribute) else { continue }
            for item in items {
                let id: String = AX.attr(item, kAXIdentifierAttribute) ?? ""
                let d: String = AX.attr(item, kAXDescriptionAttribute) ?? ""
                if id == ident || d == ident || app.bundleIdentifier == ident { return item }
            }
        }
        return nil
    }

    static func press(_ arg: String) async {
        let words = arg.split(separator: " ").map(String.init)
        let ident = words.first ?? "", action = words.count > 1 ? words[1] : kAXPressAction
        guard let item = findExtra(ident) else { log("press: '\(ident)' not found"); return }
        log("press: " + describe(item))
        var names: CFArray?
        AXUIElementCopyActionNames(item, &names)
        log("press: actions \(names as? [String] ?? [])")
        let before = Set(menuWindows().map(\.0))
        let ok = AX.perform(item, action)
        log("press: \(action)=\(ok)")
        try? await Task.sleep(for: .milliseconds(700))
        log("press after: " + describe(item))
        if let kids: [AXUIElement] = AX.attr(item, kAXChildrenAttribute) {
            for k in kids {
                log("  child " + describe(k))
                for mi in (AX.attr(k, kAXChildrenAttribute) as [AXUIElement]? ?? []).prefix(12) { log("    " + describe(mi)) }
            }
        }
        for (id, desc) in menuWindows() where !before.contains(id) { log("  new window \(id): \(desc)") }
        let bar = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in bar where (w[kCGWindowLayer as String] as? Int) == 24 {
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            log("  menubar window y=\(b["Y"] ?? 0) name='\(w[kCGWindowName as String] ?? "")'")
        }
        try? await Task.sleep(for: .milliseconds(500))
        if let kids: [AXUIElement] = AX.attr(item, kAXChildrenAttribute), let m = kids.first, AX.perform(m, kAXCancelAction) {
            log("press: cancelled through AXCancel")
        } else {
            SystemActions.postKey(53, flags: [])      // Escape
            log("press: cancelled with Escape")
        }
    }

    static func tap(_ arg: String) async {
        let words = arg.split(separator: " ").map(String.init)
        let ident = words.first ?? "", action = words.count > 1 ? words[1] : kAXPressAction
        guard let item = findExtra(ident) else { log("tap: '\(ident)' not found"); return }
        var names: CFArray?
        AXUIElementCopyActionNames(item, &names)
        log("tap: " + describe(item) + " actions \(names as? [String] ?? [])")
        let before = Set(allWindows().map(\.0))
        let err = AXUIElementPerformAction(item, action as CFString)
        log("tap: \(action) -> AXError \(err.rawValue)")
        for ms in [200, 600, 1200] {
            try? await Task.sleep(for: .milliseconds(ms == 200 ? 200 : ms / 2))
            let new = allWindows().filter { !before.contains($0.0) }
            log("tap: +\(ms) ms \(new.count) new window(s) " + new.map(\.1).joined(separator: "; "))
        }
    }

    private static func allWindows() -> [(CGWindowID, String)] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.map { w in
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let id = w[kCGWindowNumber as String] as? CGWindowID ?? 0
            return (id, "layer=\(w[kCGWindowLayer as String] ?? 0) owner=\(w[kCGWindowOwnerName as String] ?? "") "
                + "bounds=\(b["X"] ?? 0),\(b["Y"] ?? 0) \(b["Width"] ?? 0)x\(b["Height"] ?? 0)")
        }
    }

    private static func menuWindows() -> [(CGWindowID, String)] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { w in
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard layer > 0, layer != 25, layer != 24 else { return nil }
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let id = w[kCGWindowNumber as String] as? CGWindowID ?? 0
            return (id, "layer=\(layer) owner=\(w[kCGWindowOwnerName as String] ?? "") bounds=\(b["X"] ?? 0),\(b["Y"] ?? 0) \(b["Width"] ?? 0)x\(b["Height"] ?? 0)")
        }
    }

    /// Attribute names and values of every Apple menu item (finding what marks Option alternates).
    static func attrs(_ name: String) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }),
              let bar = AX.elementAttr(AX.app(app.processIdentifier), kAXMenuBarAttribute),
              let tops: [AXUIElement] = AX.attr(bar, kAXChildrenAttribute), let apple = tops.first,
              let m = (AX.attr(apple, kAXChildrenAttribute) as [AXUIElement]?)?.first,
              let items: [AXUIElement] = AX.attr(m, kAXChildrenAttribute) else { log("attrs: nothing"); return }
        for (i, el) in items.enumerated() {
            var names: CFArray?
            AXUIElementCopyAttributeNames(el, &names)
            var vals: [String] = []
            for n in names as? [String] ?? [] where !["AXParent", "AXTopLevelUIElement", "AXWindow", "AXChildren", "AXChildrenInNavigationOrder"].contains(n) {
                var v: CFTypeRef?
                let err = AXUIElementCopyAttributeValue(el, n as CFString, &v)
                var str = err == .success ? String(describing: v!) : "err\(err.rawValue)"
                if let v, CFGetTypeID(v) == AXUIElementGetTypeID() { str = CFEqual(v, el) ? "<self>" : "<other>" }
                vals.append("\(n)=\(str.prefix(40))")
            }
            log("attrs \(i): " + vals.joined(separator: " "))
        }
    }

    static func build(_ name: String) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) else {
            log("build: \(name) not running"); return
        }
        let t0 = Date()
        guard let menu = AppMenus.shared.appMenu(pid: app.processIdentifier) else { log("build: no menu"); return }
        log("build: \(name) top \(menu.items.map(\.title)) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        for i in [0, 2] where i < menu.items.count {
            guard let sub = menu.items[i].submenu else { continue }
            let t = Date()
            AppMenus.shared.menuNeedsUpdate(sub)
            let desc = sub.items.map { $0.isSeparatorItem ? "---" :
                "\($0.title)\($0.isEnabled ? "" : " (off)")\($0.keyEquivalent.isEmpty ? "" : " [\($0.keyEquivalent)]")\($0.submenu != nil ? " >" : "")" }
            log("build: \(menu.items[i].title) (\(Int(Date().timeIntervalSince(t) * 1000)) ms): " + desc.joined(separator: " | "))
        }
    }

    static func menus(_ name: String) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) else {
            log("menus: \(name) not running"); return
        }
        let t0 = Date()
        guard let bar = AX.elementAttr(AX.app(app.processIdentifier), kAXMenuBarAttribute),
              let tops: [AXUIElement] = AX.attr(bar, kAXChildrenAttribute) else { log("menus: no menu bar"); return }
        var count = 0
        func walk(_ el: AXUIElement, depth: Int) {
            guard depth < 4, let kids: [AXUIElement] = AX.attr(el, kAXChildrenAttribute) else { return }
            for k in kids { count += 1; walk(k, depth: depth + 1) }
        }
        let titles = tops.map { (AX.attr($0, kAXTitleAttribute) as String?) ?? "?" }
        let t1 = Date()
        if let first = tops.dropFirst(2).first { walk(first, depth: 0) }
        let fileMs = Int(Date().timeIntervalSince(t1) * 1000)
        for t in tops { walk(t, depth: 0) }
        log("menus: \(name) tops=\(titles) elements=\(count) top read \(Int(t1.timeIntervalSince(t0) * 1000)) ms, " +
            "File tree \(fileMs) ms, all \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        if let apple = tops.first, let kids: [AXUIElement] = AX.attr(apple, kAXChildrenAttribute), let m = kids.first {
            for mi in (AX.attr(m, kAXChildrenAttribute) as [AXUIElement]? ?? []) { log("  apple: " + describe(mi)) }
        }
    }
}
