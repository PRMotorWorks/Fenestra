import AppKit
import IOKit

// PRIVATE (IOKit, Apple silicon): DDC/CI over the display's AV service, the approach MonitorControl uses.
@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ dataAddress: UInt32,
                                 _ inputBuffer: UnsafeMutableRawPointer, _ inputBufferSize: UInt32) -> IOReturn

/// One brightness slider for all displays, like Windows' Quick Settings:
///  - built-in screen: DisplayServices (PRIVATE framework, loaded at runtime)
///  - external monitors: DDC/CI (PRIVATE IOKit). Works when the monitor and cable support DDC;
///    many USB-C docks and some portable monitors don't.
@MainActor
final class Brightness {
    static let shared = Brightness()

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private var getFn: GetFn?
    private var setFn: SetFn?
    private var ddcServices: [CFTypeRef] = []
    private let ddcQueue = DispatchQueue(label: "fenestra.ddc")
    private var pendingDDC: Int?

    private init() {
        if let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) {
            if let g = dlsym(h, "DisplayServicesGetBrightness") { getFn = unsafeBitCast(g, to: GetFn.self) }
            if let s = dlsym(h, "DisplayServicesSetBrightness") { setFn = unsafeBitCast(s, to: SetFn.self) }
        }
        refreshDisplays()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Brightness.shared.refreshDisplays() }
        }
    }

    private var builtinID: CGDirectDisplayID? {
        NSScreen.screens.compactMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
            .first { CGDisplayIsBuiltin($0) != 0 }
    }

    var isAvailable: Bool { (builtinID != nil && setFn != nil) || !ddcServices.isEmpty }

    func refreshDisplays() {
        ddcServices = []
        var iter = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iter) }
        while case let s = IOIteratorNext(iter), s != 0 {
            defer { IOObjectRelease(s) }
            let loc = IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard loc == "External", let svc = IOAVServiceCreateWithService(kCFAllocatorDefault, s)?.takeRetainedValue()
            else { continue }
            ddcServices.append(svc)
        }
    }

    /// 0...1. External monitors can't be read back cheaply, so the last value set is remembered.
    var value: Float {
        if let id = builtinID, let g = getFn {
            var v: Float = 0
            if g(id, &v) == 0 { return v }
        }
        return UserDefaults.standard.object(forKey: "externalBrightness") as? Float ?? 0.5
    }

    func set(_ v: Float) {
        let v = min(max(v, 0), 1)
        if let id = builtinID, let s = setFn { _ = s(id, v) }
        guard !ddcServices.isEmpty else { return }
        UserDefaults.standard.set(v, forKey: "externalBrightness")
        // Coalesce: the slider fires faster than monitors accept DDC writes.
        let firstPending = pendingDDC == nil
        pendingDDC = Int(v * 100)
        guard firstPending else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            MainActor.assumeIsolated {
                let b = Brightness.shared
                guard let value = b.pendingDDC else { return }
                b.pendingDDC = nil
                let services = b.ddcServices
                b.ddcQueue.async { for svc in services { Self.writeVCP(svc, code: 0x10, value: value) } }
            }
        }
    }

    /// DDC/CI "Set VCP Feature": 0x51 source, length, 0x03 opcode, code, value hi/lo, checksum.
    nonisolated private static func writeVCP(_ svc: CFTypeRef, code: UInt8, value: Int) {
        var data: [UInt8] = [0x84, 0x03, code, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF), 0]
        var chk: UInt8 = 0x6E ^ 0x51
        for i in 0..<5 { chk ^= data[i] }
        data[5] = chk
        for _ in 0..<2 {                       // many monitors drop the first write
            _ = IOAVServiceWriteI2C(svc, 0x37, 0x51, &data, UInt32(data.count))
            usleep(10_000)
        }
    }
}
