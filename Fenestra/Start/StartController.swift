import AppKit
import SwiftUI

/// Owns the Start panel. Built once at launch and kept alive, so opening is just an order-in
/// plus the Windows 11 slide-up (200 ms, ease-out); this keeps it well under 150 ms.
@MainActor
final class StartController: ObservableObject {
    static let shared = StartController()

    @Published private(set) var isOpen = false
    @Published var focusToken = 0             // bumping it focuses the search box
    @Published var resetToken = 0             // bumping it resets scroll/expanded state

    private var panel: FlyoutPanel?
    private var globalClick: Any?
    private var resignObserver: Any?
    static let size = NSSize(width: 720, height: 700)

    func prepare() {
        guard panel == nil else { return }
        let p = FlyoutPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let host = NSHostingView(rootView: StartView())
        host.sizingOptions = []
        host.roundCorners(8)                 // Windows 11: 8 px corners
        p.contentView = host
        ArrowCursor.install(on: host)
        panel = p
        StartModel.shared.reloadApps()
    }

    private var closedByClickAt = Date.distantPast
    private var localClick: Any?

    func toggle() {
        if isOpen { hide(); return }
        // The click that just closed Start (on the Start button) must not reopen it.
        if Date().timeIntervalSince(closedByClickAt) < 0.35 { return }
        show(searchFocused: false)
    }

    /// Phase 5: Start opens on the display under the pointer when that display has a taskbar (clicking a
    /// secondary taskbar's Start button, or tapping Command with the pointer there), else on the main display.
    private var openScreen: NSScreen?

    private var targetFrame: NSRect {
        let screen = openScreen ?? TaskbarController.shared.screen ?? NSScreen.screens[0]
        let h = min(Self.size.height, screen.frame.height - Theme.taskbarHeight - 24)
        let x: CGFloat = AppSettings.shared.alignment == .left
            ? screen.frame.minX + 12
            : screen.frame.midX - Self.size.width / 2
        return NSRect(x: x, y: screen.frame.minY + Theme.taskbarHeight + 12, width: Self.size.width, height: h)
    }

    func show(searchFocused: Bool) {
        prepare()
        guard let p = panel else { return }
        FlyoutManager.shared.close(animated: false)
        ThumbnailController.shared.dismiss()
        let mouse = NSEvent.mouseLocation
        let tb = TaskbarController.shared
        openScreen = NSScreen.screens.first { $0.frame.contains(mouse) && tb.hasTaskbar($0) } ?? tb.screen
        tb.ensureVisible(on: openScreen)
        if !isOpen {
            StartModel.shared.query = ""
            resetToken += 1
            StartModel.shared.reloadIfStale()
        }
        isOpen = true
        let f = targetFrame
        p.setFrame(f.offsetBy(dx: 0, dy: -40), display: false)
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { p.invalidateShadow() }    // shadow follows the rounded corners
        focusToken += 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.1, 0.9, 0.2, 1)
            p.animator().alphaValue = 1
            p.animator().setFrame(f, display: true)
        }
        installDismissal()
    }

    func hide(animated: Bool = true) {
        guard isOpen, let p = panel else { return }
        isOpen = false
        removeDismissal()
        guard animated else { p.orderOut(nil); return }
        let f = p.frame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
            p.animator().setFrame(f.offsetBy(dx: 0, dy: -24), display: true)
        }, completionHandler: {
            MainActor.assumeIsolated { if !StartController.shared.isOpen { p.orderOut(nil) } }
        })
    }

    private func installDismissal() {
        removeDismissal()
        globalClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { StartController.shared.hide() }
        }
        localClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { e in
            MainActor.assumeIsolated {
                let c = StartController.shared
                if e.window !== c.panel, c.isOpen {
                    c.closedByClickAt = Date()
                    c.hide()
                }
            }
            return e
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                object: panel, queue: .main) { _ in
            MainActor.assumeIsolated {
                // Clicking the Start button itself toggles; anything else closes Start.
                let c = StartController.shared
                let startRect = c.openScreen.flatMap { TaskbarController.shared.bar(on: $0)?.panel.frame }
                    ?? TaskbarController.shared.frame
                if !startRect.contains(NSEvent.mouseLocation) { StartController.shared.hide() }
            }
        }
    }

    private func removeDismissal() {
        if let g = globalClick { NSEvent.removeMonitor(g) }
        if let l = localClick { NSEvent.removeMonitor(l) }
        if let r = resignObserver { NotificationCenter.default.removeObserver(r) }
        globalClick = nil
        localClick = nil
        resignObserver = nil
    }

    // MARK: Right-click on Start (Windows "Win+X" quick link menu)

    func showQuickLinkMenu(in view: NSView) {
        hide(animated: false)
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            let mi = NSMenuItem(title: title, action: #selector(MenuAction.run(_:)), keyEquivalent: "")
            let a = MenuAction(action)
            mi.target = a
            mi.representedObject = a
            menu.addItem(mi)
        }
        add("Installed apps") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications")) }
        add("Power options") { SystemActions.openSettings("com.apple.Battery-Settings.extension") }
        add("System") { SystemActions.openApp("/System/Applications/Utilities/System Information.app") }
        add("Disk management") { SystemActions.openApp("/System/Applications/Utilities/Disk Utility.app") }
        add("Terminal") { SystemActions.openApp("/System/Applications/Utilities/Terminal.app") }
        add("Task Manager") { SystemActions.openTaskManager() }
        add("Settings") { SystemActions.openApp("/System/Applications/System Settings.app") }
        add("File Explorer") { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser) }
        add("Search") { StartController.shared.show(searchFocused: true) }
        menu.addItem(.separator())
        let power = NSMenuItem(title: "Shut down or sign out", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (t, f) in [("Sign out", PowerActions.signOut), ("Sleep", PowerActions.sleep),
                       ("Shut down", PowerActions.shutDown), ("Restart", PowerActions.restart)] as [(String, () -> Void)] {
            let mi = NSMenuItem(title: t, action: #selector(MenuAction.run(_:)), keyEquivalent: "")
            let a = MenuAction(f)
            mi.target = a
            mi.representedObject = a
            sub.addItem(mi)
        }
        power.submenu = sub
        menu.addItem(power)
        add("Desktop") { TaskbarActions.toggleShowDesktop() }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }
}

/// Closure-backed target for NSMenu items (kept alive by the item's representedObject).
final class MenuAction: NSObject {
    let action: () -> Void
    init(_ a: @escaping () -> Void) { action = a }
    @objc func run(_ sender: Any?) { action() }
}

/// Tap Command alone = Windows key (opens/closes Start). Any other key or click while
/// Command is down cancels it, so Command shortcuts keep working. Needs Accessibility.
@MainActor
final class WinKey {
    static let shared = WinKey()
    private var downAt: Date?
    private var tainted = false
    private var monitors: [Any] = []

    func start() {
        guard monitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { e in MainActor.assumeIsolated { WinKey.shared.handle(e) } }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown,
                                                                .otherMouseDown, .scrollWheel], handler: handler) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown], handler: { e in
            handler(e); return e
        }) {
            monitors.append(l)
        }
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .flagsChanged:
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCommandKey = e.keyCode == 55 || e.keyCode == 54
            if isCommandKey && mods == .command {
                downAt = Date(); tainted = false
            } else if isCommandKey && !mods.contains(.command) {
                if let d = downAt, !tainted, Date().timeIntervalSince(d) < 0.6, AppSettings.shared.commandTapStart {
                    StartController.shared.toggle()
                }
                downAt = nil
            } else {
                tainted = true
            }
        default:
            if downAt != nil { tainted = true }
        }
    }
}
