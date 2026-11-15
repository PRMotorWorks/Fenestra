import AppKit
import SwiftUI

/// Windows 11 look-alike colors and fonts. Follows macOS light/dark mode and accent color.
enum Theme {
    /// 48 pt normally, 40 pt with "Show smaller taskbar buttons" in effect (set by TaskbarController).
    nonisolated(unsafe) static var taskbarHeight: CGFloat = 48

    // Segoe UI Variable is preferred if you install it yourself; otherwise the system font.
    static let segoeFamily: String? = {
        for name in ["Segoe UI Variable Text", "Segoe UI Variable", "Segoe UI"] {
            if NSFont(name: name, size: 12) != nil { return name }
        }
        return nil
    }()

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if let f = segoeFamily { return .custom(f, size: size).weight(weight) }
        return .system(size: size, weight: weight)
    }

    static var accent: Color { Color(nsColor: .controlAccentColor) }

    static func text(_ s: ColorScheme) -> Color { s == .dark ? .white : Color(white: 0.1) }
    static func secondaryText(_ s: ColorScheme) -> Color { s == .dark ? Color(white: 0.78) : Color(white: 0.36) }

    /// Tint laid over the blur. Windows 11 taskbar: near-opaque dark gray / light gray.
    static func taskbarTint(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.82)
                   : Color(red: 0.93, green: 0.93, blue: 0.94).opacity(0.82)
    }
    static func flyoutTint(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.16, green: 0.16, blue: 0.17).opacity(0.88)
                   : Color(red: 0.95, green: 0.95, blue: 0.96).opacity(0.88)
    }
    static func flyoutFooter(_ s: ColorScheme) -> Color {
        s == .dark ? Color.black.opacity(0.18) : Color.black.opacity(0.04)
    }
    static func hover(_ s: ColorScheme) -> Color { s == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05) }
    static func pressed(_ s: ColorScheme) -> Color { s == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03) }
    static func border(_ s: ColorScheme) -> Color { s == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.09) }
    static func control(_ s: ColorScheme) -> Color { s == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.75) }
    static func runningPill(_ s: ColorScheme) -> Color { s == .dark ? Color(white: 0.62) : Color(white: 0.45) }
}

extension NSView {
    /// Rounds a borderless window's content (clips AppKit subviews too, unlike SwiftUI's clipShape).
    /// The window shadow then follows the rounded shape after `invalidateShadow()`.
    func roundCorners(_ radius: CGFloat) {
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }
}

/// Blur behind a window, used under the Windows-style tints (Mica / Acrylic approximation).
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var cornerRadius: CGFloat = 0
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        if cornerRadius > 0 { v.maskImage = Self.mask(cornerRadius) }   // behind-window blur ignores SwiftUI clipping
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }

    static func mask(_ r: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}
