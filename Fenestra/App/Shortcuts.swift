import AppKit

/// A key plus modifiers, as HotKeys matches it. `code` is the virtual key code (a key position, the same on every
/// layout), `mods` the Control/Option/Command/Shift bits of `CGEventFlags`, `label` the key's name as it was typed.
struct KeyCombo: Equatable, Sendable {
    var code: Int64
    var mods: UInt64
    var label: String

    static let ctrl = CGEventFlags.maskControl.rawValue
    static let opt = CGEventFlags.maskAlternate.rawValue
    static let cmd = CGEventFlags.maskCommand.rawValue
    static let shift = CGEventFlags.maskShift.rawValue
    static let modMask = ctrl | opt | cmd | shift

    static func == (a: KeyCombo, b: KeyCombo) -> Bool { a.code == b.code && a.mods == b.mods }

    func matches(code c: Int64, mods m: UInt64) -> Bool { code == c && mods == (m & Self.modMask) }

    /// Mac style, modifiers in Apple's order: ⌃⌥⇧⌘D.
    var symbols: String {
        var s = ""
        if mods & Self.ctrl != 0 { s += "⌃" }
        if mods & Self.opt != 0 { s += "⌥" }
        if mods & Self.shift != 0 { s += "⇧" }
        if mods & Self.cmd != 0 { s += "⌘" }
        return s + label
    }

    /// Spelled out, as the rest of Fenestra's text writes shortcuts: Control+Option+D.
    var words: String {
        var p: [String] = []
        if mods & Self.ctrl != 0 { p.append("Control") }
        if mods & Self.opt != 0 { p.append("Option") }
        if mods & Self.shift != 0 { p.append("Shift") }
        if mods & Self.cmd != 0 { p.append("Command") }
        return (p + [label]).joined(separator: "+")
    }

    var stored: String { "\(code):\(mods):\(label)" }
    init(code: Int64, mods: UInt64, label: String) { self.code = code; self.mods = mods; self.label = label }
    init?(stored: String) {
        let p = stored.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard p.count == 3, let c = Int64(p[0]), let m = UInt64(p[1]) else { return nil }
        self.init(code: c, mods: m & Self.modMask, label: String(p[2]))
    }

    /// From a key press in the shortcut recorder. Nil without Control, Option or Command (a bare key or
    /// Shift+key would take that key from every app).
    @MainActor init?(event e: NSEvent) {
        var m: UInt64 = 0
        let f = e.modifierFlags
        if f.contains(.control) { m |= Self.ctrl }
        if f.contains(.option) { m |= Self.opt }
        if f.contains(.command) { m |= Self.cmd }
        if f.contains(.shift) { m |= Self.shift }
        guard m & (Self.ctrl | Self.opt | Self.cmd) != 0 else { return nil }
        let code = Int64(e.keyCode)
        let label = Self.names[code]
            ?? e.characters(byApplyingModifiers: [])?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Key \(code)"
        self.init(code: code, mods: m, label: label.isEmpty ? "Key \(code)" : label)
    }

    /// Keys without a printable character.
    static let names: [Int64: String] = [
        48: "Tab", 49: "Space", 36: "Return", 76: "Enter", 51: "Delete", 117: "Forward Delete", 53: "Esc",
        123: "Left", 124: "Right", 125: "Down", 126: "Up", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
    ]
}

/// The shortcuts that can be given another key combination (Settings > Keyboard).
/// Option+Tab (Alt+Tab) and Control+Option+arrows stay fixed: they are held or come as a family.
enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case taskView, snapLayouts, showDesktop, clipboard, windowMenu
    var id: String { rawValue }

    var title: String {
        switch self {
        case .taskView: "Open Task view"
        case .snapLayouts: "Snap layouts for the window in front"
        case .showDesktop: "Show the desktop on every display"
        case .clipboard: "Open clipboard history"
        case .windowMenu: "Open the window menu"
        }
    }
    var windowsName: String {
        switch self {
        case .taskView: "Windows key + Tab"
        case .snapLayouts: "Windows key + Z"
        case .showDesktop: "Windows key + D"
        case .clipboard: "Windows key + V"
        case .windowMenu: "Alt+Space"
        }
    }
    var defaultCombo: KeyCombo {
        let co = KeyCombo.ctrl | KeyCombo.opt
        switch self {
        case .taskView: return KeyCombo(code: 48, mods: co, label: "Tab")
        case .snapLayouts: return KeyCombo(code: 6, mods: co, label: "Z")
        case .showDesktop: return KeyCombo(code: 2, mods: co, label: "D")
        case .clipboard: return KeyCombo(code: 9, mods: co, label: "V")
        case .windowMenu: return KeyCombo(code: 49, mods: KeyCombo.opt, label: "Space")
        }
    }

    /// Why `c` can't be used for this action: taken by a fixed shortcut or by another action. Nil = free.
    @MainActor func conflict(_ c: KeyCombo) -> String? {
        let co = KeyCombo.ctrl | KeyCombo.opt
        if c.code == 48 && (c.mods == KeyCombo.opt || c.mods == KeyCombo.opt | KeyCombo.shift) {
            return "Option+Tab is the window switcher (Alt+Tab)."
        }
        if (123...126).contains(c.code) && (c.mods == co || c.mods == co | KeyCombo.shift) {
            return "Control+Option+arrows snap windows."
        }
        for other in Self.allCases where other != self && AppSettings.shared.combo(other) == c {
            return "Already used for \"\(other.title)\"."
        }
        return nil
    }
}
