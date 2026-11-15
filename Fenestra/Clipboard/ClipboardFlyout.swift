import AppKit
import SwiftUI

/// Windows key + V flyout (Control+Option+V): opens at the text cursor of the app you are typing in (at the pointer
/// when the cursor can't be read), never takes keyboard focus. Arrow keys, Return and Esc reach it through the
/// HotKeys event tap while it is open, so the app keeps its focus and the paste lands there.
@MainActor
enum ClipboardFlyout {
    static let id = "clipboard"

    static func toggle() {
        if FlyoutManager.shared.isOpen(id) { FlyoutManager.shared.close(); return }
        let h = ClipboardHistory.shared
        h.selected = 0
        h.expanded = nil
        h.part = .item
        h.checkNow()
        let started = DispatchTime.now()
        // The caret lookup is a few AX round trips to the front app: off the main thread.
        DispatchQueue.global(qos: .userInteractive).async {
            let caret = caretRect()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    show(caret: caret)
                    let ms = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                    Log.write("clipboard: flyout at \(caret == nil ? "pointer" : "text cursor"), \(h.items.count) item(s), \(ms) ms")
                }
            }
        }
    }

    private static func show(caret: CGRect?) {
        let anchor: NSRect
        let cursor = caret.map {
            NSRect(x: $0.minX, y: CaptionController.primaryHeight - $0.maxY, width: max($0.width, 1), height: $0.height)
        }
        if let cursor, NSScreen.screens.contains(where: { $0.frame.contains(NSPoint(x: cursor.minX, y: cursor.midY)) }) {
            anchor = cursor
        } else {
            let m = NSEvent.mouseLocation
            anchor = NSRect(x: m.x, y: m.y, width: 1, height: 1)
        }
        FlyoutManager.shared.show(id: id, anchor: anchor, align: .leading, gap: 6, placement: .below, keyable: false,
                                  onClose: { HotKeys.shared.setClipboardActive(false) }) {
            ClipboardView()
        }
        HotKeys.shared.setClipboardActive(true)
    }

    /// Keys while the flyout is open (from the event tap): Up/Down move between items, Tab and Shift+Tab move to
    /// the item's ... (See more), Delete and Pin buttons, Return activates the focused one, Esc closes.
    static func key(_ code: Int64, shift: Bool = false) {
        guard FlyoutManager.shared.isOpen(id) else { return }
        let h = ClipboardHistory.shared
        switch code {
        case 125: h.moveSelection(1)
        case 126: h.moveSelection(-1)
        case 48: h.moveFocus(shift ? -1 : 1)
        case 36, 76: h.activateFocused()
        default: FlyoutManager.shared.close()
        }
    }

    /// Text cursor of the focused element, in AX (top-left origin) coordinates. Works in native text views and
    /// most web views; nil in apps that don't publish it (then the flyout opens at the pointer).
    nonisolated private static func caretRect() -> CGRect? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &v) == .success,
              let focused = v, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let el = focused as! AXUIElement
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range else { return nil }
        var b: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                        range, &b) == .success,
              let b, CFGetTypeID(b) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(b as! AXValue, .cgRect, &r), r.origin != .zero else { return nil }
        if r.height < 1 { r.size.height = 16 }        // an empty line can report no height
        return r
    }
}

struct ClipboardView: View {
    @ObservedObject private var h = ClipboardHistory.shared
    @ObservedObject private var s = AppSettings.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let list = h.ordered
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Clipboard history").font(Theme.font(14, .semibold))
                Spacer()
                if s.clipboardHistory && list.contains(where: { !$0.pinned }) {
                    Button("Clear all") { h.clearAll() }.buttonStyle(.link).font(Theme.font(12))
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            if !s.clipboardHistory {
                message("Clipboard history is off",
                        "Turn it on to keep the last \(s.clipboardLimit) things you copy and paste any of them.",
                        button: "Turn on") { s.clipboardHistory = true }
            } else if list.isEmpty {
                message("Nothing here yet", "Copy text, an image or files and they show up here.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                                ClipCard(item: item, selected: i == h.selected).id(item.id)
                            }
                        }
                        .padding(.horizontal, 12).padding(.bottom, 12)
                    }
                    .onChange(of: h.selected) { _, i in
                        if list.indices.contains(i) { proxy.scrollTo(list[i].id) }
                    }
                }
            }
        }
        .frame(width: 360, height: 440, alignment: .top)
    }

    private func message(_ title: String, _ detail: String, button: String? = nil,
                         action: @escaping () -> Void = {}) -> some View {
        VStack(spacing: 8) {
            Text(title).font(Theme.font(14, .semibold))
            Text(detail).font(Theme.font(12)).foregroundStyle(Theme.secondaryText(scheme)).multilineTextAlignment(.center)
            if let button { Button(button, action: action).padding(.top, 4) }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One history entry: preview, then pin mark and ... (See more), which turns into Delete and Pin, as on Windows.
struct ClipCard: View {
    let item: ClipItem
    let selected: Bool
    @ObservedObject private var h = ClipboardHistory.shared
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            preview.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            HStack(spacing: 0) {
                if h.expanded == item.id {
                    ClipIconButton(symbol: "trash", help: "Delete", focused: selected && h.part == .delete) {
                        h.delete(item.id)
                    }
                    ClipIconButton(symbol: item.pinned ? "pin.slash" : "pin", help: item.pinned ? "Unpin" : "Pin",
                                   focused: selected && h.part == .pin) {
                        h.togglePin(item.id)
                    }
                } else if item.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 11)).frame(width: 28, height: 28)
                }
                ClipIconButton(symbol: "ellipsis", help: "See more", focused: selected && h.part == .more) {
                    h.expanded = h.expanded == item.id ? nil : item.id
                }
            }
        }
        .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 6)
        .frame(minHeight: 52, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.control(scheme)))
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Theme.hover(scheme) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(selected && h.part == .item ? Theme.text(scheme) : Theme.border(scheme),
                          lineWidth: selected && h.part == .item ? 2 : 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { h.paste(item.id) }
    }

    @ViewBuilder private var preview: some View {
        switch item.kind {
        case .text(let s):
            Text(String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600)))
                .font(Theme.font(13)).lineLimit(4)
        case .image(let img, _):
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: 260, maxHeight: 110, alignment: .leading)
        case .files(let urls):
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: urls[0].path)).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")
                        .font(Theme.font(13)).lineLimit(1)
                    Text(urls.count == 1 ? urls[0].deletingLastPathComponent().path
                                         : urls.map(\.lastPathComponent).joined(separator: ", "))
                        .font(Theme.font(11)).foregroundStyle(Theme.secondaryText(scheme))
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }
}

struct ClipIconButton: View {
    let symbol: String
    let help: String
    var focused = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Theme.hover(scheme) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(focused ? Theme.text(scheme) : .clear, lineWidth: 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}
