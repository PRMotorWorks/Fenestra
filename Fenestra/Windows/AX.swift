import AppKit
import ApplicationServices

/// Private but long-stable HIServices symbol: maps an AX window element to its CGWindowID.
/// Used by yabai, AltTab and others. If an OS update removes it, thumbnails fall back to titles.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Thin helpers over the public Accessibility API (ApplicationServices / HIServices).
@MainActor
enum AX {
    static func configureTimeouts() {
        // A hung app must never freeze the taskbar for more than a quarter second.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    }

    static func app(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    @discardableResult
    static func set(_ el: AXUIElement, _ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(el, name as CFString, value) == .success
    }

    static func isSettable(_ el: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, name as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    static func perform(_ el: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(el, action as CFString) == .success
    }

    /// Real document/app windows of a process (skips sheets, palettes, popovers).
    static func windows(_ pid: pid_t) -> [AXUIElement] {
        guard let all: [AXUIElement] = attr(app(pid), kAXWindowsAttribute) else { return [] }
        return all.filter { w in
            let sub: String? = attr(w, kAXSubroleAttribute)
            return sub == kAXStandardWindowSubrole || sub == kAXDialogSubrole
        }
    }

    static func windowID(_ w: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(w, &id) == .success && id != 0 ? id : nil
    }

    static func title(_ w: AXUIElement) -> String { attr(w, kAXTitleAttribute) ?? "" }
    static func isMinimized(_ w: AXUIElement) -> Bool { attr(w, kAXMinimizedAttribute) ?? false }

    static func setMinimized(_ w: AXUIElement, _ v: Bool) {
        set(w, kAXMinimizedAttribute, v as CFBoolean)
    }

    static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        guard let v: CFTypeRef = attr(app(pid), kAXFocusedWindowAttribute),
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// Frame in AX coordinates (origin at top-left of the primary display, y grows downward).
    static func frame(_ w: AXUIElement) -> CGRect? {
        guard let pv: AXValue = attrValue(w, kAXPositionAttribute),
              let sv: AXValue = attrValue(w, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv, .cgPoint, &p)
        AXValueGetValue(sv, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    static func setSize(_ w: AXUIElement, _ size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) { set(w, kAXSizeAttribute, v) }
    }

    static func setPosition(_ w: AXUIElement, _ point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) { set(w, kAXPositionAttribute, v) }
    }

    private static func attrValue(_ el: AXUIElement, _ name: String) -> AXValue? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }

    /// Brings an app forward and raises one of its windows (works from a background app,
    /// unlike NSRunningApplication.activate under macOS 14+ cooperative activation).
    static func focus(pid: pid_t, window: AXUIElement?) {
        let appEl = app(pid)
        if let w = window {
            if isMinimized(w) { setMinimized(w, false) }
            perform(w, kAXRaiseAction)
            set(w, kAXMainAttribute, kCFBooleanTrue)
        }
        set(appEl, kAXFrontmostAttribute, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate()
        CaptionController.shared.afterRaise(pid)       // the raise lands above the caption panel
    }

    static func close(_ w: AXUIElement) {
        if let b: AXUIElement = elementAttr(w, kAXCloseButtonAttribute) { perform(b, kAXPressAction) }
    }

    static func elementAttr(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v: CFTypeRef = attr(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// Finds the app's "New …" menu item (Command-N with no other modifiers) and presses it.
    static func pressNewWindowMenuItem(pid: pid_t) -> Bool {
        guard let bar = elementAttr(app(pid), kAXMenuBarAttribute),
              let menus: [AXUIElement] = attr(bar, kAXChildrenAttribute) else { return false }
        for barItem in menus.prefix(4).dropFirst() {          // skip the Apple menu, look in app/File/Edit
            guard let submenus: [AXUIElement] = attr(barItem, kAXChildrenAttribute),
                  let menu = submenus.first,
                  let items: [AXUIElement] = attr(menu, kAXChildrenAttribute) else { continue }
            for item in items {
                let ch: String? = attr(item, kAXMenuItemCmdCharAttribute)
                let mods: Int = attr(item, kAXMenuItemCmdModifiersAttribute) ?? -1
                let enabled: Bool = attr(item, kAXEnabledAttribute) ?? false
                if ch?.uppercased() == "N", mods == 0, enabled {
                    return perform(item, kAXPressAction)
                }
            }
        }
        return false
    }
}
