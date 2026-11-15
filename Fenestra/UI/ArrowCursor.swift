import AppKit

@_silgen_name("_CGSDefaultConnection")
private func _CGSDefaultConnection() -> Int32
@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

/// Fenestra is never the active app, so AppKit's cursor rects don't apply to its panels and macOS doesn't reset
/// the pointer when it moves from another app's window onto one of them. Coming off a window's bottom resize edge
/// onto the taskbar, the resize arrow stayed. This sets the normal arrow when the pointer enters a panel.
/// `SetsCursorInBackground` (private connection property, used by other window tools) lets a background app's
/// cursor change take effect; Fenestra only sets the cursor while the pointer is over its own panels.
@MainActor
final class ArrowCursor: NSResponder {
    private static let shared = ArrowCursor()             // tracking areas don't retain their owner
    private static let moving = ArrowCursor()
    private static var enabled = false

    /// `followMoves`: also on every pointer move (the taskbar has no text fields, so nothing wants another
    /// cursor there; it also covers a drag released over it). Without it, only on entering (Start, flyouts:
    /// their text fields keep their I-beam).
    static func install(on view: NSView, followMoves: Bool = false) {
        if !enabled {
            enabled = true
            _ = CGSSetConnectionProperty(_CGSDefaultConnection(), _CGSDefaultConnection(),
                                         "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        }
        var opts: NSTrackingArea.Options = [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect]
        if followMoves { opts.insert(.mouseMoved) }
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: opts, owner: followMoves ? moving : shared, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set() }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseExited(with event: NSEvent) {}
}
