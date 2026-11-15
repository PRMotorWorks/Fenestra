import AppKit
import SwiftUI
import CoreLocation
import CoreBluetooth
import ApplicationServices

/// Tracks the macOS permissions Fenestra needs and explains each one.
@MainActor
final class Permissions: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = Permissions()

    @Published private(set) var accessibility = AXIsProcessTrusted()
    @Published private(set) var screenRecording = CGPreflightScreenCaptureAccess()
    @Published private(set) var location: CLAuthorizationStatus = .notDetermined
    @Published private(set) var bluetooth: CBManagerAuthorization = CBCentralManager.authorization

    private let locationManager = CLLocationManager()
    private var btManager: CBCentralManager?
    private var timer: Timer?

    override init() {
        super.init()
        locationManager.delegate = self
        location = locationManager.authorizationStatus
    }

    var allEssentialGranted: Bool { accessibility && screenRecording }

    func refresh() {
        let wasAX = accessibility
        accessibility = AXIsProcessTrusted()
        screenRecording = CGPreflightScreenCaptureAccess()
        location = locationManager.authorizationStatus
        bluetooth = CBCentralManager.authorization
        if accessibility && !wasAX {
            Log.write("accessibility granted")
            AppDelegate.startAccessibilityFeatures()
        }
    }

    /// Poll only while the permissions window is open (macOS has no change notification for these).
    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { Permissions.shared.refresh() }
        }
    }
    func stopPolling() { timer?.invalidate(); timer = nil }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        SystemActions.openSettings("com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
    }
    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            SystemActions.openSettings("com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")
        }
    }
    func requestLocation() {
        if location == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else {
            SystemActions.openSettings("com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices")
        }
    }
    func requestBluetooth() {
        if bluetooth == .notDetermined {
            btManager = CBCentralManager(delegate: nil, queue: nil)   // triggers the prompt
        } else {
            SystemActions.openSettings("com.apple.settings.PrivacySecurity.extension?Privacy_Bluetooth")
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in Permissions.shared.refresh() }
    }
}

struct PermissionsView: View {
    @ObservedObject var p = Permissions.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fenestra needs a few permissions").font(.title2.bold())
            Text("Each one is optional. Without it, only the feature listed stops working. You can change these any time in System Settings > Privacy & Security.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            row("Accessibility", "hand.raised", p.accessibility,
                "Lets the taskbar bring windows forward, minimize and restore them, open a new window on middle-click, and keep maximized windows above the taskbar.",
                action: p.requestAccessibility)
            row("Screen & System Audio Recording", "rectangle.dashed.badge.record", p.screenRecording,
                "Used only for the window thumbnails when you hover over a taskbar icon. Nothing is recorded or saved. macOS may ask you to confirm this again from time to time.",
                action: p.requestScreenRecording)
            row("Location", "location", p.location == .authorizedAlways,
                "macOS hides the Wi-Fi network name from apps without Location access. Fenestra never reads your location.",
                action: p.requestLocation)
            row("Bluetooth", "dot.radiowaves.left.and.right", p.bluetooth == .allowedAlways,
                "Lets Quick Settings turn Bluetooth on and off and list your devices.",
                action: p.requestBluetooth)

            Text("Later phases will also ask for Input Monitoring (Windows key shortcuts).")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { PermissionsWindow.close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { p.startPolling() }
        .onDisappear { p.stopPolling() }
    }

    private func row(_ title: String, _ icon: String, _ granted: Bool, _ why: String,
                     action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title2).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else {
                Button("Allow…", action: action)
            }
        }
    }
}

@MainActor
enum PermissionsWindow {
    private static var window: NSWindow?
    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: PermissionsView()))
            w.title = "Fenestra Permissions"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
    static func close() { window?.close() }
}
