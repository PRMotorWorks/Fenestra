import AppKit
import SwiftUI

/// Transparent AppKit layer that gives SwiftUI taskbar buttons Windows-style mouse handling:
/// left click, right click, middle click, hover and pressed state, plus the button's screen rect.
struct MouseCatcher: NSViewRepresentable {
    var onLeft: ((NSRect) -> Void)? = nil
    var onRight: ((NSRect, NSView) -> Void)? = nil
    var onMiddle: ((NSRect) -> Void)? = nil
    var onHover: ((Bool, NSRect) -> Void)? = nil
    var onPress: ((Bool) -> Void)? = nil
    var onDrag: ((CGFloat) -> Void)? = nil          // horizontal drag offset while dragging
    var onDragEnd: ((CGFloat) -> Void)? = nil
    /// Pointer moves inside: point from the top-left of the view, and the view's screen rect.
    /// Only views that set it get mouse-moved events (the taskbar stays cheap otherwise).
    var onMove: ((CGPoint, NSRect) -> Void)? = nil
    /// Scroll wheel or two-finger trackpad scroll over the view (point as for onMove). Without it, scrolls pass on.
    var onScroll: ((NSEvent, CGPoint, NSRect) -> Void)? = nil

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.handlers = self
        return v
    }
    func updateNSView(_ v: CatcherView, context: Context) { v.handlers = self }

    final class CatcherView: NSView {
        var handlers: MouseCatcher?
        private var tracking: NSTrackingArea?
        private var pressedInside = false

        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        var screenRect: NSRect {
            guard let w = window else { return .zero }
            return w.convertToScreen(convert(bounds, to: nil))
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let t = tracking { removeTrackingArea(t) }
            var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
            if handlers?.onMove != nil { options.insert(.mouseMoved) }
            let t = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
            addTrackingArea(t)
            tracking = t
        }

        /// Event location from the view's top-left corner (SwiftUI's orientation).
        private func topLeftPoint(_ event: NSEvent) -> CGPoint {
            let p = convert(event.locationInWindow, from: nil)
            return CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
        }

        /// A hidden taskbar (full screen, auto-hide) stays ordered in, transparent and click-through, and its
        /// tracking areas still fire: no hover, tooltips or thumbnails from a bar nobody can see.
        private var isLive: Bool {
            guard let w = window else { return false }
            return !w.ignoresMouseEvents && w.alphaValue > 0
        }

        override func mouseEntered(with event: NSEvent) {
            guard isLive else { return }
            handlers?.onHover?(true, screenRect)
            handlers?.onMove?(topLeftPoint(event), screenRect)
        }
        override func mouseMoved(with event: NSEvent) {
            guard let move = handlers?.onMove else { return super.mouseMoved(with: event) }
            guard isLive else { return }
            move(topLeftPoint(event), screenRect)
        }
        override func scrollWheel(with event: NSEvent) {
            guard let scroll = handlers?.onScroll else { return super.scrollWheel(with: event) }
            guard isLive else { return }
            scroll(event, topLeftPoint(event), screenRect)
        }
        override func mouseExited(with event: NSEvent) {
            handlers?.onHover?(false, screenRect)
            if pressedInside { pressedInside = false; handlers?.onPress?(false) }
        }
        private var downX: CGFloat = 0
        private var dragging = false

        override func mouseDown(with event: NSEvent) {
            pressedInside = true
            dragging = false
            downX = NSEvent.mouseLocation.x
            handlers?.onPress?(true)
        }
        override func mouseDragged(with event: NSEvent) {
            guard handlers?.onDrag != nil else { return }
            let dx = NSEvent.mouseLocation.x - downX
            if !dragging && abs(dx) > 6 { dragging = true; handlers?.onPress?(false) }
            if dragging { handlers?.onDrag?(dx) }
        }
        override func mouseUp(with event: NSEvent) {
            if dragging {
                dragging = false
                pressedInside = false
                handlers?.onDragEnd?(NSEvent.mouseLocation.x - downX)
                return
            }
            guard pressedInside else { return }
            pressedInside = false
            handlers?.onPress?(false)
            if bounds.contains(convert(event.locationInWindow, from: nil)) { handlers?.onLeft?(screenRect) }
        }
        override func rightMouseDown(with event: NSEvent) { handlers?.onRight?(screenRect, self) }
        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 { handlers?.onMiddle?(screenRect) }
        }
    }
}

/// Hover/pressed background used by every taskbar button (Windows 11: 4 px radius).
struct TaskbarButtonChrome<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var width: CGFloat? = 40
    var height: CGFloat = 40
    var highlighted = false
    var onLeft: ((NSRect) -> Void)? = nil
    var onRight: ((NSRect, NSView) -> Void)? = nil
    var onMiddle: ((NSRect) -> Void)? = nil
    var onHoverChange: ((Bool, NSRect) -> Void)? = nil
    var onDrag: ((CGFloat) -> Void)? = nil
    var onDragEnd: ((CGFloat) -> Void)? = nil
    var onMove: ((CGPoint, NSRect) -> Void)? = nil
    var onScroll: ((NSEvent, CGPoint, NSRect) -> Void)? = nil
    @ViewBuilder var content: () -> Content

    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        content()
            .scaleEffect(pressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(pressed ? Theme.pressed(scheme) : (hovering || highlighted ? Theme.hover(scheme) : .clear))
            )
            .overlay(
                MouseCatcher(
                    onLeft: onLeft, onRight: onRight, onMiddle: onMiddle,
                    onHover: { inside, rect in hovering = inside; onHoverChange?(inside, rect) },
                    onPress: { pressed = $0 },
                    onDrag: onDrag, onDragEnd: onDragEnd, onMove: onMove, onScroll: onScroll
                )
            )
    }
}
