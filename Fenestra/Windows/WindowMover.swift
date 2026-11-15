import AppKit
import ApplicationServices

/// The window menu's Move and Size (Windows: Alt+Space, then M or S). Arrow keys step the window by 10 points,
/// Return or a click keeps the result, Esc puts the window back where it was. Size: the first arrow picks the edge
/// (Left = left edge, Up = top edge, and so on; a second direction adds the other edge for a corner), the next
/// arrows move it. Keys reach this through the HotKeys tap, so the app keeps its focus.
@MainActor
final class WindowMover {
    static let shared = WindowMover()
    enum Mode { case move, size }

    private var mode: Mode?
    private var pid: pid_t = 0
    private var element: AXUIElement?
    private var original: CGRect = .zero
    private var frame: CGRect = .zero          // AX coordinates (top-left origin, y down)
    private var edgeX = 0                      // Size: -1 left edge, 1 right edge, 0 none yet
    private var edgeY = 0                      // Size: -1 top edge, 1 bottom edge
    private var idleTimer: Timer?
    private var hint: NSPanel?
    private let step: CGFloat = 10
    private let minSize = CGSize(width: 120, height: 80)

    var isActive: Bool { mode != nil }

    func begin(_ m: Mode, pid: pid_t, element: AXUIElement) {
        if mode != nil { finish(cancel: false) }
        guard let f = AX.frame(element) else { return }
        mode = m
        self.pid = pid
        self.element = element
        original = f
        frame = f
        edgeX = 0
        edgeY = 0
        AX.focus(pid: pid, window: element)
        HotKeys.shared.setModal(.mover)
        showHint()
        armIdle()
        Log.write("window menu: \(m == .move ? "move" : "size") started at \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))")
    }

    /// From the HotKeys tap: arrows step, Return keeps, Esc cancels.
    func key(_ code: Int64) {
        guard mode != nil else { return }
        switch code {
        case 123: arrow(dx: -1, dy: 0)
        case 124: arrow(dx: 1, dy: 0)
        case 125: arrow(dx: 0, dy: 1)
        case 126: arrow(dx: 0, dy: -1)
        case 53: finish(cancel: true)
        default: finish(cancel: false)
        }
    }

    private func arrow(dx: Int, dy: Int) {
        guard let el = element, let mode else { return }
        armIdle()
        if mode == .move {
            frame.origin.x += CGFloat(dx) * step
            frame.origin.y += CGFloat(dy) * step
            AX.setPosition(el, frame.origin)
        } else {
            // The first press in each direction only picks the edge, as on Windows.
            if dx != 0 && edgeX == 0 { edgeX = dx; updateHint(); return }
            if dy != 0 && edgeY == 0 { edgeY = dy; updateHint(); return }
            if dx != 0 {
                let d = CGFloat(dx) * step
                if edgeX < 0 {
                    let w = max(frame.width - d, minSize.width)
                    frame.origin.x += frame.width - w
                    frame.size.width = w
                } else {
                    frame.size.width = max(frame.width + d, minSize.width)
                }
            }
            if dy != 0 {
                let d = CGFloat(dy) * step
                if edgeY < 0 {
                    let h = max(frame.height - d, minSize.height)
                    frame.origin.y += frame.height - h
                    frame.size.height = h
                } else {
                    frame.size.height = max(frame.height + d, minSize.height)
                }
            }
            AX.setPosition(el, frame.origin)
            AX.setSize(el, frame.size)
            // Apps may refuse a size (minimum sizes, Terminal's character cells): continue from what they took.
            if let real = AX.frame(el) { frame = real }
        }
    }

    private func finish(cancel: Bool) {
        guard let m = mode else { return }
        mode = nil
        idleTimer?.invalidate()
        HotKeys.shared.setModal(.none)
        hint?.orderOut(nil)
        if cancel, let el = element {
            AX.setPosition(el, original.origin)
            if m == .size { AX.setSize(el, original.size) }
        }
        let f = element.flatMap(AX.frame) ?? frame
        Log.write("window menu: \(m == .move ? "move" : "size") \(cancel ? "cancelled" : "done") at "
                  + "\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))")
        element = nil
    }

    /// Nothing pressed for 30 s: keep the window where it is and give the keys back.
    private func armIdle() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in
            MainActor.assumeIsolated { WindowMover.shared.finish(cancel: false) }
        }
    }

    // MARK: Hint (Windows shows a four-way pointer; macOS won't let a background app set it, so a label)

    private var hintText: String {
        switch mode {
        case .move: return "Move: arrow keys, Return to finish, Esc to cancel"
        case .size:
            if edgeX == 0 && edgeY == 0 { return "Size: press an arrow key to pick an edge" }
            return "Size: arrow keys, Return to finish, Esc to cancel"
        case nil: return ""
        }
    }

    private func showHint() {
        let p = hint ?? makeHint()
        hint = p
        updateHint()
        p.orderFrontRegardless()
    }

    private func updateHint() {
        guard let p = hint, let label = p.contentView?.subviews.first as? NSTextField else { return }
        label.stringValue = hintText
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 24, height: 30)
        label.frame.origin = NSPoint(x: 12, y: (size.height - label.frame.height) / 2)
        // Centered near the top of the window's display, clear of the window being moved.
        let screen = Displays.screen(forAX: original) ?? NSScreen.main
        let f = screen?.frame ?? .zero
        let top = f.maxY - (screen.map(CaptionController.menuBarInset) ?? 0)
        p.setFrame(NSRect(x: f.midX - size.width / 2, y: top - size.height - 16, width: size.width,
                          height: size.height), display: true)
    }

    private func makeHint() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 30),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        p.contentView = bg
        bg.roundCorners(8)
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        bg.addSubview(label)
        return p
    }
}
