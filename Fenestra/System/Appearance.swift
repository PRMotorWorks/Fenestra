import AppKit

/// Light/dark mode (Control Center's Dark Mode control).
enum Appearance {
    @MainActor static var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    // PRIVATE: SkyLight's `SLSSetAppearanceThemeLegacy(bool)`, what System Settings uses. Looked up at run time:
    // if an update removes it, AppleScript (System Events, asks for Automation permission once) does it instead.
    private typealias SetTheme = @convention(c) (Bool) -> Void
    private static let setTheme: SetTheme? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let sym = dlsym(h, "SLSSetAppearanceThemeLegacy") else { return nil }
        return unsafeBitCast(sym, to: SetTheme.self)
    }()

    static func set(dark: Bool) {
        if let setTheme {
            setTheme(dark)
            Log.write("quicksettings: dark mode \(dark) (SkyLight)")
        } else {
            Shell.run("/usr/bin/osascript", ["-e",
                "tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark)"])
            Log.write("quicksettings: dark mode \(dark) (System Events)")
        }
    }
}
