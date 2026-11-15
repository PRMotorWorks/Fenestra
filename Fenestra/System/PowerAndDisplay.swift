import AppKit

/// Night light = macOS Night Shift through CBBlueLightClient (PRIVATE CoreBrightness framework,
/// the same class apps like Shifty use). Falls back to Displays settings if the class is missing.
@MainActor
final class NightShift {
    static let shared = NightShift()
    private var client: NSObject?

    private init() {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        if let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type { client = cls.init() }
    }

    var isAvailable: Bool { client != nil }

    var isOn: Bool {
        guard let c = client else { return false }
        let sel = NSSelectorFromString("getBlueLightStatus:")
        guard c.responds(to: sel) else { return false }
        typealias Fn = @convention(c) (NSObject, Selector, UnsafeMutableRawPointer) -> Bool
        let fn = unsafeBitCast(c.method(for: sel), to: Fn.self)
        // struct { BOOL active; BOOL enabled; BOOL sunSchedulePermitted; int mode; ... }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        defer { buf.deallocate() }
        buf.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        _ = fn(c, sel, buf)
        return buf.load(fromByteOffset: 1, as: Bool.self)
    }

    func set(_ on: Bool) {
        guard let c = client else { return }
        let sel = NSSelectorFromString("setEnabled:")
        guard c.responds(to: sel) else { return }
        typealias Fn = @convention(c) (NSObject, Selector, Bool) -> Bool
        let fn = unsafeBitCast(c.method(for: sel), to: Fn.self)
        _ = fn(c, sel, on)
    }
}

/// Battery saver = Low Power Mode. Reading is public; switching needs `pmset` as root.
/// Fenestra asks once for your admin password to install a sudoers rule that allows exactly
/// `pmset -a lowpowermode 0|1` without a password (file /etc/sudoers.d/fenestra, removed by restore.sh --uninstall).
enum LowPower {
    static var isOn: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
    static var permissionInstalled: Bool { FileManager.default.fileExists(atPath: "/etc/sudoers.d/fenestra") }

    static func set(_ on: Bool) -> Bool {
        Shell.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "lowpowermode", on ? "1" : "0"]).status == 0
    }

    /// Shows the macOS admin password prompt. Returns true if the rule is now installed.
    @MainActor
    static func installPermission() -> Bool {
        let user = NSUserName().filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
        let cmd = "F=$(/usr/bin/mktemp) && /usr/bin/printf '%s ALL=(root) NOPASSWD: /usr/bin/pmset -a lowpowermode 0, /usr/bin/pmset -a lowpowermode 1\\n' '\(user)' > \"$F\" && /usr/sbin/visudo -cf \"$F\" && /usr/bin/install -m 0440 -o root -g wheel \"$F\" /etc/sudoers.d/fenestra; /bin/rm -f \"$F\""
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges " +
                                   "with prompt \"Fenestra needs your permission once to switch Low Power Mode (Battery saver).\"")
        var err: NSDictionary?
        script?.executeAndReturnError(&err)
        return permissionInstalled
    }
}

/// Focus has no public on/off API. Fenestra runs two Shortcuts ("Fenestra Focus On" / "Fenestra Focus Off", each a
/// single Set Focus action for Do Not Disturb). It builds them itself and hands them to Shortcuts, which asks you
/// once per shortcut to add it (macOS lets no app add shortcuts silently).
enum FocusControl {
    static let onName = "Fenestra Focus On"
    static let offName = "Fenestra Focus Off"

    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: "focusOn") }
        set { UserDefaults.standard.set(newValue, forKey: "focusOn") }
    }

    static func installedNames() async -> Set<String> {
        await Task.detached {
            let out = Shell.run("/usr/bin/shortcuts", ["list"]).output
            return Set(out.split(separator: "\n").map { String($0) }).intersection([onName, offName])
        }.value
    }

    static func shortcutsInstalled() async -> Bool { await installedNames().count == 2 }

    static func set(_ on: Bool) async -> Bool {
        let ok = await Task.detached {
            Shell.run("/usr/bin/shortcuts", ["run", on ? onName : offName]).status == 0
        }.value
        if ok { isOn = on }
        return ok
    }

    /// Do Not Disturb's name in the Mac's language. Set Focus finds the Focus by this name, not by its identifier:
    /// "Do Not Disturb" on a Romanian Mac failed with "no such Focus" (2026-11-15); there it is "Nu deranjați".
    static func modeName() -> String {
        let english = "Do Not Disturb"
        let path = "/System/Library/PrivateFrameworks/DoNotDisturb.framework/Resources/Localizable.loctable"
        guard let data = FileManager.default.contents(atPath: path),
              let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]]
        else { return english }
        let lang = Bundle.preferredLocalizations(from: Array(table.keys), forPreferences: Locale.preferredLanguages).first
        return lang.flatMap { table[$0]?["MODE_NAME_DEFAULT"] as? String } ?? english
    }

    /// Writes the shortcut (a Set Focus action: Do Not Disturb on until turned off, or off) and signs it with
    /// `shortcuts sign`, since Shortcuts refuses unsigned files. Returns the signed file.
    static func build(_ name: String) -> URL? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Fenestra/Shortcuts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let action: [String: Any] = [
            "WFWorkflowActionIdentifier": "is.workflow.actions.dnd.set",
            "WFWorkflowActionParameters": [
                "Enabled": name == onName ? 1 : 0,
                "AssertionType": "Turned Off",
                "FocusModes": ["DisplayString": modeName(), "Identifier": "com.apple.donotdisturb.mode.default"],
            ] as [String: Any],
        ]
        let workflow: [String: Any] = [
            "WFWorkflowActions": [action],
            "WFWorkflowClientVersion": "3218.0.4.100",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 4_282_601_983, "WFWorkflowIconGlyphNumber": 59511],
            "WFWorkflowTypes": [String](), "WFWorkflowInputContentItemClasses": [String](),
            "WFWorkflowOutputContentItemClasses": [String](), "WFWorkflowImportQuestions": [String](),
            "WFQuickActionSurfaces": [String](), "WFWorkflowHasShortcutInputVariables": false,
        ]
        let raw = dir.appendingPathComponent("\(name).unsigned.shortcut")
        let signed = dir.appendingPathComponent("\(name).shortcut")
        guard let data = try? PropertyListSerialization.data(fromPropertyList: workflow, format: .binary, options: 0),
              (try? data.write(to: raw)) != nil else { return nil }
        try? FileManager.default.removeItem(at: signed)
        let r = Shell.run("/usr/bin/shortcuts", ["sign", "--mode", "people-who-know-me",
                                                 "--input", raw.path, "--output", signed.path])
        try? FileManager.default.removeItem(at: raw)
        Log.write("focus: built \(name) (sign status \(r.status))")
        return r.status == 0 ? signed : nil
    }
}