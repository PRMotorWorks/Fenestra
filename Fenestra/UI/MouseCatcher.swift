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
            let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self, userInfo: nil)
            addTrackingArea(t)
            tracking = t
        }

        override func mouseEntered(with event: NSEvent) { handlers?.onHover?(true, screenRect) }
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
                    onDrag: onDrag, onDragEnd: onDragEnd
                )
            )
    }
}
