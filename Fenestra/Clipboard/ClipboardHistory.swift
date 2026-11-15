import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// One clipboard history entry (Windows key + V). Kept in memory only.
struct ClipItem: Identifiable {
    enum Kind {
        case text(String)
        case image(NSImage, pixels: CGSize)      // small preview; the full image is in `data` as PNG
        case files([URL])
    }
    let id = UUID()
    let kind: Kind
    /// What goes back on the pasteboard (one pasteboard item). Empty for files: they go back as file URLs.
    let data: [(NSPasteboard.PasteboardType, Data)]
    let fingerprint: String                     // SHA-256 of the main content, for duplicates
    var pinned = false

    /// Kind and size only, for the log (never the content).
    var summary: String {
        let bytes = data.reduce(0) { $0 + $1.1.count }
        let what: String
        switch kind {
        case .text: what = "text"
        case .image(_, let px): what = "image \(Int(px.width))x\(Int(px.height))"
        case .files(let urls): what = "\(urls.count) file(s)"
        }
        return "\(what), \(bytes) B, types \(data.map(\.0.rawValue).joined(separator: " "))\(pinned ? ", pinned" : "")"
    }
}

/// Clipboard history: the list and what the flyout does with it. The pasteboard itself is only touched on
/// `ClipboardReader`'s queue.
@MainActor
final class ClipboardHistory: ObservableObject {
    static let shared = ClipboardHistory()
    /// Windows keeps text, HTML and images under 4 MB; bigger copies are left out of the history.
    nonisolated static let maxBytes = 4 * 1024 * 1024

    @Published private(set) var items: [ClipItem] = []       // most recent first
    @Published var selected = 0                               // keyboard focus in the flyout (index into `ordered`)
    @Published var expanded: UUID?                            // item whose ... (See more) is open
    /// Which part of the selected item has keyboard focus (Tab / Shift+Tab, as on Windows).
    enum Part { case item, more, delete, pin }
    @Published var part: Part = .item

    /// Display order: pinned items first, then the rest, each most recent first.
    var ordered: [ClipItem] { items.filter(\.pinned) + items.filter { !$0.pinned } }

    private let reader = ClipboardReader()

    func start() {
        settingsChanged()
        // Diagnostics (no setting needed): distributed notification "local.fenestra.debug.clipboard" with object
        // "open" (toggles the flyout as Control+Option+V does) or "list" (logs each item's kind and size, no content).
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.fenestra.debug.clipboard"), object: nil, queue: .main
        ) { n in
            let what = n.object as? String ?? "list"
            MainActor.assumeIsolated {
                if what == "open" { ClipboardFlyout.toggle(); return }
                let h = ClipboardHistory.shared
                Log.write("cliptest: \(h.items.count) item(s), open=\(FlyoutManager.shared.isOpen(ClipboardFlyout.id))")
                for (i, item) in h.ordered.enumerated() { Log.write("cliptest: \(i) \(item.summary)") }
            }
        }
    }

    func settingsChanged() {
        if AppSettings.shared.clipboardHistory {
            reader.start()
        } else {
            reader.stop()
            items.removeAll { !$0.pinned }
        }
        trim()
    }

    /// Picks up a copy made in the last half second before the flyout shows it.
    func checkNow() { reader.checkNow() }

    func add(_ new: ClipItem) {
        var item = new
        if let i = items.firstIndex(where: { $0.fingerprint == new.fingerprint }) {
            item.pinned = items[i].pinned
            items.remove(at: i)
        }
        items.insert(item, at: 0)
        trim()
        Log.write("clipboard: + \(item.summary) (\(items.count) item(s))")
    }

    func trim() {
        let limit = AppSettings.shared.clipboardLimit
        var unpinned = 0
        var kept: [ClipItem] = []
        for item in items {
            if !item.pinned { unpinned += 1; if unpinned > limit { continue } }
            kept.append(item)
        }
        if kept.count != items.count { items = kept }
        selected = min(selected, max(items.count - 1, 0))
    }

    /// Windows: the item goes on the clipboard and is pasted into the app you were typing in.
    func paste(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: i)
        items.insert(item, at: 0)
        FlyoutManager.shared.close(animated: false)
        // The flyout never takes keyboard focus, so the app you were typing in still has it: Command+V lands there.
        // V is key code 9 on U.S., ABC and Romanian.
        reader.write(item) { SystemActions.postKey(9, flags: .maskCommand) }
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        expanded = nil
        selected = min(selected, max(items.count - 1, 0))
    }

    func togglePin(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned.toggle()
        expanded = nil
    }

    /// Flyout "Clear all": everything except pinned items.
    func clearAll() {
        items.removeAll { !$0.pinned }
        expanded = nil
        selected = 0
    }

    /// Settings "Clear clipboard data": the history (pinned items stay) and what is on the clipboard now.
    func clearData() {
        clearAll()
        reader.clearPasteboard()
    }

    /// Tab order inside the selected item: the item, then ... (See more), then Delete and Pin once ... is open.
    func moveFocus(_ delta: Int) {
        let list = ordered
        guard list.indices.contains(selected) else { return }
        let parts: [Part] = expanded == list[selected].id ? [.item, .more, .delete, .pin] : [.item, .more]
        let i = parts.firstIndex(of: part) ?? 0
        part = parts[(i + delta + parts.count) % parts.count]
    }

    /// Return on the focused part.
    func activateFocused() {
        let list = ordered
        guard list.indices.contains(selected) else { return }
        let id = list[selected].id
        switch part {
        case .item: paste(id)
        case .more: expanded = expanded == id ? nil : id
        case .delete: delete(id); part = .item
        case .pin:
            togglePin(id)
            selected = ordered.firstIndex { $0.id == id } ?? selected    // focus follows the item
            part = .item
        }
    }

    func moveSelection(_ delta: Int) {
        part = .item
        expanded = nil
        let n = items.count
        guard n > 0 else { return }
        selected = min(max(selected + delta, 0), n - 1)
    }

    func pasteSelected() {
        let list = ordered
        guard list.indices.contains(selected) else { return }
        paste(list[selected].id)
    }
}

/// Watches the general pasteboard. macOS has no change notification for it, so `changeCount` is compared every
/// 0.5 s (with 0.25 s leeway so the system can batch the wakeup); that is one cheap call to the pasteboard
/// server. Content is read only when the count changes, all on one background queue: reading a big image or a
/// lazily provided type can take a while, and macOS may hold the read for its paste permission alert.
final class ClipboardReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fenestra.clipboard", qos: .utility)
    private var timer: DispatchSourceTimer?      // main thread only
    // Queue only:
    private var lastCount = -1
    private var ownCount = -1
    private var refusedLogged = false
    private var settling = false

    /// Copies that password managers and similar apps mark as not for history (nspasteboard.org conventions).
    private static let skipTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword", "de.petermaurer.TransientPasteboardType", "com.typeit4me.clipping",
        "Pasteboard generator type", "net.antelle.keeweb",
    ]

    @MainActor
    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(250))
        t.setEventHandler { [unowned self] in self.poll() }
        t.resume()
        timer = t
        let behavior: String
        switch NSPasteboard.general.accessBehavior {
        case .default: behavior = "default (macOS asks once)"
        case .ask: behavior = "ask"
        case .alwaysAllow: behavior = "always allow"
        case .alwaysDeny: behavior = "always deny (history stays empty)"
        @unknown default: behavior = "unknown"
        }
        Log.write("clipboard: watching (limit \(AppSettings.shared.clipboardLimit), paste access: \(behavior))")
    }

    @MainActor
    func stop() {
        guard let t = timer else { return }
        t.cancel()
        timer = nil
        queue.async { self.lastCount = -1 }
        Log.write("clipboard: stopped")
    }

    func checkNow() { queue.async { self.poll() } }

    func write(_ item: ClipItem, then: @escaping @MainActor () -> Void) {
        queue.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            if case .files(let urls) = item.kind {
                pb.writeObjects(urls as [NSURL])
            } else {
                let pi = NSPasteboardItem()
                for (type, data) in item.data { pi.setData(data, forType: type) }
                // Older apps only read TIFF images.
                if case .image = item.kind, let png = item.data.first(where: { $0.0 == .png })?.1,
                   let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation {
                    pi.setData(tiff, forType: .tiff)
                }
                pb.writeObjects([pi])
            }
            self.ownCount = pb.changeCount
            self.lastCount = self.ownCount
            DispatchQueue.main.async { MainActor.assumeIsolated { then() } }
        }
    }

    func clearPasteboard() {
        queue.async {
            NSPasteboard.general.clearContents()
            self.lastCount = NSPasteboard.general.changeCount
        }
    }

    private func poll() {
        guard !settling, NSPasteboard.general.changeCount != lastCount else { return }
        // A copy can arrive in steps (clear, then one write per item): read it 80 ms later, once it has settled.
        settling = true
        queue.asyncAfter(deadline: .now() + .milliseconds(80)) {
            self.settling = false
            let pb = NSPasteboard.general
            let count = pb.changeCount
            guard count != self.lastCount else { return }
            self.lastCount = count
            guard count != self.ownCount, let item = self.capture(pb) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { ClipboardHistory.shared.add(item) } }
        }
    }

    private func capture(_ pb: NSPasteboard) -> ClipItem? {
        guard let types = pb.types, !types.isEmpty else { return nil }
        let names = Set(types.map(\.rawValue))
        if !names.isDisjoint(with: Self.skipTypes) {
            Log.write("clipboard: left out a copy marked concealed or transient")
            return nil
        }

        // Files copied in Finder (not in Windows' history; the user asked for them).
        if names.contains(NSPasteboard.PasteboardType.fileURL.rawValue) {
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
               !urls.isEmpty {
                return ClipItem(kind: .files(urls), data: [],
                                fingerprint: Self.hash(Data(urls.map(\.path).joined(separator: "\n").utf8)))
            }
            return refused(pb)
        }

        let string = names.contains(NSPasteboard.PasteboardType.string.rawValue) ? pb.string(forType: .string) : nil
        let rich = names.contains(NSPasteboard.PasteboardType.rtf.rawValue)
            || names.contains(NSPasteboard.PasteboardType.rtfd.rawValue)
        let imageType = [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")]
            .first { names.contains($0.rawValue) }
        // An image copied from a browser often comes with its address as text: still an image.
        let onlyAnAddress = string.map { s in
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return !t.contains(where: \.isWhitespace) && URL(string: t)?.scheme != nil
        } ?? true
        if let imageType, !rich, onlyAnAddress {
            if let item = captureImage(pb, imageType, names) { return item }
            if string == nil { return nil }
        }

        guard let string else { return names.contains(NSPasteboard.PasteboardType.string.rawValue) ? refused(pb) : nil }
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let utf8 = Data(string.utf8)
        guard utf8.count <= ClipboardHistory.maxBytes else {
            Log.write("clipboard: left out \(utf8.count / 1024) KB of text (over 4 MB)")
            return nil
        }
        var data: [(NSPasteboard.PasteboardType, Data)] = [(.string, utf8)]
        var total = utf8.count
        for t in [NSPasteboard.PasteboardType.rtf, .html] where names.contains(t.rawValue) {
            if let d = pb.data(forType: t), total + d.count <= ClipboardHistory.maxBytes {
                data.append((t, d)); total += d.count
            }
        }
        return ClipItem(kind: .text(string), data: data, fingerprint: Self.hash(utf8))
    }

    private func captureImage(_ pb: NSPasteboard, _ type: NSPasteboard.PasteboardType, _ names: Set<String>) -> ClipItem? {
        guard let raw = pb.data(forType: type) else { return refused(pb) }
        guard let src = CGImageSourceCreateWithData(raw as CFData, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        var png = raw
        if type != .png {
            let out = NSMutableData()
            guard let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImageFromSource(dst, src, 0, nil)
            guard CGImageDestinationFinalize(dst) else { return nil }
            png = out as Data
        }
        guard png.count <= ClipboardHistory.maxBytes else {
            Log.write("clipboard: left out a \(png.count / 1024) KB image (over 4 MB)")
            return nil
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 640,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let preview = NSImage(cgImage: thumb, size: NSSize(width: CGFloat(thumb.width) / 2, height: CGFloat(thumb.height) / 2))
        var data: [(NSPasteboard.PasteboardType, Data)] = [(.png, png)]
        var total = png.count
        for t in [NSPasteboard.PasteboardType.string, .html, .URL] where names.contains(t.rawValue) {
            if let d = pb.data(forType: t), total + d.count <= ClipboardHistory.maxBytes { data.append((t, d)); total += d.count }
        }
        return ClipItem(kind: .image(preview, pixels: CGSize(width: w, height: h)), data: data, fingerprint: Self.hash(png))
    }

    /// The types were readable but the content wasn't: macOS refused the read (paste permission set to deny).
    private func refused(_ pb: NSPasteboard) -> ClipItem? {
        if !refusedLogged {
            refusedLogged = true
            Log.write("clipboard: macOS refused reading the pasteboard (paste access \(pb.accessBehavior.rawValue)); "
                      + "allow Fenestra under Privacy & Security")
        }
        return nil
    }

    private static func hash(_ d: Data) -> String {
        SHA256.hash(data: d).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
