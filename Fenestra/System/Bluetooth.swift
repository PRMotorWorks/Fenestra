import Foundation
import IOBluetooth

// PRIVATE: IOBluetooth exports these power functions without declaring them (blueutil uses them).
// If an OS update removes them, the Bluetooth tile falls back to opening Bluetooth settings.
@_silgen_name("IOBluetoothPreferenceGetControllerPowerState")
private func IOBluetoothPreferenceGetControllerPowerState() -> Int32
@_silgen_name("IOBluetoothPreferenceSetControllerPowerState")
private func IOBluetoothPreferenceSetControllerPowerState(_ state: Int32)

enum Bluetooth {
    struct Device: Identifiable, @unchecked Sendable {
        let id: String           // address
        let name: String
        let connected: Bool
        let symbol: String       // from the device class, like Windows' device icons
        let device: IOBluetoothDevice
    }

    static var isOn: Bool { IOBluetoothPreferenceGetControllerPowerState() != 0 }

    /// Returns false if the state didn't change (permission denied or API gone).
    static func setPower(_ on: Bool) async -> Bool {
        IOBluetoothPreferenceSetControllerPowerState(on ? 1 : 0)
        for _ in 0..<20 {                            // the controller takes a moment
            try? await Task.sleep(for: .milliseconds(100))
            if isOn == on { return true }
        }
        return isOn == on
    }

    static func pairedDevices() -> [Device] {
        let devs = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devs.map {
            Device(id: $0.addressString ?? UUID().uuidString, name: $0.nameOrAddress ?? "Device",
                   connected: $0.isConnected(), symbol: symbol($0), device: $0)
        }
        .sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) }
    }

    private static func symbol(_ d: IOBluetoothDevice) -> String {
        let minor = d.deviceClassMinor
        switch Int(d.deviceClassMajor) {
        case kBluetoothDeviceClassMajorAudio: return "headphones"
        case kBluetoothDeviceClassMajorPeripheral:
            if minor & 0x10 != 0 { return "keyboard" }          // keyboard bit of the peripheral minor class
            if minor & 0x20 != 0 { return "computermouse" }     // pointing device bit
            return "gamecontroller"
        case kBluetoothDeviceClassMajorPhone: return "iphone"
        case kBluetoothDeviceClassMajorComputer: return "laptopcomputer"
        default: return "dot.radiowaves.left.and.right"
        }
    }

    /// Connect: IOBluetooth's asynchronous open on the main thread (its callbacks need the main run loop; the old
    /// synchronous call from a background task did nothing). Returns the IOReturn, 0 = connected.
    @MainActor static func connect(_ d: Device) async -> IOReturn {
        await withCheckedContinuation { cont in
            let waiter = ConnectWaiter(cont)
            let r = d.device.openConnection(waiter, withPageTimeout: 0x3000, authenticationRequired: false)   // ~7.7 s
            if r != kIOReturnSuccess { waiter.finish(r) }
        }
    }

    @MainActor static func disconnect(_ d: Device) -> IOReturn { d.device.closeConnection() }
}

/// Receives IOBluetooth's `connectionComplete:status:` and keeps itself alive until then.
private final class ConnectWaiter: NSObject, @unchecked Sendable {
    private var cont: CheckedContinuation<IOReturn, Never>?
    private var me: ConnectWaiter?
    init(_ c: CheckedContinuation<IOReturn, Never>) { cont = c; super.init(); me = self }
    func finish(_ r: IOReturn) { cont?.resume(returning: r); cont = nil; me = nil }
    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) { finish(status) }
}
