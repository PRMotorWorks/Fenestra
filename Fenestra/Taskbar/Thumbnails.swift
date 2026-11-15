import AppKit
import SwiftUI
import ScreenCaptureKit

/// Window thumbnails via ScreenCaptureKit (public API, Screen Recording permission).
/// Minimized windows can't be captured live, so the last good capture is reused.
@MainActor
final class ThumbnailCapture {
    static let shared = ThumbnailCapture()
    private var cache: [CGWindowID: NSImage] = [:]
    private var content: SCShareableContent?
    private var contentDate = Date.distantPast

    func cached(_ id: CGWindowID) -> NSImage? { cache[id] }
    func store(_ id: CGWindowID, _ img: NSImage) {
        cache[id] = img
        if cache.count > 120 { cache.removeAll() }      // closed windows; cheap to capture again
    }

    func capture(_ ids: [CGWindowID], maxSize: CGSize) async -> [CGWindowID: NSImage] {
        guard CGPreflightScreenCaptureAccess(), !ids.isEmpty else { return [:] }
        if content == nil || Date().timeIntervalSince(contentDate) > 1.5 {
            content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            contentDate = Date()
        }
        guard let windows = content?.windows else { return [:] }
        var out: [CGWindowID: NSImage] = [:]
        for id in ids {
            guard let w = windows.first(where: { $0.windowID == id }) else { continue }
            let scale = min(maxSize.width / max(w.frame.width, 1), maxSize.height / max(w.frame.height, 1), 1)
            let cfg = SCStreamConfiguration()
            let backing = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
            cfg.width = max(Int(w.frame.width * scale * backing), 2)
            cfg.height = max(Int(w.frame.height * scale * backing), 2)
            cfg.showsCursor = false
            cfg.ignoreShadowsSingleWindow = true
            let filter = SCContentFilter(desktopIndependentWindow: w)
            if let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) {
                let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / backing,
                                                            height: CGFloat(cg.height) / backing))
                cache[id] = img
                out[id] = img
            } else if let old = cache[id] {
                out[id] = old
            }
        }
        return out
    }
}

/// Shows the hover/click thumbnail strip above a taskbar button.
@MainActor
final class ThumbnailController {
    static let shared = ThumbnailController()
    private var showTimer: Timer?
    private var hideTimer: Timer?
    private(set) var itemID: String?
    private var panelHovered = false

    func hoverBegan(item: AppItem, anchor: NSRect, scope: TaskbarActions.Scope? = nil) {
        hideTimer?.invalidate()
        guard item.isRunning else { return }
        if itemID != nil && itemID != item.id {          // moving along the taskbar: switch instantly
            show(for: item, anchor: anchor, pinnedOpen: false, scope: scope)
            return
        }
        guard itemID == nil else { return }
        showTimer?.invalidate()
        showTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { _ in
            MainActor.assumeIsolated { ThumbnailController.shared.show(for: item, anchor: anchor, pinnedOpen: false, scope: scope) }
        }
        RecentFiles.shared.prefetch(item)
    }

    func hoverEnded() {
        showTimer?.invalidate()
        scheduleHide()
    }

    func panelHover(_ inside: Bool) {
        panelHovered = inside
        if inside { hideTimer?.invalidate() } else { scheduleHide() }
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
            MainActor.assumeIsolated {
                let c = ThumbnailController.shared
                if !c.panelHovered { c.dismiss() }
            }
        }
    }

    func dismiss() {
        showTimer?.invalidate()
        if itemID != nil, FlyoutManager.shared.currentID?.hasPrefix("thumbs:") == true {
            FlyoutManager.shared.close(animated: false)
        }
        itemID = nil
        panelHovered = false
    }

    func show(for item: AppItem, anchor: NSRect, pinnedOpen: Bool, scope: TaskbarActions.Scope? = nil) {
        let windows = Permissions.shared.accessibility ? TaskbarActions.windows(of: item, scope: scope) : []
        itemID = item.id
        var groups = AppSettings.shared.snapGroups
            ? SnapGroups.shared.groups(containing: Set(windows.compactMap(\.windowID))) : []
        if let scope { groups = groups.filter { scope.contains($0.display) } }
        let model = ThumbnailStripModel(item: item, windows: windows, groups: groups)
        FlyoutManager.shared.show(id: "thumbs:\(item.id)", anchor: anchor, align: .center, gap: 8) {
            ThumbnailStrip(model: model)
        }
        Task { await model.load() }
    }
}

@MainActor
final class ThumbnailStripModel: ObservableObject {
    let item: AppItem
    let windows: [TaskbarActions.WindowRef]
    /// Snap groups with one of these windows (Windows 11 shows them before the app's own windows).
    let groups: [SnapGroups.Group]
    @Published var images: [CGWindowID: NSImage] = [:]
    static let thumbSize = CGSize(width: 200, height: 120)

    init(item: AppItem, windows: [TaskbarActions.WindowRef], groups: [SnapGroups.Group] = []) {
        self.item = item
        self.windows = windows
        self.groups = groups
        let ids = windows.compactMap(\.windowID) + groups.flatMap { $0.members.map(\.id) }
        for id in ids { if let c = ThumbnailCapture.shared.cached(id) { images[id] = c } }
    }

    func load() async {
        var ids = windows.filter { !$0.minimized }.compactMap(\.windowID)
        for g in groups { for m in g.members where !AX.isMinimized(m.element) && !ids.contains(m.id) { ids.append(m.id) } }
        let fresh = await ThumbnailCapture.shared.capture(ids, maxSize: Self.thumbSize)
        images.merge(fresh) { _, new in new }
    }
}

struct ThumbnailStrip: View {
    @ObservedObject var model: ThumbnailStripModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if model.windows.isEmpty {
                // No windows (or no Accessibility permission): Windows shows just the app name.
                HStack(spacing: 8) {
                    Image(nsImage: TaskbarModel.shared.icon(for: model.item)).resizable().frame(width: 16, height: 16)
                    Text(model.item.name).lineLimit(1)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                HStack(spacing: 4) {
                    ForEach(model.groups) { g in
                        SnapGroupCard(model: model, group: g)
                    }
                    ForEach(model.windows) { w in
                        ThumbnailCard(model: model, window: w)
                    }
                }
                .padding(6)
            }
        }
        .onHover { ThumbnailController.shared.panelHover($0) }
    }
}

struct ThumbnailCard: View {
    @ObservedObject var model: ThumbnailStripModel
    let window: TaskbarActions.WindowRef
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var closeHover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(nsImage: TaskbarModel.shared.icon(for: model.item)).resizable().frame(width: 16, height: 16)
                Text(window.title.isEmpty ? model.item.name : window.title)
                    .font(Theme.font(12)).lineLimit(1)
                Spacer(minLength: 4)
                if hovering {
                    Button { AX.close(window.element); ThumbnailController.shared.dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 4).fill(closeHover ? Color(red: 0.77, green: 0.17, blue: 0.11) : .clear))
                            .foregroundStyle(closeHover ? .white : Theme.text(scheme))
                    }
                    .buttonStyle(.plain)
                    .onHover { closeHover = $0 }
                }
            }
            // As wide as the preview: a long title ends in "..." instead of widening the card (Windows does the same).
            .frame(width: ThumbnailStripModel.thumbSize.width, height: 22)
            ZStack {
                if let id = window.windowID, let img = model.images[id] {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(nsImage: TaskbarModel.shared.icon(for: model.item)).resizable().frame(width: 40, height: 40)
                        .opacity(0.8)
                }
            }
            .frame(width: ThumbnailStripModel.thumbSize.width, height: ThumbnailStripModel.thumbSize.height)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.hover(scheme) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            ThumbnailController.shared.dismiss()
            NSRunningApplication(processIdentifier: window.pid)?.unhide()
            AX.focus(pid: window.pid, window: window.element)
        }
    }
}

/// A snap group in the taskbar preview: the group's windows drawn in their zones, as Windows 11 shows it.
/// Clicking it brings the whole group back, with the hovered app's window in front.
struct SnapGroupCard: View {
    @ObservedObject var model: ThumbnailStripModel
    let group: SnapGroups.Group
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var title: String {
        var names: [String] = []
        for m in group.members {
            let n = NSRunningApplication(processIdentifier: m.pid)?.localizedName ?? "?"
            if !names.contains(n) { names.append(n) }
        }
        return names.joined(separator: ", ")
    }

    var body: some View {
        let box = ThumbnailStripModel.thumbSize
        let wa = group.workArea
        let scale = min(box.width / max(wa.width, 1), box.height / max(wa.height, 1))
        let size = CGSize(width: wa.width * scale, height: wa.height * scale)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.split.2x1").font(.system(size: 12)).frame(width: 16, height: 16)
                Text(title).font(Theme.font(12)).lineLimit(1)
                Spacer(minLength: 4)
            }
            .frame(width: box.width, height: 22)
            ZStack(alignment: .topLeading) {
                ForEach(group.members, id: \.id) { m in
                    let r = CGRect(x: m.zone.minX * size.width, y: m.zone.minY * size.height,
                                   width: m.zone.width * size.width, height: m.zone.height * size.height)
                        .insetBy(dx: 1.5, dy: 1.5)
                    ZStack {
                        RoundedRectangle(cornerRadius: 3).fill(Theme.control(scheme))
                        if let img = model.images[m.id] {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        } else if let app = NSRunningApplication(processIdentifier: m.pid), let icon = app.icon {
                            Image(nsImage: icon).resizable().frame(width: 24, height: 24).opacity(0.8)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.border(scheme), lineWidth: 1))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                }
            }
            .frame(width: size.width, height: size.height)
            .frame(width: box.width, height: box.height)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.hover(scheme) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            ThumbnailController.shared.dismiss()
            let mine = Set(model.item.pids)
            SnapGroups.shared.restore(group, focus: group.members.first { mine.contains($0.pid) }?.id)
        }
        .help("Snap group: \(title)")
    }
}
