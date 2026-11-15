import Foundation
import CoreWLAN

/// Wi-Fi through CoreWLAN (public). The network name needs Location permission (macOS 14+ rule).
final class WiFi: NSObject, CWEventDelegate, @unchecked Sendable {
    static let shared = WiFi()
    private let client = CWWiFiClient.shared()
    var onChange: (() -> Void)?

    private var iface: CWInterface? { client.interface() }
    var isAvailable: Bool { iface != nil }
    var isOn: Bool { iface?.powerOn() ?? false }
    var ssid: String? { iface?.ssid() }
    var rssi: Int { iface?.rssiValue() ?? -100 }
    var isConnected: Bool { (iface?.wlanChannel()) != nil && isOn && (iface?.transmitRate() ?? 0) > 0 }

    /// 0...3 bars, like the Windows icon.
    var bars: Int {
        let r = rssi
        if r >= -55 { return 3 }
        if r >= -67 { return 2 }
        if r >= -80 { return 1 }
        return 0
    }

    func startMonitoring() {
        client.delegate = self
        for e in [CWEventType.powerDidChange, .ssidDidChange, .linkDidChange, .linkQualityDidChange] {
            try? client.startMonitoringEvent(with: e)
        }
    }

    func setPower(_ on: Bool) throws { try iface?.setPower(on) }

    /// The last scan macOS itself made (no radio work, instant): shown while a fresh scan runs.
    func cachedNetworks() -> [CWNetwork] { Self.strongest(iface?.cachedScanResults() ?? []) }

    /// Scanning blocks for ~2 seconds, so it runs off the main thread.
    func scan() async -> [CWNetwork] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: Self.strongest((try? self.iface?.scanForNetworks(withName: nil)) ?? []))
            }
        }
    }

    /// Keep the strongest entry per network name, strongest first.
    private static func strongest(_ nets: Set<CWNetwork>) -> [CWNetwork] {
        var best: [String: CWNetwork] = [:]
        for n in nets {
            guard let name = n.ssid, !name.isEmpty else { continue }
            if let b = best[name], b.rssiValue >= n.rssiValue { continue }
            best[name] = n
        }
        return best.values.sorted { $0.rssiValue > $1.rssiValue }
    }

    func connect(_ network: CWNetwork, password: String?) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try self.iface?.associate(to: network, password: password); cont.resume() }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    func disconnect() { iface?.disassociate() }

    /// Networks macOS remembers (System Settings > Wi-Fi > Known Networks).
    func knownSSIDs() -> Set<String> {
        Set((iface?.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []).compactMap(\.ssid))
    }

    /// Joins a remembered network with the password macOS saved. That one lives in the System keychain, and macOS
    /// asks for your Mac password every time an app reads it ("Always Allow" doesn't stick there). So after the
    /// first join Fenestra keeps a copy in your login keychain (item "Fenestra Wi-Fi", readable by Fenestra without
    /// a prompt) and uses that; a copy that no longer works is deleted and the System keychain asked again.
    /// Blocks while the macOS dialog is open: call it off the main thread. The password is never logged.
    func joinSaved(_ network: CWNetwork) -> String {
        guard let data = network.ssidData, let ssid = network.ssid else { return "no SSID" }
        if let copy = Self.ownCopy(ssid) {
            if (try? iface?.associate(to: network, password: copy)) != nil { return "joined (Fenestra copy)" }
            Self.deleteCopy(ssid)
        }
        var pw: NSString?
        var status = CWKeychainFindWiFiPassword(.system, data, &pw)
        if status != errSecSuccess || pw == nil { status = CWKeychainFindWiFiPassword(.user, data, &pw) }
        guard status == errSecSuccess, let pw else { return "keychain \(status)" }
        do {
            try iface?.associate(to: network, password: pw as String)
            Self.saveCopy(ssid, pw as String)
            return "joined (System keychain, copy saved)"
        } catch { return "associate failed \((error as NSError).code)" }
    }

    private static let service = "Fenestra Wi-Fi"
    private static func query(_ ssid: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: ssid]
    }
    private static func ownCopy(_ ssid: String) -> String? {
        var q = query(ssid)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    private static func saveCopy(_ ssid: String, _ password: String) {
        deleteCopy(ssid)
        var q = query(ssid)
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrLabel as String] = "\(service): \(ssid)"
        SecItemAdd(q as CFDictionary, nil)
    }
    private static func deleteCopy(_ ssid: String) { SecItemDelete(query(ssid) as CFDictionary) }

    // CWEventDelegate (called on a CoreWLAN thread)
    private func changed() { DispatchQueue.main.async { self.onChange?() } }
    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { changed() }
    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { changed() }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { changed() }
    func linkQualityDidChangeForWiFiInterface(withName interfaceName: String, rssi: Int, transmitRate: Double) { changed() }
}

extension CWNetwork {
    var isSecured: Bool { !supportsSecurity(.none) }
    var bars: Int {
        if rssiValue >= -55 { return 3 }
        if rssiValue >= -67 { return 2 }
        if rssiValue >= -80 { return 1 }
        return 0
    }
}

