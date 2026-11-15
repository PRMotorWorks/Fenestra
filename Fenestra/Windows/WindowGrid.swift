import AppKit
import SwiftUI

/// Window cards (icon and title above a live thumbnail) in centered rows, shared by Alt+Tab, Task View and
/// Snap Assist. The layout picks the biggest thumbnail height at which every window fits, like Windows.
@MainActor
final class WindowGridModel: ObservableObject {
    @Published private(set) var items: [SwitchWindow]
    @Published private(set) var rows: [[Int]] = []
    @Published var images: [CGWindowID: NSImage] = [:]
    @Published var selected: Int?
    @Published private(set) var thumbH: CGFloat = 150
    /// Size of all rows together (for sizing the panel around them).
    private(set) var contentSize: CGSize = .zero
    private var width: CGFloat = 800

    var onPick: ((SwitchWindow) -> Void)?
    var onClose: ((SwitchWindow) -> Void)?
    /// Hovering a card selects it (Alt+Tab and Task View do this on Windows).
    var hoverSelects = true
    /// Where the pointer was when the cards appeared: a card that merely appears under a resting pointer
    /// isn't selected; selection follows the mouse once it moves.
    private var hoverOrigin: NSPoint? = NSEvent.mouseLocation

    func hoverShouldSelect() -> Bool {
        guard hoverSelects else { return false }
        guard let o = hoverOrigin else { return true }
        if hypot(NSEvent.mouseLocation.x - o.x, NSEvent.mouseLocation.y - o.y) > 2 { hoverOrigin = nil; return true }
        return false
    }

    static let pad: CGFloat = 8          // inside a card
    static let header: CGFloat = 24      // icon + title row
    static let gap: CGFloat = 6          // header to thumbnail
    static let spacing: CGFloat = 12     // between cards and rows

    init(items: [SwitchWindow]) { self.items = items }

    func thumbWidth(_ i: Int) -> CGFloat {
        guard items.indices.contains(i) else { return thumbH }
        return min(max(items[i].aspect * thumbH, thumbH * 0.75), thumbH * 2.2).rounded()
    }
    var cardHeight: CGFloat { thumbH + Self.header + Self.gap + Self.pad * 2 }
    func cardWidth(_ i: Int) -> CGFloat { thumbWidth(i) + Self.pad * 2 }

    /// Largest thumbnail height between maxH and minH at which all cards fit into `area`.
    func layout(in area: CGSize, maxH: CGFloat, minH: CGFloat) {
        width = area.width
        var h = maxH
        while true {
            thumbH = h
            let r = pack(width: area.width)
            let height = CGFloat(r.count) * cardHeight + CGFloat(max(r.count - 1, 0)) * Self.spacing
            if height <= area.height || h <= minH {
                setRows(r)
                return
            }
            h = max(minH, h - 6)
        }
    }

    private func pack(width: CGFloat) -> [[Int]] {
        var out: [[Int]] = []
        var row: [Int] = []
        var x: CGFloat = 0
        for i in items.indices {
            let w = cardWidth(i)
            if !row.isEmpty && x + Self.spacing + w > width {
                out.append(row); row = []; x = 0
            }
            x += (row.isEmpty ? 0 : Self.spacing) + w
            row.append(i)
        }
        if !row.isEmpty { out.append(row) }
        return out
    }

    private func setRows(_ r: [[Int]]) {
        rows = r
        let rowWidths = r.map { row in row.map(cardWidth).reduce(0, +) + CGFloat(max(row.count - 1, 0)) * Self.spacing }
        contentSize = CGSize(width: rowWidths.max() ?? 0,
                             height: CGFloat(r.count) * cardHeight + CGFloat(max(r.count - 1, 0)) * Self.spacing)
    }

    /// Drops a closed window; the others keep their size.
    func remove(_ id: CGWindowID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: i)
        setRows(pack(width: width))
        if let s = selected {
            selected = items.isEmpty ? nil : min(s > i ? s - 1 : s, items.count - 1)
        }
    }

    func loadThumbnails(maxSize: CGSize) {
        let ids = items.filter { !$0.minimized }.map(\.id)
        for w in items where w.minimized { if let c = ThumbnailCapture.shared.cached(w.id) { images[w.id] = c } }
        Task { @MainActor [weak self] in
            await ThumbnailCapture.shared.captureEach(ids, maxSize: maxSize) { id, img in self?.images[id] = img }
        }
    }

    enum Move { case left, right, up, down }

    /// Keyboard navigation: left/right walk through all cards (wrapping), up/down go to the nearest card
    /// in the row above or below.
    func move(_ m: Move) {
        guard !items.isEmpty else { return }
        guard let s = selected else { selected = 0; return }
        switch m {
        case .left: selected = (s - 1 + items.count) % items.count
        case .right: selected = (s + 1) % items.count
        case .up, .down:
            guard let r = rows.firstIndex(where: { $0.contains(s) }) else { return }
            let target = m == .up ? r - 1 : r + 1
            guard rows.indices.contains(target) else { return }
            let x = center(of: s, in: rows[r])
            selected = rows[target].min { abs(center(of: $0, in: rows[target]) - x) < abs(center(of: $1, in: rows[target]) - x) }
        }
    }

    private func center(of i: Int, in row: [Int]) -> CGFloat {
        let total = row.map(cardWidth).reduce(0, +) + CGFloat(max(row.count - 1, 0)) * Self.spacing
        var x = -total / 2
        for j in row {
            if j == i { return x + cardWidth(j) / 2 }
            x += cardWidth(j) + Self.spacing
        }
        return 0
    }

    func pick(_ i: Int) { if items.indices.contains(i) { onPick?(items[i]) } }
    func close(_ i: Int) {
        guard items.indices.contains(i) else { return }
        let w = items[i]
        onClose?(w)
        remove(w.id)
    }
}

/// The rows of cards, centered.
struct WindowGridView: View {
    @ObservedObject var model: WindowGridModel
    var body: some View {
        VStack(spacing: WindowGridModel.spacing) {
            ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: WindowGridModel.spacing) {
                    ForEach(row, id: \.self) { i in
                        if model.items.indices.contains(i) { WindowCardView(model: model, index: i, id: model.items[i].id) }
                    }
                }
            }
        }
    }
}

/// One window: app icon and title, close button on hover (red, like the caption close button), thumbnail.
/// The selected card gets the Windows focus outline.
struct WindowCardView: View {
    @ObservedObject var model: WindowGridModel
    let index: Int
    let id: CGWindowID
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var closeHover = false

    var body: some View {
        if model.items.indices.contains(index), model.items[index].id == id { card(model.items[index]) }
    }

    private func card(_ w: SwitchWindow) -> some View {
        let tw = model.thumbWidth(index)
        let selected = model.selected == index
        return VStack(alignment: .leading, spacing: WindowGridModel.gap) {
            HStack(spacing: 6) {
                Image(nsImage: WindowList.icon(w.pid)).resizable().frame(width: 16, height: 16)
                Text(w.label).font(Theme.font(12)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 2)
                if hovering {
                    Button { model.close(index) } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 4)
                                .fill(closeHover ? Color(red: 0.77, green: 0.17, blue: 0.11) : Theme.hover(scheme)))
                            .foregroundStyle(closeHover ? .white : Theme.text(scheme))
                    }
                    .buttonStyle(.plain)
                    .onHover { closeHover = $0 }
                    .help("Close")
                }
            }
            .frame(height: WindowGridModel.header)
            ZStack {
                if let img = model.images[id] {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.control(scheme))
                    Image(nsImage: WindowList.icon(w.pid)).resizable().frame(width: 48, height: 48)
                }
            }
            .frame(width: tw, height: model.thumbH)
        }
        .padding(WindowGridModel.pad)
        .frame(width: tw + WindowGridModel.pad * 2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected || hovering ? Theme.hover(scheme).opacity(selected ? 2.2 : 1.6) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(selected ? Theme.text(scheme) : .clear, lineWidth: 2.5))
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside && model.hoverShouldSelect() { model.selected = index }
        }
        .onTapGesture { model.pick(index) }
    }
}

/// Hosting view that acts on the first click. Fenestra never becomes the active app (its panels are
/// non-activating), and AppKit otherwise spends the first click on an inactive app's window just focusing it:
/// a Snap Layouts zone or Snap Assist card then needed a second click.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless panel for Alt+Tab, Task View, Snap Assist and the snap previews.
final class OverlayPanel: NSPanel {
    var keyable = false
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }

    init(level: NSWindow.Level, keyable: Bool = false) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        self.keyable = keyable
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
    }
}
