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
        try? (s + "\n").write(to: stateFile, atomically: true, encoding: .utf8)
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
                MainActor.assumeIsolated { MenuBarBlocker.shared.stop(); markStopped() }
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: Installing from the disk image (no Xcode needed)

    /// Running from the disk image, or from Downloads through macOS's App Translocation, instead of Applications.
    static func needsMoveToApplications() -> Bool {
        let path = Bundle.main.bundlePath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return !(path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/"))
    }

    static func askToMoveToApplications() {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Move Fenestra to Applications"
        a.informativeText = "Drag Fenestra into the Applications folder (the disk image shows both), then open it "
            + "from there. Fenestra starts itself at every login from Applications."
        a.addButton(withTitle: "Open Applications")
        a.addButton(withTitle: "Quit")
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
        }
    }

    /// Writes the login agent that runs the watchdog (fenestra-run.sh) at every login, like install.sh does.
    static func installAgent() {
        installScripts()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let run = supportDir.appendingPathComponent("fenestra-run.sh").path
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(agentLabel)</string>
          <key>AssociatedBundleIdentifiers</key><array><string>local.fenestra.Fenestra</string></array>
          <key>ProgramArguments</key>
          <array>
            <string>/bin/bash</string>
            <string>\(run)</string>
          </array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
          <key>ThrottleInterval</key><integer>5</integer>
          <key>LimitLoadToSessionType</key><string>Aqua</string>
          <key>ProcessType</key><string>Interactive</string>
          <key>StandardOutPath</key><string>\(home)/Library/Logs/Fenestra.log</string>
          <key>StandardErrorPath</key><string>\(home)/Library/Logs/Fenestra.log</string>
        </dict>
        </plist>

        """
        let fm = FileManager.default
        try? fm.createDirectory(at: agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: home + "/Library/Logs", withIntermediateDirectories: true)
        do {
            try plist.write(to: agentPlist, atomically: true, encoding: .utf8)
            Log.write("setup: login agent installed (first launch from \((Bundle.main.bundlePath as NSString).abbreviatingWithTildeInPath))")
        } catch {
            Log.write("setup: could not write the login agent: \(error.localizedDescription)")
        }
    }

    /// Settings > Fenestra > Uninstall: restores every macOS setting, then removes the app, login agent and data
    /// (restore.sh --uninstall). Runs detached, since stopping the agent ends this process.
    static func uninstall() {
        installScripts()
        // Wi-Fi password copies live in your login keychain; Fenestra made them, so it can remove them silently.
        let removed = WiFi.deleteAllCopies()
        Log.write("uninstall: removed \(removed) Wi-Fi password copies")
        // The Battery saver permission is a root-owned file: remove it here, where macOS can ask for the password.
        if FileManager.default.fileExists(atPath: "/etc/sudoers.d/fenestra") {
            NSAppleScript(source: "do shell script \"/bin/rm -f /etc/sudoers.d/fenestra\" with administrator privileges "
                          + "with prompt \"Fenestra is removing its Battery saver permission.\"")?.executeAndReturnError(nil)
        }
        let script = supportDir.appendingPathComponent("restore.sh").path
        let log = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Logs/Fenestra-uninstall.log"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "nohup /bin/bash '\(script)' --uninstall > '\(log)' 2>&1 &"]
        try? p.run()
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
            DispatchQueue.main.async {
                Log.write("defaults: \(out)")
                MainActor.assumeIsolated {
                    CaptionController.refreshMenuBarHidden()
                    MenuBarBlocker.shared.update(reason: "defaults applied")
                    Log.write("workarea: menu bar \(CaptionController.menuBarHidden ? "hidden" : "shown"), "
                              + "top of main work area y=\(Int(CaptionController.workArea(screen: NSScreen.screens[0]).minY)), "
                              + "AppKit menu bar inset \(Int(NSScreen.screens[0].frame.maxY - NSScreen.screens[0].visibleFrame.maxY))")
                }
            }
        }
    }

    /// Whether the login agent (watchdog) is loaded. Switching Fenestra off in System Settings > Login Items
    /// unloads it but leaves the app running (tested 2026-11-15), so nothing would restore the Mac afterward.
    static func agentLoaded() -> Bool {
        Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/\(agentLabel)"]).status == 0
    }

    /// Restores the Mac's settings now when no watchdog will (login item switched off, or started from Xcode).
    static func restoreIfUnsupervised(reason: String) {
        guard !agentLoaded() else { return }
        Log.write("lifecycle: login item is off, restoring macOS settings (\(reason))")
        _ = Shell.run("/bin/bash", [supportDir.appendingPathComponent("restore.sh").path, "--soft"])
    }

    /// Quit Fenestra the normal way: the watchdog then restores the Dock and menu bar.
    static func quitAndRestore() {
        if !launchedFromAgent || !agentLoaded() {
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
