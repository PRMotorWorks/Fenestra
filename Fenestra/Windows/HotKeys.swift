import AppKit
import os

/// Phase 4 keyboard shortcuts that the app in front must not also receive:
///   Option+Tab, Option+Shift+Tab        Alt+Tab window switcher
///   Control+Option+arrows (+Shift)      Windows key + arrows (snapping, move to the other display)
///   Control+Option+Tab                  Windows key + Tab (Task View)
///   Control+Option+Z                    Windows key + Z (Snap Layouts for the focused window)
///   Control+Option+D                    Windows key + D (show desktop)
///   Control+Option+V                    Windows key + V (clipboard history; while open: arrows, Tab, Return, Esc)
///   Option+Space                        Alt+Space (window menu of the focused window)
///   While a keyboard mode is open: Snap Layouts from Control+Option+Z takes digits, arrows, Return and Esc;
///   the window menu's Move and Size take arrows, Return and Esc.
///   Option tapped alone                 Alt (Phase 6: opens the front app's menus; not swallowed)
///   Shift tapped alone in Alt+Tab       one window back (as Shift+Tab)
/// Task view, Snap Layouts, show desktop, clipboard history and the window menu can be given other key
/// combinations in Settings > Keyboard (`ShortcutAction`); the ones above are their defaults.
/// Carbon hot keys can't do Option+Tab (macOS 15 and later refuse Option-only hot keys), so this is an
/// active `CGEventTap` on key events. It runs on its own thread: typing never waits for Fenestra's main
/// thread, and the callback only compares a key code and four modifier bits. Needs Accessibility.
final class HotKeys: @unchecked Sendable {
    static let shared = HotKeys()

    private struct State {
        var switcher = false            // Alt+Tab open: every key goes to it until Option is released
        var clipboard = false           // clipboard history open: arrows, Tab, Return and Esc go to it
        var modal: Modal = .none        // keyboard Snap Layouts or window Move/Size in progress
        var altSpace = true
        var taskViewKey = true
        var showDesktopKey = true
        var altTab = true
        var snapKeys = true
        var swallowedUps: Set<Int64> = []
        var optionTap = true
        var optionDownAt: UInt64 = 0     // event timestamp (ns) of a lone Option press, 0 = none
        var optionTainted = false        // another key, modifier or click came while Option was down
        var shiftTap = true
        var shiftDown = false            // Shift pressed alone while the switcher is open
        var recording = false            // Settings is recording a shortcut: every key reaches it
        var bindings: [ShortcutAction: KeyCombo] = [:]
        func combo(_ a: ShortcutAction) -> KeyCombo { bindings[a] ?? a.defaultCombo }
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    nonisolated(unsafe) private static var tap: CFMachPort?
    private var started = false

    enum Modal { case none, snapLayouts, mover }

    enum Action {
        case altTab(reverse: Bool)
        case switcherKey(Int64, shift: Bool)
        case optionReleased
        case arrow(WindowSnap.Arrow, shift: Bool)
        case taskView, snapLayouts, showDesktop
        case optionTap
        case clipboard, clipboardKey(Int64, shift: Bool)
        case windowMenu
        case modalKey(Modal, Int64)
    }

    /// Digit keys 1 to 9 (top row, then keypad), as layout positions: the same on U.S., ABC and Romanian.
    static let digitCodes: [Int64] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    static let keypadCodes: [Int64] = [83, 84, 85, 86, 87, 88, 89, 91, 92]
    static func digit(_ code: Int64) -> Int? {
        if let i = digitCodes.firstIndex(of: code) { return i + 1 }
        if let i = keypadCodes.firstIndex(of: code) { return i + 1 }
        return nil
    }

    @MainActor
    func start() {
        guard !started, AXIsProcessTrusted() else { return }
        started = true
        configure()
        let t = Thread {
            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
                | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
                // Clicks only mark a held Option as used (Option-click must not open the menus).
                | CGEventMask(1 << CGEventType.leftMouseDown.rawValue) | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
                | CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
            let cb: CGEventTapCallBack = { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let t = HotKeys.tap { CGEvent.tapEnable(tap: t, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                return HotKeys.shared.handle(type, event) ? nil : Unmanaged.passUnretained(event)
            }
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: mask, callback: cb, userInfo: nil) else {
                Log.write("hotkeys: event tap unavailable (Accessibility?)")
                return
            }
            HotKeys.tap = tap
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            Log.write("hotkeys: started (Option+Tab, Control+Option+arrows, "
                      + ShortcutAction.allCases.map { a in "\(a.rawValue)=\(HotKeys.shared.state.withLock { $0.combo(a) }.words)" }
                          .joined(separator: ", ") + ")")
            CFRunLoopRun()
        }
        t.name = "Fenestra hot keys"
        t.qualityOfService = .userInteractive
        t.start()
    }

    @MainActor
    func configure() {
        let s = AppSettings.shared
        let altTab = s.altTab, snap = s.snapWindows, optTap = s.optionTapMenus, altSpace = s.altSpaceMenu
        let tv = s.taskViewShortcut, sd = s.showDesktopShortcut, shiftTap = s.altTabShiftTap
        let bindings = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, s.combo($0)) })
        state.withLock {
            $0.altTab = altTab; $0.snapKeys = snap; $0.optionTap = optTap; $0.altSpace = altSpace
            $0.taskViewKey = tv; $0.showDesktopKey = sd; $0.shiftTap = shiftTap; $0.bindings = bindings
        }
    }

    /// While Settings records a shortcut, no shortcut acts, so the recorder sees the keys (even the current ones).
    func setRecording(_ on: Bool) {
        state.withLock { $0.recording = on }
    }

    func setSwitcherActive(_ on: Bool) {
        state.withLock { $0.switcher = on }
    }

    func setClipboardActive(_ on: Bool) {
        state.withLock { $0.clipboard = on }
    }

    func setModal(_ m: Modal) {
        state.withLock { $0.modal = m }
    }

    /// Runs on the tap thread. Returns true to swallow the event.
    private func handle(_ type: CGEventType, _ e: CGEvent) -> Bool {
        let flags = e.flags
        let opt = flags.contains(.maskAlternate), ctrl = flags.contains(.maskControl)
        let cmd = flags.contains(.maskCommand), shift = flags.contains(.maskShift)
        let s = state.withLock { $0 }
        let mods = flags.rawValue & KeyCombo.modMask
        if s.recording && !s.switcher && s.modal == .none && !s.clipboard {
            if type == .keyUp { _ = state.withLock { $0.swallowedUps.remove(e.getIntegerValueField(.keyboardEventKeycode)) } }
            return false
        }

        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            if s.optionDownAt != 0 { state.withLock { $0.optionTainted = true } }
            // A click ends keyboard Move/Size where the window is (Windows does the same).
            if s.modal == .mover { post(.modalKey(.mover, 36)) }
            return false
        }
        if type == .flagsChanged { trackOptionTap(e, s) }
        if type == .keyDown && s.optionDownAt != 0 { state.withLock { $0.optionTainted = true } }

        if type == .flagsChanged {
            if s.switcher && !opt {
                state.withLock { $0.switcher = false; $0.shiftDown = false }
                post(.optionReleased)
            } else if s.switcher {
                // Shift tapped alone while Option holds the switcher open: one window back.
                let code = e.getIntegerValueField(.keyboardEventKeycode)
                if code == 56 || code == 60 {
                    if shift && !ctrl && !cmd {
                        state.withLock { $0.shiftDown = true }
                    } else if !shift {
                        if s.shiftDown && s.shiftTap { post(.altTab(reverse: true)) }
                        state.withLock { $0.shiftDown = false }
                    }
                } else {
                    state.withLock { $0.shiftDown = false }
                }
            }
            return false
        }
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp {
            // The key-up of a swallowed key-down is swallowed too.
            return state.withLock { $0.swallowedUps.remove(code) != nil }
        }
        guard type == .keyDown else { return false }
        let repeated = e.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if s.shiftDown { state.withLock { $0.shiftDown = false } }      // Shift+key, not a Shift tap
        func bound(_ a: ShortcutAction) -> Bool { s.combo(a).matches(code: code, mods: mods) }

        var action: Action?
        let arrowsReturnEsc: Set<Int64> = [123, 124, 125, 126, 36, 76, 53]
        if s.modal == .mover {
            // Move/Size: arrows step the window, Return keeps it, Esc puts it back; other keys end it and pass.
            if !ctrl && !opt && !cmd && arrowsReturnEsc.contains(code) {
                action = .modalKey(.mover, code)
            } else {
                post(.modalKey(.mover, 36))
                return false
            }
        } else if s.modal == .snapLayouts && !bound(.snapLayouts) {
            // Snap Layouts from the keyboard: digits pick a layout, then a zone; arrows and Return do the same.
            if !ctrl && !opt && !cmd && (arrowsReturnEsc.contains(code) || Self.digit(code) != nil) {
                action = .modalKey(.snapLayouts, code)
            } else {
                post(.modalKey(.snapLayouts, -1))
                return false
            }
        } else if s.clipboard && !bound(.clipboard) {
            // Clipboard history open: it takes arrows, Tab, Return and Esc; any other key closes it and reaches
            // the app (Space too, so typing carries on).
            if !ctrl && !opt && !cmd && [125, 126, 36, 76, 53, 48].contains(code) {
                action = .clipboardKey(code, shift: shift)
            } else {
                post(.clipboardKey(-1, shift: false))
                return false
            }
        } else if s.switcher {
            action = code == 48 ? .altTab(reverse: shift) : .switcherKey(code, shift: shift)
        } else if code == 48 && opt && !ctrl && !cmd && s.altTab {
            action = .altTab(reverse: shift)
            state.withLock { $0.switcher = true }      // the next keys belong to the switcher already
        } else if ctrl && opt && !cmd && (123...126).contains(code) && s.snapKeys {
            switch code {
            case 123: action = .arrow(.left, shift: shift)
            case 124: action = .arrow(.right, shift: shift)
            case 125: action = .arrow(.down, shift: shift)
            default: action = .arrow(.up, shift: shift)
            }
        } else if bound(.taskView) && s.taskViewKey {
            action = .taskView
        } else if bound(.snapLayouts) && s.snapKeys {
            action = .snapLayouts
        } else if bound(.showDesktop) && s.showDesktopKey {
            action = .showDesktop
        } else if bound(.clipboard) {
            action = .clipboard
        } else if bound(.windowMenu) && s.altSpace {
            action = .windowMenu
        }
        guard let action else { return false }
        state.withLock { _ = $0.swallowedUps.insert(code) }
        // Holding Tab in the switcher keeps moving (as on Windows); other shortcuts act once per press.
        if repeated, case .arrow = action { return true }
        if repeated, case .taskView = action { return true }
        if repeated, case .clipboard = action { return true }
        if repeated, case .windowMenu = action { return true }
        post(action)
        return true
    }

    /// Option pressed and released alone within 0.6 s, with nothing else in between = Alt tap.
    private func trackOptionTap(_ e: CGEvent, _ s: State) {
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        let mods = e.flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn])
        guard code == 58 || code == 61 else {                       // left / right Option
            if s.optionDownAt != 0 { state.withLock { $0.optionTainted = true } }
            return
        }
        if mods == .maskAlternate {
            state.withLock { $0.optionDownAt = e.timestamp; $0.optionTainted = false }
        } else if !mods.contains(.maskAlternate) {
            let fire = s.optionTap && s.optionDownAt != 0 && !s.optionTainted && !s.switcher
                && e.timestamp &- s.optionDownAt < 600_000_000
            state.withLock { $0.optionDownAt = 0 }
            if fire { MenuTrace.tapAt = CACurrentMediaTime(); post(.optionTap) }
        } else {
            state.withLock { $0.optionTainted = true }              // Option plus another modifier
        }
    }

    private func post(_ a: Action) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { HotKeys.run(a) }
        }
    }

    @MainActor
    private static func run(_ a: Action) {
        switch a {
        case .altTab(let reverse): AltTab.shared.tab(reverse: reverse)
        case .switcherKey(let code, let shift): AltTab.shared.key(code, shift: shift)
        case .optionReleased: AltTab.shared.commit()
        case .arrow(let dir, let shift): WindowSnap.shared.keyboard(dir, shift: shift)
        case .taskView: TaskView.shared.toggle()
        case .snapLayouts: WindowSnap.shared.showLayoutsForFocusedWindow()
        case .showDesktop: TaskbarActions.toggleShowDesktop()
        case .optionTap: AppMenus.shared.openForFrontmost()
        case .clipboard: ClipboardFlyout.toggle()
        case .clipboardKey(let code, let shift): ClipboardFlyout.key(code, shift: shift)
        case .windowMenu: CaptionController.shared.windowMenuForFocusedWindow()
        case .modalKey(.snapLayouts, let code): SnapController.shared.keyboardKey(code)
        case .modalKey(.mover, let code): WindowMover.shared.key(code)
        case .modalKey(.none, _): break
        }
    }
}
