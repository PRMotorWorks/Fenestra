import AppKit
import Collaboration

/// Start's power and account actions, wired to the real macOS actions.
@MainActor
enum PowerActions {
    static func sleep() { Shell.run("/usr/bin/pmset", ["sleepnow"]) }

    // Apple events to loginwindow (Apple Technical Q&A QA1134). Public. macOS may ask once
    // whether Fenestra may control "loginwindow" (Automation permission).
    static func restart() { send(AEEventID(kAERestart), fallback: "restart") }
    static func shutDown() { send(AEEventID(kAEShutDown), fallback: "shut down") }
    static func signOut() { send(AEEventID(kAEReallyLogOut), fallback: "log out") }

    private static func send(_ id: AEEventID, fallback: String) {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow")
        let ev = NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kCoreEventClass), eventID: id,
                                                   targetDescriptor: target,
                                                   returnID: AEReturnID(kAutoGenerateReturnID),
                                                   transactionID: AETransactionID(kAnyTransactionID))
        do {
            _ = try ev.sendEvent(options: [.noReply], timeout: 5)
        } catch {
            Log.write("loginwindow event failed (\(error.localizedDescription)); using System Events")
            NSAppleScript(source: "tell application \"System Events\" to \(fallback)")?.executeAndReturnError(nil)
        }
    }

    /// PRIVATE: SACLockScreenImmediate from login.framework (same as Control Center's Lock Screen).
    /// Fallback: Ctrl+Cmd+Q, the macOS lock shortcut.
    static func lock() {
        typealias Fn = @convention(c) () -> Int32
        if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let sym = dlsym(h, "SACLockScreenImmediate") {
            _ = unsafeBitCast(sym, to: Fn.self)()
        } else {
            SystemActions.postKey(12, flags: [.maskCommand, .maskControl])
        }
    }

    static var userName: String { NSFullUserName() }

    /// Account picture, cropped to a small circle (the original can be a large photo).
    static let userImage: NSImage? = {
        guard let src = CBIdentity(name: NSUserName(), authority: CBIdentityAuthority.default())?.image,
              src.size.width > 0, src.size.height > 0 else { return nil }
        let side = min(src.size.width, src.size.height)
        let crop = NSRect(x: (src.size.width - side) / 2, y: (src.size.height - side) / 2, width: side, height: side)
        return NSImage(size: NSSize(width: 64, height: 64), flipped: false) { r in
            NSBezierPath(ovalIn: r).addClip()
            src.draw(in: r, from: crop, operation: .sourceOver, fraction: 1)
            return true
        }
    }()

    static func accountMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(menuItem("Change account settings") {
            StartController.shared.hide()
            SystemActions.openSettings("com.apple.Users-Groups-Settings.extension")
        })
        m.addItem(.separator())
        m.addItem(menuItem("Lock") { StartController.shared.hide(animated: false); lock() })
        m.addItem(menuItem("Sign out") { signOut() })
        return m
    }

    static func powerMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(menuItem("Sleep", "moon") { StartController.shared.hide(animated: false); sleep() })
        m.addItem(menuItem("Shut down", "power") { shutDown() })
        m.addItem(menuItem("Restart", "arrow.clockwise") { restart() })
        return m
    }

    private static func menuItem(_ title: String, _ symbol: String? = nil, _ f: @escaping () -> Void) -> NSMenuItem {
        let a = MenuAction(f)
        let mi = NSMenuItem(title: title, action: #selector(MenuAction.run(_:)), keyEquivalent: "")
        mi.target = a
        mi.representedObject = a
        if let symbol { mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return mi
    }

    /// Opens a menu just above a button (screen rect), the way Start's bottom-bar menus open on Windows.
    static func popUp(_ menu: NSMenu, above rect: NSRect) {
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + menu.size.height + 4), in: nil)
    }

    static func openFolder(_ f: StartFolder) {
        StartController.shared.hide()
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch f {
        case .settings: SystemActions.openApp("/System/Applications/System Settings.app")
        case .explorer: NSWorkspace.shared.open(home)
        case .documents: NSWorkspace.shared.open(home.appendingPathComponent("Documents"))
        case .downloads: NSWorkspace.shared.open(home.appendingPathComponent("Downloads"))
        case .music: NSWorkspace.shared.open(home.appendingPathComponent("Music"))
        case .pictures: NSWorkspace.shared.open(home.appendingPathComponent("Pictures"))
        case .videos: NSWorkspace.shared.open(home.appendingPathComponent("Movies"))
        case .network: NSWorkspace.shared.open(URL(fileURLWithPath: "/Network"))
        case .personal: NSWorkspace.shared.open(home)
        }
    }
}
