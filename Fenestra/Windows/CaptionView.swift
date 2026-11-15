import AppKit

/// Borderless panel holding one window's caption buttons. Never key, never activates Fenestra,
/// so clicking a button leaves the target app's focus alone (as on Windows).
final class CaptionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(view: CaptionView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 138, height: 32),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .normal                       // interleaves with app windows; ordered just above its target
        collectionBehavior = [.transient, .ignoresCycle]   // hidden by Mission Control, skipped by Cmd-`
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        allowsToolTipsWhenApplicationIsInactive = true
        contentView = view
    }
}

/// Windows 11 caption buttons (minimize, maximize/restore, close), plus the Phase 6 menu button (the app's
/// menus, for when the menu bar is hidden) to their right, drawn with Core Animation layers:
/// glyphs are vector paths (10 x 10 pt like Segoe Fluent Icons), hover/press fades are implicit layer
/// animations, so nothing is redrawn and nothing runs while idle. No Microsoft assets.
final class CaptionView: NSView {
    enum Part: Int, CaseIterable { case minimize, maximize, close, menu }

    var onClick: ((Part) -> Void)?
    /// Phase 6: the menu button opens on mouse down (like a menu) with its screen rect; blocks while the menu is open.
    var onMenu: ((NSRect) -> Void)?
    /// Phase 6: right-click anywhere on the buttons (Windows: the window menu), with the screen point.
    var onRightClick: ((NSPoint) -> Void)?
    /// Phase 6: whether the menu button is shown (the panel is then four buttons wide).
    var showsMenu = false { didSet { if oldValue != showsMenu { needsLayout = true } } }
    private var visibleParts: [Part] { showsMenu ? Part.allCases : [.minimize, .maximize, .close] }
    /// Hover enter/exit on the maximize button with its screen rect (drives Snap Layouts).
    var onMaximizeHover: ((Bool, NSRect) -> Void)?

    private(set) var buttonWidth: CGFloat = 46
    private var radius: CGFloat = 16
    private var showMaximizeTip = true

    var active = true { didSet { if oldValue != active { refresh() } } }
    var maximized = false { didSet { if oldValue != maximized { rebuildGlyphs(); updateToolTips() } } }
    var enabledParts: [Bool] = [true, true, true, true] { didSet { if oldValue != enabledParts { refresh() } } }

    private let root = CALayer()
    private let cornerMask = CAShapeLayer()
    private let background = CALayer()
    private var fills: [CALayer] = []
    private var glyphs: [CAShapeLayer] = []
    private var hovered: Part?
    private var pressed: Part?
    private var pressedInside = false
    private var areas: [NSTrackingArea] = []
    private var sampled: CGImage?
    private let tipOwners: [NSString] = ["Minimize", "Maximize", "Restore Down", "Close", "Menu"]

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Layer-hosting view: the layer tree is ours, AppKit doesn't touch it.
        // Only the window's top-left corner is round: an explicit mask path (see updateMask) rather than
        // cornerRadius/maskedCorners, whose corner names depend on the (flipped) layer geometry AppKit uses.
        root.mask = cornerMask
        cornerMask.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        root.actions = ["bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull()]
        layer = root
        wantsLayer = true
        background.contentsGravity = .resize
        background.actions = ["contents": NSNull(), "backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        root.addSublayer(background)
        for _ in Part.allCases {
            let f = CALayer()
            f.actions = ["bounds": NSNull(), "position": NSNull()]       // backgroundColor fades implicitly
            let g = CAShapeLayer()
            g.fillColor = nil
            g.lineWidth = 1
            g.lineCap = .butt
            g.lineJoin = .miter
            g.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
            root.addSublayer(f)
            root.addSublayer(g)
            fills.append(f)
            glyphs.append(g)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    func configure(buttonWidth: CGFloat, radius: CGFloat, maximizeTip: Bool) {
        guard buttonWidth != self.buttonWidth || radius != self.radius || maximizeTip != showMaximizeTip else { return }
        self.buttonWidth = buttonWidth
        self.radius = radius
        showMaximizeTip = maximizeTip
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = bounds
        background.frame = bounds
        cornerMask.frame = root.bounds
        for p in Part.allCases {
            let r = rect(of: p)
            fills[p.rawValue].frame = r
            glyphs[p.rawValue].frame = r
            fills[p.rawValue].isHidden = !visibleParts.contains(p)
            glyphs[p.rawValue].isHidden = !visibleParts.contains(p)
        }
        CATransaction.commit()
        rebuildGlyphs()
        updateMask()
        refresh(animated: false)
        updateTrackingAreas()
        updateToolTips()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        ([root, background] + fills + glyphs).forEach { $0.contentsScale = s }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh(animated: false)
    }

    /// True when y grows downward inside our layers (AppKit's window layer tree is flipped), so "top" is minY.
    private var layersFlipped: Bool { background.contentsAreFlipped() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true                      // the flip is only known once the layer is in the window's tree
    }

    /// Rounds the top-left corner with the window's radius, square everywhere else.
    private func updateMask() {
        let w = bounds.width, h = bounds.height
        let r = min(radius, w, h)
        let p = CGMutablePath()
        // Built in y-up terms, then mirrored if the layer geometry is flipped.
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: 0, y: h - r))
        p.addArc(tangent1End: CGPoint(x: 0, y: h), tangent2End: CGPoint(x: r, y: h), radius: r)
        p.addLine(to: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: w, y: 0))
        p.closeSubpath()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if layersFlipped {
            var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
            cornerMask.path = p.copy(using: &t)
        } else {
            cornerMask.path = p
        }
        CATransaction.commit()
    }

    func rect(of p: Part) -> CGRect {
        CGRect(x: CGFloat(p.rawValue) * buttonWidth, y: 0, width: buttonWidth, height: bounds.height)
    }

    func screenRect(of p: Part) -> NSRect {
        guard let w = window else { return .zero }
        return w.convertToScreen(convert(rect(of: p), to: nil))
    }

    /// Glyph paths in a 10 x 10 pt box centered in the button, strokes on half points so a 1 pt line
    /// lands on whole pixels at both 1x (your monitors) and 2x.
    private func rebuildGlyphs() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for p in Part.allCases {
            let size = rect(of: p).size
            let cx = floor(size.width / 2), cy = floor(size.height / 2)
            let path = CGMutablePath()
            switch p {
            case .minimize:
                path.move(to: CGPoint(x: cx - 5, y: cy + 0.5))
                path.addLine(to: CGPoint(x: cx + 5, y: cy + 0.5))
            case .maximize where !maximized:
                path.addRoundedRect(in: CGRect(x: cx - 4.5, y: cy - 4.5, width: 9, height: 9), cornerWidth: 1, cornerHeight: 1)
            case .maximize:
                // "Restore Down": front square bottom-left, the back square's corner peeking out top-right.
                path.addRoundedRect(in: CGRect(x: cx - 4.5, y: cy - 4.5, width: 7, height: 7), cornerWidth: 1, cornerHeight: 1)
                path.move(to: CGPoint(x: cx - 2.5, y: cy + 2.5))
                path.addLine(to: CGPoint(x: cx - 2.5, y: cy + 4.5))
                path.addLine(to: CGPoint(x: cx + 4.5, y: cy + 4.5))
                path.addLine(to: CGPoint(x: cx + 4.5, y: cy - 2.5))
                path.addLine(to: CGPoint(x: cx + 2.5, y: cy - 2.5))
            case .close:
                path.move(to: CGPoint(x: cx - 4.5, y: cy - 4.5))
                path.addLine(to: CGPoint(x: cx + 5.5, y: cy + 5.5))
                path.move(to: CGPoint(x: cx + 5.5, y: cy - 4.5))
                path.addLine(to: CGPoint(x: cx - 4.5, y: cy + 5.5))
            case .menu:
                // Three 10 pt lines (Fluent "GlobalNavigationButton").
                for dy: CGFloat in [-3.5, 0.5, 4.5] {
                    path.move(to: CGPoint(x: cx - 5, y: cy + dy))
                    path.addLine(to: CGPoint(x: cx + 5, y: cy + dy))
                }
            }
            if layersFlipped {
                // Paths are written y-up; mirror them (keeping half-point alignment) in flipped geometry.
                var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
                glyphs[p.rawValue].path = path.copy(using: &t)
            } else {
                glyphs[p.rawValue].path = path
            }
        }
        CATransaction.commit()
    }

    // MARK: Colors (WinUI caption button resources)

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    /// Title bar color sampled from the window (Screen Recording), or the system window color.
    func setBackground(_ image: CGImage?) {
        sampled = image
        refreshBackground()
    }

    private func refreshBackground() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let img = sampled {
            background.contents = img
            background.backgroundColor = nil
        } else {
            background.contents = nil
            var c = CGColor(gray: 0.93, alpha: 1)
            effectiveAppearance.performAsCurrentDrawingAppearance { c = NSColor.windowBackgroundColor.cgColor }
            background.backgroundColor = c
        }
        CATransaction.commit()
    }

    func refresh(animated: Bool = true) {
        let dark = isDark
        let red = CGColor(srgbRed: 196 / 255, green: 43 / 255, blue: 28 / 255, alpha: 1)       // #C42B1C
        let primary = dark ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 0.894)
        let disabled = dark ? CGColor(gray: 1, alpha: 0.363) : CGColor(gray: 0, alpha: 0.361)
        let hoverFill = dark ? CGColor(gray: 1, alpha: 0.0605) : CGColor(gray: 0, alpha: 0.0373)
        let pressFill = dark ? CGColor(gray: 1, alpha: 0.0419) : CGColor(gray: 0, alpha: 0.0241)
        CATransaction.begin()
        if animated { CATransaction.setAnimationDuration(0.08) } else { CATransaction.setDisableActions(true) }
        for p in Part.allCases {
            let enabled = enabledParts[p.rawValue]
            let isPressed = enabled && pressed == p && pressedInside
            let isHover = enabled && hovered == p && (pressed == nil || pressed == p)
            let fill: CGColor?
            let glyph: CGColor
            if p == .close && (isPressed || isHover) {
                fill = isPressed ? red.copy(alpha: 0.9) : red
                glyph = CGColor(gray: 1, alpha: isPressed ? 0.7 : 1)
            } else {
                fill = isPressed ? pressFill : (isHover ? hoverFill : nil)
                if !enabled { glyph = disabled }
                else if isHover || isPressed || active { glyph = isPressed ? primary.copy(alpha: dark ? 0.79 : 0.62)! : primary }
                else { glyph = disabled }                        // inactive window: dimmed glyphs
            }
            fills[p.rawValue].backgroundColor = fill
            glyphs[p.rawValue].strokeColor = glyph
        }
        CATransaction.commit()
        if sampled == nil { refreshBackground() }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        areas.forEach(removeTrackingArea)
        areas = visibleParts.map { p in
            NSTrackingArea(rect: rect(of: p), options: [.mouseEnteredAndExited, .activeAlways],
                           owner: self, userInfo: ["part": p.rawValue])
        }
        areas.forEach(addTrackingArea)
    }

    private func updateToolTips() {
        removeAllToolTips()
        addToolTip(rect(of: .minimize), owner: tipOwners[0], userData: nil)
        if showMaximizeTip { addToolTip(rect(of: .maximize), owner: tipOwners[maximized ? 2 : 1], userData: nil) }
        addToolTip(rect(of: .close), owner: tipOwners[3], userData: nil)
        if showsMenu { addToolTip(rect(of: .menu), owner: tipOwners[4], userData: nil) }
    }

    private func part(at event: NSEvent) -> Part? {
        let pt = convert(event.locationInWindow, from: nil)
        guard bounds.contains(pt) else { return nil }
        return Part(rawValue: min(visibleParts.count - 1, max(0, Int(pt.x / buttonWidth))))
    }

    private func setHover(_ p: Part?) {
        guard p != hovered else { return }
        let old = hovered
        hovered = p
        refresh()
        if old == .maximize { onMaximizeHover?(false, screenRect(of: .maximize)) }
        if p == .maximize, enabledParts[Part.maximize.rawValue] { onMaximizeHover?(true, screenRect(of: .maximize)) }
    }

    /// Clears hover/press state (the panel is being hidden or moved).
    func resetInteraction() {
        pressed = nil
        pressedInside = false
        setHover(nil)
    }

    override func mouseEntered(with event: NSEvent) {
        if let raw = event.trackingArea?.userInfo?["part"] as? Int { setHover(Part(rawValue: raw)) }
    }

    override func mouseExited(with event: NSEvent) {
        guard let raw = event.trackingArea?.userInfo?["part"] as? Int, hovered?.rawValue == raw else { return }
        setHover(nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard let p = part(at: event), enabledParts[p.rawValue] else { return }
        if p == .menu {
            // Menus open on press. popUp runs its own tracking loop and returns once the menu closes.
            pressed = p; pressedInside = true; hovered = p
            refresh(animated: false)
            onMenu?(screenRect(of: .menu))
            pressed = nil; pressedInside = false
            setHover(nil)
            refresh()
            return
        }
        pressed = p
        pressedInside = true
        hovered = p
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let p = pressed else { return }
        let inside = part(at: event) == p
        if inside != pressedInside { pressedInside = inside; refresh() }
    }

    override func mouseUp(with event: NSEvent) {
        guard let p = pressed else { return }
        let hit = part(at: event) == p
        pressed = nil
        pressedInside = false
        refresh()
        if hit { onClick?(p) }
    }

    override func rightMouseDown(with event: NSEvent) {
        resetInteraction()
        onRightClick?(NSEvent.mouseLocation)
    }
}
