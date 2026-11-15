import AppKit
import CoreImage
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Diagnostics only (`captionDragTrace` on): while a followed title bar drag runs, captures the composited
/// display at its frame rate and counts traffic-light pixels around where the lights would be, per frame.
/// A frame with lights is classed by the side they show on: the side the window moves away from means the
/// panel was drawn ahead of the window, the other side behind it. Summary per drag in the app log; the first
/// frames with lights are saved to ~/Library/Logs/Fenestra-dragtest/frame-*.png (260 x 140 pt crops).
/// (A capture of only the window and panel is not representative: it doesn't show what the display drew.)
final class DragCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    static let shared = DragCapture()

    private let lock = NSLock()
    private var panel = CGPoint.zero            // latest window origin the panel was put at (AX)
    private var moves: [(t: Double, x: CGFloat)] = []
    private var region = CGRect.zero            // captured area (AX) = the display
    private var lights = CGRect.zero
    private var stream: SCStream?
    private var frames = 0, lit = 0, saved = 0, ahead = 0, behind = 0, still = 0
    private let queue = DispatchQueue(label: "fenestra.dragcapture")
    private let ci = CIContext()
    private static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Fenestra-dragtest")

    func setPanel(_ p: CGPoint) {
        lock.lock()
        panel = p
        moves.append((CFAbsoluteTimeGetCurrent(), p.x))
        if moves.count > 8 { moves.removeFirst() }
        lock.unlock()
    }

    @MainActor func start(at p: CGPoint, lights l: CGRect) {
        stop()
        setPanel(p)
        Task { @MainActor in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: p.x + 5, y: p.y + 5)) })
            else { return }
            let cfg = SCStreamConfiguration()
            let r = display.frame
            cfg.sourceRect = CGRect(origin: .zero, size: r.size)
            cfg.width = Int(r.width)
            cfg.height = Int(r.height)
            cfg.showsCursor = false
            cfg.queueDepth = 8
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 240)
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: nil)
            try? s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            lock.lock()
            region = r; lights = l
            frames = 0; lit = 0; saved = 0; ahead = 0; behind = 0; still = 0; stream = s
            lock.unlock()
            try? await s.startCapture()
        }
    }

    @MainActor func stop() {
        lock.lock()
        let s = stream
        stream = nil
        let summary = frames > 0
            ? "dragcapture: \(frames) frames, \(lit) with traffic lights (panel ahead \(ahead), behind \(behind), pointer still \(still))"
            : nil
        lock.unlock()
        if let s { Task { try? await s.stopCapture() } }
        if let summary { Log.write(summary) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = sb.imageBuffer,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              (atts.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)) == .complete else { return }
        lock.lock()
        let p = panel, reg = region, l = lights, mv = moves
        lock.unlock()
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let bpr = CVPixelBufferGetBytesPerRow(pb), w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let s = CGFloat(w) / reg.width
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        // Traffic-light colored pixels within ~20 pt of where the lights are if the window is where the panel is.
        var n = 0, sumX: CGFloat = 0
        var y = p.y + l.minY - 14
        while y < p.y + l.maxY + 14 {
            var x = p.x + l.minX - 24
            while x < p.x + l.maxX + 24 {
                let ix = Int(((x - reg.minX) * s).rounded(.down)), iy = Int(((y - reg.minY) * s).rounded(.down))
                if ix >= 0, iy >= 0, ix < w, iy < h {
                    let i = iy * bpr + ix * 4
                    let b = Int(ptr[i]), g = Int(ptr[i + 1]), r = Int(ptr[i + 2])
                    if (r > 200 && g < 120 && b < 110) || (r > 210 && g > 160 && b < 90) || (g > 170 && r < 130 && b < 120) {
                        n += 1
                        sumX += x - p.x - l.midX
                    }
                }
                x += 1 / s
            }
            y += 1 / s
        }
        var vx: CGFloat = 0
        if mv.count >= 3, let a = mv.first, let b = mv.last, b.t - a.t > 0.004 { vx = (b.x - a.x) / CGFloat(b.t - a.t) }
        lock.lock()
        frames += 1
        let k = frames
        var save = false
        if n > 20 {
            lit += 1
            // Lights showing on the side the window moves away from: the panel is drawn ahead of it.
            if abs(vx) > 100 { if (sumX < 0) == (vx > 0) { ahead += 1 } else { behind += 1 } } else { still += 1 }
            if saved < 6 { saved += 1; save = true }
        }
        lock.unlock()
        if save, let img = ci.createCGImage(CIImage(cvPixelBuffer: pb),
                                            from: CGRect(x: (p.x - reg.minX - 60) * s, y: CGFloat(h) - (p.y - reg.minY + 100) * s,
                                                         width: 260 * s, height: 140 * s)) {
            try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
            let url = Self.dir.appendingPathComponent("frame-\(Int(Date().timeIntervalSince1970 * 1000) % 100000)-\(k).png")
            if let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(d, img, nil)
                CGImageDestinationFinalize(d)
            }
        }
    }
}
