import AppKit

/// Start-up, shutdown and crash-safety plumbing shared with the scripts in Resources.
///
/// The state file tells the watchdog (fenestra-run.sh) how the app ended:
///   running <pid>  -> if the process is gone, it crashed
///   stopped        -> you quit Fenestra: restore Dock and menu bar
///   session-end    -> logout / shutdown: leave settings alone
///   handoff        -> this copy handed over to the login agent
@MainActor
enum Lifecycle {
    static let agentLabel = "local.fenestra.shell"
    static var sessionEnding = false

    static var supportDir: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Fenestra", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var stateFile: URL { supportDir.appendingPathComponent("state") }
    static var agentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    static var launchedFromAgent: Bool { CommandLine.arguments.contains("--from-agent") }

    static func anotherInstanceIsRunning() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains { $0.processIdentifier != me && !$0.isTerminated }
    }

    /// Returns true if the agent exists and was asked to start us; this copy should then exit.
    static func handOffToAgentIfInstalled() -> Bool {
        guard FileManager.default.fileExists(atPath: agentPlist.path) else { return false }
        writeState("handoff")
        let uid = getuid()
        let script = """
        sleep 1
        launchctl enable gui/\(uid)/\(agentLabel)
        launchctl bootstrap gui/\(uid) '\(agentPlist.path)' 2>/dev/null
        launchctl kickstart gui/\(uid)/\(agentLabel)
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try? p.run()   // keeps running after we exit
        return true
    }

    static func writeState(_ s: String) {
        try? s.write(to: stateFile, atomically: true, encoding: .utf8)
    }

    static func markRunning() {
        writeState("running \(ProcessInfo.processInfo.processIdentifier)")
    }

    static func markStopped() {
        writeState(sessionEnding ? "session-end" : "stopped")
    }

    private static var signalSources: [DispatchSourceSignal] = []
    static func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                MainActor.assumeIsolated { markStopped() }
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: Scripts

    /// Copies the bundled scripts to Application Support so restore.sh works even if the app is deleted.
    static func installScripts() {
        let fm = FileManager.default
        for name in ["restore.sh", "apply-defaults.sh", "fenestra-run.sh"] {
            guard let src = Bundle.main.url(forResource: name.replacingOccurrences(of: ".sh", with: ""),
                                            withExtension: "sh") else { continue }
            let dst = supportDir.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        }
    }

    static func applyDefaults() {
        installScripts()
        let script = supportDir.appendingPathComponent("apply-defaults.sh").path
        // Phase 6: the menu bar key follows the "Hide the macOS menu bar" setting; the other groups follow
        // Fenestra tab > macOS changes.
        let hide = UserDefaults.standard.object(forKey: "hideMenuBar") as? Bool ?? true
        let off = (UserDefaults.standard.stringArray(forKey: "macOSChangesOff") ?? []).joined(separator: ",")
        DispatchQueue.global(qos: .utility).async {
            let r = Shell.run("/bin/bash", [script], env: ["FENESTRA_HIDE_MENUBAR": hide ? "1" : "0", "FENESTRA_OFF": off])
            let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { Log.write("defaults: \(out)") }
        }
    }

    /// Quit Fenestra the normal way: the watchdog then restores the Dock and menu bar.
    static func quitAndRestore() {
        if !launchedFromAgent {
            // Not supervised: restore ourselves.
            _ = Shell.run("/bin/bash", [supportDir.appendingPathComponent("restore.sh").path, "--soft"])
        }
        NSApp.terminate(nil)
    }
}

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String], env: [String: String] = [:]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if !env.isEmpty {
            p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
