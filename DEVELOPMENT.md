# Fenestra: development notes

For installing Fenestra, see [README.md](README.md) and [INSTALL.md](INSTALL.md). This file is for building and
changing it: permissions, every macOS change, APIs per feature, test checklists, known differences from Windows 11.

A Windows 11 (25H2) style desktop shell for macOS Tahoe 26, built as one native AppKit/SwiftUI app.
For personal use. SIP stays on. No Microsoft icons, fonts or wallpapers are included; glyphs are
SF Symbols and the system font (Segoe UI Variable is used automatically if you install it yourself).

Status: **Phase 1 (taskbar, tray, Quick Settings)**, **Phase 2 (Start menu)**, **Phase 3 (Windows caption buttons,
Snap Layouts)**, **Phase 4 (snapping, Snap Assist, Alt+Tab, Task View)**, **Phase 5 (multiple displays: taskbar on
every display, window locations remembered per display)** and **Phase 6 (menu bar migration: hidden menu bar, menu
bar icons in the tray, app menus from each window)** are done, plus **clipboard history with images
(Control+Option+V)**, the one extra beyond Windows parity chosen in Phase 0.

---

## Emergency: get your Mac back

| What | Command |
|---|---|
| Stop Fenestra, restore Dock, menu bar and all defaults | `~/Documents/Fenestra/restore.sh` |
| Same, if this folder is gone | `~/Library/Application\ Support/Fenestra/restore.sh` |
| PANIC uninstall (restore, then delete app, login agent, data) | `~/Library/Application\ Support/Fenestra/restore.sh --uninstall` |
| Can't reach Terminal at all | Restart and hold **Shift** at the login window: login items don't start. Then run the restore command. |

If Fenestra crashes, the watchdog restores the Dock and menu bar at once and restarts it.
After 3 crashes within 2 minutes it turns Fenestra off and shows a notification.

## Build, install, run

Requires Xcode 27.2 (macOS 27.2 SDK; deployment target macOS 26.0).

```bash
cd ~/Documents/Fenestra
./install.sh          # builds Release, installs ~/Applications/Fenestra.app, starts it, and at every login
```

- Re-run `./install.sh` after any code change.
- Open `Fenestra.xcodeproj` in Xcode to edit. Running from Xcode works too (it isn't supervised by the watchdog then).
- To start it again after `restore.sh`: open `~/Applications/Fenestra.app`.
- Logs: `~/Library/Logs/Fenestra.log`.
- Signing (`Config/Signing.xcconfig`): ad-hoc by default, so it builds on any Mac, but macOS asks for the
  permissions again after each rebuild. To sign with your Apple Development certificate so permissions survive
  rebuilds, `cp Config/Local.xcconfig.example Config/Local.xcconfig` and put your team ID in it (the file is
  gitignored). macOS may then ask once whether `codesign` may use the key: choose **Always Allow**.

### Installing on another Mac (no Xcode)

```bash
./package.sh          # builds dist/Fenestra-<version>.dmg (app + Applications shortcut + install guide)
```

Copy the disk image to the other Mac and follow [INSTALL.md](INSTALL.md) (also inside the image as
"How to install Fenestra.txt"). On first launch from Applications, Fenestra writes its own login agent and copies
its scripts (what `install.sh` does), then restarts under the watchdog. Opened from the disk image or Downloads it
asks to be moved to Applications. Settings > Fenestra > Uninstall… runs `restore.sh --uninstall`.

Signing: `package.sh` signs with hardened runtime and `Config/Fenestra-dist.entitlements` (Apple events). Without a
Developer ID it signs ad-hoc (no identity in the signature; the Apple Development certificate would put your Apple ID
email in it): the other Mac needs System Settings > Privacy & Security > **Open Anyway** once, and permissions again
after each update.
With a **Developer ID Application** certificate (paid Apple Developer Program) it signs with that instead, and
notarizes and staples when a notarytool profile exists (`xcrun notarytool store-credentials fenestra-notary`):
the image then opens with no warning on any Mac.

### How it runs (crash safety)

`~/Library/LaunchAgents/local.fenestra.shell.plist` runs `fenestra-run.sh` (the watchdog) at login.
The watchdog launches the app through LaunchServices (`open -W`) and waits, using no CPU.
The app writes `~/Library/Application Support/Fenestra/state` so the watchdog knows how it ended:

| App ended because | Watchdog does |
|---|---|
| You quit Fenestra | restores Dock and menu bar, stays stopped |
| Logout or shutdown | nothing (settings stay for the next login) |
| Crash or force-kill | restores Dock and menu bar immediately; launchd restarts Fenestra |
| 3 crashes in 2 minutes | restores, disables the agent, notifies you |

## Permissions

| Permission | Used for | Without it |
|---|---|---|
| Accessibility | minimize/restore from the taskbar, bringing windows forward, middle-click new window, per-window taskbar buttons, unread badges, capturing notifications for the bell, keeping maximized windows above the taskbar, tap-Command for Start, Windows caption buttons and Snap Layouts, snapping, Snap Assist, Alt+Tab, Task View and the Control+Option shortcuts, putting windows back when a display reconnects, taskbar buttons per display, menu bar icons in the tray, app menus from the menu button / Option tap / right-click, clipboard history (Control+Option+V, opening at the text cursor, pasting into the front app) | clicking an icon hides/shows the whole app instead of minimizing; no badges, notifications or Command shortcut |
| Screen & System Audio Recording | hover thumbnails, Alt+Tab, Task View and Snap Assist thumbnails, and matching the caption buttons' background to each title bar (ScreenCaptureKit, single still frames). Nothing is recorded. macOS may re-confirm it from time to time | thumbnails show the app icon instead |
| Location | macOS hides the Wi-Fi network name from apps without it. Location itself is never read | Wi-Fi shows without a name |
| Bluetooth | Quick Settings Bluetooth toggle and device list | Bluetooth tile opens Bluetooth settings |
| Administrator (once, optional) | Battery saver: installs `/etc/sudoers.d/fenestra`, allowing only `pmset -a lowpowermode 0/1` without a password | Battery saver tile opens Battery settings |
| Automation: loginwindow / System Events | Start's Restart, Shut down, Sign out (macOS may ask once) | use the Apple menu |
| Pasteboard access (macOS 15.4 and later) | clipboard history reads what you copy in other apps. macOS may ask once ("paste from other apps"); choose Allow. The app log says which setting is in effect at start (`clipboard: watching (... paste access: ...)`; currently "always allow") | the history stays empty (logged once: `clipboard: macOS refused reading the pasteboard`) |
| Input Monitoring | not needed: the Phase 4 shortcuts use an event tap, which Accessibility already allows | n/a |

The first-run window explains each one. Reopen it from the taskbar's right-click menu > Permissions.

## Every system change Fenestra makes

All `defaults` keys are written by `apply-defaults.sh` at every start. Before a key is first changed,
its original value is saved to `~/Library/Application Support/Fenestra/defaults-backup.txt`, and
`restore.sh` writes those originals back (or deletes the key if it didn't exist).

Each group of keys has a switch in Settings > Fenestra > macOS changes (Dock, Finder, title bar double-click,
macOS tiling, wallpaper click, minimize effect; the menu bar is Windows > "Hide the macOS menu bar"). Switching a
group off writes your backed-up originals back for that group only (`FENESTRA_OFF` in `apply-defaults.sh`).

| Domain | Key | Value | Why | Restore by hand |
|---|---|---|---|---|
| com.apple.dock | autohide | true | hide the Dock (it keeps running: it also powers Cmd+Tab, Mission Control and minimizing) | `defaults delete com.apple.dock autohide` |
| com.apple.dock | autohide-delay | 1000 | it never slides in when the cursor hits the edge | `defaults delete com.apple.dock autohide-delay` |
| com.apple.dock | autohide-time-modifier | 0 | no animation if it is ever shown | `defaults delete com.apple.dock autohide-time-modifier` |
| com.apple.dock | minimize-to-application | true | minimized windows don't pile up in the hidden Dock | `defaults write com.apple.dock minimize-to-application -bool false` |
| com.apple.dock | mineffect | scale | minimize shrinks and fades the window (Scale effect) instead of Genie: closer to Windows' minimize. Applies to every minimize. Your original: not set (Genie) | `defaults delete com.apple.dock mineffect` |
| com.apple.finder | ShowPathbar | true | Explorer-like address bar | `defaults delete com.apple.finder ShowPathbar` |
| com.apple.finder | ShowStatusBar | true | Explorer-like status bar | `defaults delete com.apple.finder ShowStatusBar` |
| com.apple.finder | _FXSortFoldersFirst | true | folders first, like Explorer | `defaults delete com.apple.finder _FXSortFoldersFirst` |
| com.apple.finder | NewWindowTarget | PfHm | new Finder windows open your home folder | `defaults delete com.apple.finder NewWindowTarget` |
| NSGlobalDomain | AppleShowAllExtensions | true | show file extensions, like Explorer | `defaults delete NSGlobalDomain AppleShowAllExtensions` |
| NSGlobalDomain | AppleActionOnDoubleClick | Fill | double-clicking a title bar maximizes (Fill), like Windows; the taskbar area stays clear. Your original: not set | `defaults delete NSGlobalDomain AppleActionOnDoubleClick` |
| com.apple.WindowManager | EnableTilingByEdgeDrag | false | macOS's own tiling ("Drag windows to screen edges to tile") would react to the same drags as Fenestra's snapping. Your original: not set (on) | `defaults delete com.apple.WindowManager EnableTilingByEdgeDrag` |
| com.apple.WindowManager | EnableTopTilingByEdgeDrag | false | "Drag windows to menu bar to fill screen": the top edge is Fenestra's maximize and snap layouts bar. Your original: not set (on) | `defaults delete com.apple.WindowManager EnableTopTilingByEdgeDrag` |
| NSGlobalDomain | _HIHideMenuBar | true | Phase 6: "Automatically hide and show the menu bar: Always". Only while Fenestra's "Hide the macOS menu bar" setting is on; off puts your original back. Applied live (apps are told through `AppleInterfaceMenuBarHidingChangedNotification`). Your original: not set (menu bar shown) | `defaults delete NSGlobalDomain _HIHideMenuBar` |
| com.apple.WindowManager | EnableTilingOptionAccelerator | false | "Hold Option key while dragging windows to tile": Option is Alt here. Your original: not set (on) | `defaults delete com.apple.WindowManager EnableTilingOptionAccelerator` |
| com.apple.WindowManager | EnableStandardClickToShowDesktop | false | "Click wallpaper to reveal desktop: Only in Stage Manager": clicking the desktop no longer hides every window (Windows has no such behavior). Your original: not set (Always) | `defaults delete com.apple.WindowManager EnableStandardClickToShowDesktop` |

Then `killall Dock` (Dock keys), `killall Finder` (Finder keys and AppleShowAllExtensions) and `killall WindowManager`
(tiling keys; launchd restarts it at once) when something changed. Your actual originals are in the backup file (for example, your
`minimize-to-application` was already `true` and `NewWindowTarget` was `PfAF`).

Other files: `~/Applications/Fenestra.app`, `~/Library/LaunchAgents/local.fenestra.shell.plist`,
`~/Library/Application Support/Fenestra/` (scripts, state, backup), `~/Library/Logs/Fenestra.log`,
app settings in `defaults read local.fenestra.Fenestra`, and optionally `/etc/sudoers.d/fenestra`.

Not changed (decided in Phase 0): "Displays have separate Spaces" stays on. Your portable display sits
directly below the main one, so the Dock can't live under the taskbar and the setting would gain nothing.

## Decisions (Phase 0)

| Topic | Decision |
|---|---|
| Close button | Windows behavior: closes the window; the app quits when its last window closes. Finder never quits. |
| Minimize | real minimize (window state kept) |
| Keys | stock modifiers. Tap Command alone = Start. Win+key shortcuts = Control+Option+key (Ctrl+Opt+V clipboard history, Ctrl+Opt+Arrow snap, Ctrl+Opt+D show desktop). Option+Tab = Alt+Tab. |
| Virtual desktops | none (one desktop); Task View = window overview |
| Finder | Explorer-like settings only (no restyling) |
| Extras | clipboard history with images; desktop right-click items through a Finder extension (later, optional). No Widgets, no Copilot, nothing else. |
| SIP | stays on |
| Taskbar | Start, Search box, Task View; no Widgets, no Copilot. Phase 5: on all displays (changed from main display only) |
| Quick Settings tiles | core set; extra tiles to be decided |

## Phase 1: APIs used (what an OS update could break)

| Feature | API | Tier |
|---|---|---|
| Taskbar window | `NSPanel`, level `CGWindowLevelForKey(.dockWindow)+1`, `.canJoinAllSpaces .stationary .ignoresCycle` | public |
| Running/pinned apps | `NSWorkspace.runningApplications` + launch/terminate/activate/hide notifications | public |
| Window list, focus, minimize, close | `AXUIElementCreateApplication`, `kAXWindowsAttribute`, `kAXMinimizedAttribute`, `kAXRaiseAction`, `kAXFrontmostAttribute`, `kAXCloseButtonAttribute` | Accessibility |
| AX window → window ID | `_AXUIElementGetWindow` (HIServices) | **private** |
| Thumbnails | `SCShareableContent`, `SCScreenshotManager.captureImage`, `SCContentFilter(desktopIndependentWindow:)` | public |
| Jump list recents | `NSMetadataQuery` on `kMDItemLastUsedDate` + the app's `CFBundleDocumentTypes` | public |
| Middle-click | AX press of the app's Cmd-N menu item (`kAXMenuItemCmdCharAttribute`), fallback `CGEvent.postToPid` | Accessibility |
| Show desktop | `NSRunningApplication.hide()/unhide()` | public |
| Keep maximized windows above taskbar | `AXObserver` on `kAXWindowResizedNotification` / `Created` / `Deminiaturized`, `kAXSizeAttribute` | Accessibility |
| Wi-Fi | CoreWLAN `CWWiFiClient`, `CWInterface.setPower`, `cachedScanResults` (list shown at once), `scanForNetworks`, `configuration().networkProfiles` (known networks), `associate(to:password:)`; known secured networks: `CWKeychainFindWiFiPassword(.system)` (macOS asks for your Mac password) then `associate`; Fenestra then keeps its own copy in the login keychain (generic password, service "Fenestra Wi-Fi") so later joins are silent | public |
| Bluetooth power | `IOBluetoothPreferenceGetControllerPowerState` / `SetControllerPowerState` | **private** |
| Bluetooth devices | `IOBluetoothDevice.pairedDevices` (icon from `deviceClassMajor`/`Minor`), asynchronous `openConnection(_:withPageTimeout:authenticationRequired:)` on the main thread / `closeConnection`; a click opens the row with Connect or Disconnect, like Wi-Fi | public |
| Volume, mute, output | CoreAudio `kAudioDevicePropertyVolumeScalar`, `kAudioDevicePropertyMute`, `kAudioHardwarePropertyDefaultOutputDevice` | public |
| AirPlay output | AVKit `AVRoutePickerView` | public |
| Battery | IOKit `IOPSCopyPowerSourcesInfo`, `IOPSNotificationCreateRunLoopSource` | public |
| Brightness (built-in) | `DisplayServicesGetBrightness` / `DisplayServicesSetBrightness` (DisplayServices.framework) | **private** |
| Brightness (external, DDC/CI) | `IOAVServiceCreateWithService`, `IOAVServiceWriteI2C` on `DCPAVServiceProxy` | **private** |
| Night light | `CBBlueLightClient` `getBlueLightStatus:` / `setEnabled:` (CoreBrightness.framework) | **private** |
| Battery saver | `ProcessInfo.isLowPowerModeEnabled`; `sudo -n pmset -a lowpowermode` | public + one sudoers rule |
| Focus | `/usr/bin/shortcuts run "Fenestra Focus On/Off"`. Fenestra builds both (one `is.workflow.actions.dnd.set` action each, Do Not Disturb), signs them with `shortcuts sign --mode people-who-know-me` into ~/Library/Application Support/Fenestra/Shortcuts and opens them; Shortcuts asks you to add each one | public (shortcut file format undocumented) |
| Nearby sharing (tile) | `com.apple.sharingd DiscoverableMode` "Off" / "Contacts Only" / "Everyone" via `CFPreferencesSetAppValue`, then `killall sharingd` (launchd restarts it and it reads the new mode) | public preference |
| Cast (tile) | AX press on Control Center's `com.apple.menuextra.screen-mirroring` item (its panel opens at the top right); Displays settings if that item is hidden | Accessibility |
| Accessibility (tile) | posts Option+Command+F5 (`CGEvent`), macOS's Accessibility Shortcuts panel | Accessibility |
| Live captions (tile) | opens System Settings > Accessibility > Live Captions (no public switch; `Live Captions.app` can't be launched by other apps: launchd spawn error 162) | public scheme |
| Dark mode (tile) | `SLSSetAppearanceThemeLegacy` (SkyLight, looked up with `dlsym`; System Events AppleScript if missing); state from `NSApp.effectiveAppearance` | **private** |
| Capture screen / selection (tiles) | posts Shift+Command+3 / 4 after the flyout fades (your Screenshot settings apply) | Accessibility |
| Quick note (tile) | posts Globe+Q (`maskSecondaryFn` + Q) | Accessibility |
| Screen saver, Screenshot and record, Voice memo, Calculator, Clock (tiles) | open ScreenSaverEngine, Screenshot, Voice Memos, Calculator, Clock (`NSWorkspace`) | public |
| Edit quick settings | pencil in the footer: unpin badge per tile, Add page, SwiftUI `onDrag`/`onDrop` reorder; order saved in `quickTiles` | public |
| Keyboard layout | Carbon TIS: `TISCreateInputSourceList`, `TISSelectInputSource`, `kTISNotifySelectedKeyboardInputSourceChanged` | public |
| Settings panes | `x-apple.systempreferences:<extension bundle id>` | public scheme, undocumented IDs |
| Notification Center | AX press on Control Center's `com.apple.menuextra.clock` item | Accessibility |
| Hide taskbar for full-screen apps/videos | `CGWindowListCopyWindowInfo` bounds vs `CGDisplayBounds`, on `activeSpaceDidChange`, app activation and window events | public |
| Auto-hide taskbar | 2 pt trigger `NSPanel` with `NSTrackingArea` | public |
| Per-window buttons ("Combine: Never") | `AXObserver` (window created/destroyed/minimized/title/focus) | Accessibility |
| Unread badges | hidden Dock's `AXList` items, `AXStatusLabel` attribute, read every 5 s | Accessibility |
| Notifications on the bell | `AXObserver` on `com.apple.notificationcenterui`; groups with subrole `AXNotificationCenterBanner/Alert` | Accessibility |
| Task View button | Fenestra's Task View (Phase 4; was Mission Control) | public |

## Phase 2: APIs used

| Feature | API | Tier |
|---|---|---|
| Start panel | prebuilt `NSPanel` (`.nonactivatingPanel`, can become key), Core Animation slide-up 200 ms | public |
| App catalog | scan of /Applications, /System/Applications (+Utilities), ~/Applications; `LSApplicationCategoryType` for categories; `addedToDirectoryDate` for "recently added" | public |
| Recommended files, file search | `NSMetadataQuery` (`kMDItemLastUsedDate`, `kMDItemDisplayName LIKE[cd]`, `kMDItemContentTypeTree`) | public |
| Settings search | System Settings extensions (`/System/Library/ExtensionKit/Extensions`, `SettingsExtensionAttributes`) opened via `x-apple.systempreferences:` | public, undocumented IDs |
| Tap Command = Start | `NSEvent.addGlobalMonitorForEvents` (`.flagsChanged`, `.keyDown`, clicks) | Accessibility |
| Sleep | `pmset sleepnow` | public |
| Restart / Shut down / Sign out | Apple events `kAERestart` / `kAEShutDown` / `kAEReallyLogOut` to loginwindow (QA1134); fallback System Events | public |
| Lock | `SACLockScreenImmediate` (login.framework); fallback Ctrl+Cmd+Q | **private** |
| User tile | `NSFullUserName`, Collaboration `CBIdentity.image` | public |

## Phase 1 test checklist (about 5 minutes)

| # | Do this | Windows 11 25H2 behavior | Fenestra should |
|---|---|---|---|
| 1 | Look at the bottom of the main display | 48 px taskbar, icons centered | same; Dock gone (the portable display has its own taskbar since Phase 5) |
| 2 | Taskbar settings > alignment Left | icons move left | same |
| 3 | Click a pinned app that isn't running | launches; pill appears | same (gray pill, accent pill when active) |
| 4 | Click the active app's icon (one window) | minimizes | same |
| 5 | Click it again | restores | same |
| 6 | Hover an icon of a running app | thumbnails after a short delay | same (needs Screen Recording) |
| 7 | Click an icon of an app with 2+ windows | thumbnail picker | same; click a card to focus it, X closes it (red hover) |
| 8 | Right-click an icon | jump list: recent files, app name, pin, close | same (native menu style) |
| 9 | Middle-click an icon | new instance | new window of that app |
| 10 | Click the far-right sliver, then again | shows desktop, then restores | same |
| 11 | Click Wi-Fi/volume/battery | Quick Settings flyout slides up | same; try each tile |
| 12 | Wi-Fi tile `>` | network list; click a network: it opens with Connect; known networks join without the key | click opens it with Connect; known networks join with the saved password (the first time macOS asks for your Mac password; Fenestra keeps a copy in your login keychain, so it asks once per network); new secured networks ask for the key in place (no "Connect automatically" box) |
| 13 | Volume `>` | output picker | same, plus AirPlay |
| 13a | Nearby sharing tile | Nearby sharing on/off (My devices only) | each click: Off, Contacts only, Everyone (back to Contacts only after 10 minutes, like macOS), Off. Check in Control Center > AirDrop |
| 13j | Bluetooth > click a device | the row opens with Connect (paired) or Disconnect (connected) | same; Connect shows Connecting, then Connected or a message |
| 13i | Focus tile (first time) | Do Not Disturb on/off | Set up Focus page > Add shortcuts: Shortcuts asks twice (Add Shortcut), then Do Not Disturb turns on |
| 13b | Cast tile | Cast flyout with nearby displays | Screen Mirroring panel at the top right (macOS draws it there) |
| 13c | Accessibility tile | Accessibility flyout: Magnifier, Narrator, Color filters... | macOS Accessibility Shortcuts panel (Zoom, VoiceOver, Invert colors...) in the middle of the screen |
| 13d | Keyboard layout tile (title = current layout) | layout list | same list; choosing one switches |
| 13e | Live captions tile | captions on/off | opens Accessibility > Live Captions settings |
| 13f | Pencil at the bottom of Quick Settings | tiles get unpin badges, Add and Done appear; drag to reorder | same; Add lists Windows tiles, then "From Control Center" (Dark mode, Screen saver, Capture screen/selection, Screenshot and record, Voice memo, Quick note, Calculator, Clock) |
| 13g | Taskbar settings > Quick Settings | (Windows: only in the flyout) | the same tiles with switches, drag to reorder, Reset to default tiles |
| 13h | Taskbar settings > Keyboard layout (ENG US): Automatic | input indicator always shown | hidden while the Keyboard layout tile is in Quick Settings; Always show / Never show override it |
| 14 | Brightness slider | changes brightness | built-in screen; external only if DDC works on that monitor |
| 15 | Battery saver tile | Energy saver on | asks for admin once, then toggles Low Power Mode |
| 16 | Click the clock | calendar + notifications | same; "Open macOS Notification Center" works |
| 17 | Click `ENG/US` | layout list | same; switches layout |
| 18 | Double-click a window's title bar or use Window > Fill | maximized window stops at taskbar | window gets shortened to stop at the taskbar |
| 19 | Right-click empty taskbar | Task Manager, Taskbar settings | same (Activity Monitor) |
| 20 | `kill -9 $(pgrep -x Fenestra)` | n/a | Dock flashes back, Fenestra restarts within seconds |

## Phase 2 test checklist

| # | Do this | Windows 11 25H2 | Fenestra should |
|---|---|---|---|
| 1 | Click Start, or tap Command alone | Start slides up | same, in about 200 ms |
| 2 | Type right away | search starts | same; apps and settings instantly, documents a moment later |
| 3 | Arrow keys, Enter, Esc | move, open, clear/close | same |
| 4 | Pinned "Show all" | expands | same (when more than 16 pins) |
| 5 | Right-click an app | Pin/Unpin, Move to front, Pin to taskbar, Open file location | same |
| 6 | All > View: Category / Grid / List | three views | same; click a category to open it |
| 7 | User tile | Lock, Sign out, account settings | same |
| 8 | Power button | Sleep, Shut down, Restart | same (macOS may ask to allow controlling loginwindow) |
| 9 | Right-click Start | Win+X menu | same, with Mac equivalents |
| 10 | Personalization > Start | recommended, folders | same; folders appear next to power |
| 11 | Taskbar alignment Left | Start opens at the left | same |

## Phase 1: still different from real Windows 11

- Jump list is a native macOS menu, not the Windows-styled panel. Recent files are "recent files of the types this app opens", because macOS doesn't share an app's own recent list.
- No progress bars or attention flashing on icons (not exposed by macOS).
- "Show my taskbar on all displays" came in Phase 5 (see below).
- Maximized windows from other apps are corrected just after they resize (a brief jump), because macOS can't reserve screen space for a taskbar with your display arrangement.
- Minimize animates toward the hidden Dock's position (bottom of the portable display), not the taskbar icon.
- The bell only lists notifications captured as banners while Fenestra runs (macOS doesn't share Notification Center's history). Notifications hidden by Focus or with banner style None aren't captured.
- Start: no Phone Link panel, no web results, no live tiles; search ranking is Fenestra's own over Spotlight data.
- Focus state is what Fenestra last set; changing Focus elsewhere isn't detected.
- External brightness can't be read back from monitors, so the slider shows the last value set.
- Tray overflow and the menu bar: see Phase 6.

## Phase 3: Windows caption buttons and Snap Layouts

Every window with traffic lights gets Windows 11 minimize, maximize/restore and close buttons in their place
(top-left, your choice). macOS can't restyle another app's title bar without disabling SIP, so each window gets a
small panel of Fenestra's, ordered directly above that window, covering the traffic lights. It follows the window
through Accessibility events (no polling). While you drag a window by its title bar the buttons move with it
(since 2026-11-15; before, they hid during the drag and the traffic lights showed). See "Following a dragged
window" below for how, and what is left of the old wobble. Settings > Windows > "Keep the buttons on a window
while I drag it" (on by default) turns it off: then the buttons hide during a drag and the traffic lights show,
for anyone who finds the following choppy (more noticeable on high refresh rate displays).
After every click and app switch Fenestra also checks the window order once and puts any panel that fell behind
its window back on top (some apps, Electron ones included, raise their windows without telling Accessibility).
Glyphs are drawn by Fenestra (vector paths, 10 x 10 pt like Segoe Fluent Icons); no Microsoft assets.
Options: Fenestra settings > **Windows** (turn it off, button size, keep the buttons on a dragged window,
Snap Layouts on hover).

| Button | Does |
|---|---|
| Minimize | real minimize (AX) |
| Maximize | fills the work area of the display the window is on: on the main display the visible frame minus the taskbar, never a full-screen Space. Glyph turns into Restore Down |
| Restore Down | back to the frame it had before (remembered per window ID); if it was maximized before Fenestra saw it, a centered 70% x 80% window |
| Close | closes the window; when that was the app's last window the app quits (normal Quit, so it can still ask to save). Finder never quits |
| Hover maximize (0.4 s) | Snap Layouts flyout under the button; click a zone to snap the window there |

Snap Layouts adapt to the display's shape, like Windows: landscape gets halves, 2/3 + 1/3, thirds (displays 1800 pt
wide or more, so both of yours), half + quarters and quadrants; ultrawide (2.1:1 or wider) adds 1/4 + 1/2 + 1/4;
portrait gets stacked halves, 2/3 + 1/3, thirds (1800 pt tall or more) and half + two quarters.

Button size, Automatic (default): Windows size (46 x 32 pt, up to 48 pt tall in tall toolbars) unless that would
cover the app's own controls next to the traffic lights (checked with Accessibility hit tests); then the buttons
shrink to the traffic lights' width. Chromium and Electron apps (Brave, Chrome, Claude, VS Code...) always get the
compact size because their tabs start right beside the traffic lights. Settings can force either size.

### Phase 3: APIs used

| Feature | API | Tier |
|---|---|---|
| Button panel per window | `NSPanel` (`.borderless`, `.nonactivatingPanel`, level normal, `.transient` so Mission Control hides it), `order(.above, relativeTo: CGWindowID)` | public |
| Traffic light position, enabled state | `kAXCloseButtonAttribute`, `kAXMinimizeButtonAttribute`, `kAXZoomButtonAttribute`, `kAXEnabledAttribute`, `kAXPositionAttribute` / `kAXSizeAttribute`, `AXUIElementIsAttributeSettable` | Accessibility |
| Window events | shared `AXObserver` hub (`WindowEvents`): created, destroyed, moved, resized, minimized, focus; `NSWorkspace` activate/hide/unhide/Space change | Accessibility + public |
| AX window to window ID | `_AXUIElementGetWindow` (HIServices) | **private** (already used) |
| On-screen check, z-order, drag detection | `CGWindowListCopyWindowInfo` (`.optionOnScreenOnly`, `.optionIncludingWindow`) | public |
| Follow a dragged window | `NSEvent.addGlobalMonitorForEvents` `.leftMouseDown`; an **active** `CGEvent.tapCreate` (`.cgSessionEventTap`, head insert, drag and mouse-up only, on only during a title bar press; it passes every event on unchanged) so the panel moves before the window server routes each event; one `AXUIElementCopyElementAtPosition` at mouse-down tells empty title bar from controls | public (needs Accessibility) |
| Move the panel without a frame of delay | `SLSMainConnectionID`, `SLSMoveWindow` (SkyLight, `dlsym`) on Fenestra's own panel only; AppKit `setFrame` afterwards so AppKit agrees | **private** (own windows only; falls back to AppKit `setFrame` + `CATransaction.flush()`) |
| Follow apps that move their own window (Chromium, Electron) | `CGWindowListCopyWindowInfo` `.optionIncludingWindow` for that one window every 0.6 ms on a background queue, only during the drag and 40 ms after each drag event (also 0.25 s after Fenestra snaps or maximizes a window) | public |
| Keep panels on top | at mouse-down on a window its panel is lifted to `NSWindow.Level.normal + 1` until 0.3 s after release, so the click-to-front (and apps that raise their own window, like Claude) land underneath it; plus one `CGWindowListCopyWindowInfo` read 30 ms and 400 ms after each click or app switch to re-`order(.above, relativeTo:)` any panel not directly above its window | public |
| Glyphs, hover and press states | Core Animation `CAShapeLayer` / `CALayer` implicit 80 ms fades, no redraws | public |
| Title bar color match | `SCScreenshotManager.captureImage` with `SCContentFilter(desktopIndependentWindow:)` and a `sourceRect` of the window's top-left corner | public, Screen Recording |
| Automatic button size | `AXUIElementCopyElementAtPosition` hit tests beside the traffic lights | Accessibility |
| Minimize | `kAXMinimizedAttribute` | Accessibility |
| Maximize, restore, snap | `kAXSizeAttribute` / `kAXPositionAttribute` (size, position, size), `NSScreen.visibleFrame` minus `TaskbarController.reservedHeight`; `AXEnhancedUserInterface` switched off during the move if an app had it on | Accessibility |
| Close, then quit | AX press of the close button; `NSRunningApplication.terminate()` once `kAXWindowsAttribute` is empty | Accessibility + public |
| Snap Layouts flyout | `FlyoutManager` (new below-the-anchor placement), SwiftUI; its hosting view accepts the first click (Fenestra is never the active app) | public |
| Double-click title bar | `NSGlobalDomain AppleActionOnDoubleClick = Fill` | defaults |

### Phase 3 test checklist (about 5 minutes)

| # | Do this | Windows 11 25H2 | Fenestra should |
|---|---|---|---|
| 1 | Look at the top-left of a Finder, TextEdit and Brave window | three caption buttons, no other window controls | Windows glyphs where the traffic lights were; no traffic light visible. Brave: compact width |
| 2 | Hover minimize, maximize, close | light gray hover; close turns red (#C42B1C) with a white X | same, quick fade |
| 3 | Press and hold close, slide off, release | nothing happens | same |
| 4 | Click another window, look back at the first | inactive window: dimmed glyphs | same |
| 5 | Minimize | window goes to the taskbar | window minimizes; its taskbar button brings it back |
| 6 | Maximize a window on the main display | fills the screen down to the taskbar, glyph becomes Restore Down | same; no full-screen Space, no animation to a new desktop |
| 7 | Restore Down | previous size and position | same |
| 8 | Maximize a window on the portable display | fills that display above its taskbar | same (with "Show my taskbar on all displays" off: the whole display) |
| 9 | Double-click an empty title bar area | maximize / restore | macOS Fill, stops at the taskbar; caption glyph switches to Restore Down |
| 10 | Rest the pointer on maximize | Snap Layouts flyout | after 0.4 s, under the button: 5 layouts in two rows |
| 11 | Hover a zone, click it | zone turns accent color, window snaps there, Snap Assist fills the rest | same |
| 12 | Move the pointer away from flyout and button | flyout closes | same, after 0.3 s |
| 13 | Drag a window by its title bar (Finder, Claude, Brave; slow, fast, into the top edge; a maximized one out of maximize) | buttons move with the window | buttons move with the window; at fast drags an occasional single frame shows a sliver of a traffic light (user check on 120 Hz and 60 Hz displays, 2026-11-15: "good enough to keep") |
| 14 | TextEdit: type something, close, Don't Save | app exits with its last window | same |
| 15 | Close the last Finder window | window closes | same; Finder keeps running (never quits) |
| 15b | Click Wi-Fi/volume/battery on the taskbar | Quick Settings opens | same (this was broken: every flyout opened at 0 x 0 pt) |
| 16 | Settings > Windows > Button size: Windows size, then Compact | n/a | button width changes at once |
| 17 | `top -pid $(pgrep -x Fenestra)` with nothing moving | n/a | under 1% CPU (measured 0.04%) |

### Phase 3: still different from real Windows 11

- The buttons are at the top-left where the traffic lights were (your choice); Windows puts them at the top-right.
- They're an overlay, not part of the window. Clicking a window is covered (the buttons are lifted before the app
  raises it), but a window brought forward without a click (Cmd-Tab, Dock, another app) can show its traffic lights
  for a frame or two before Fenestra re-orders its panel.
- While a window is dragged the buttons follow it, but they are a separate window: at fast drags a single frame
  now and then is a few points off and shows a sliver of a traffic light (most often in Chromium and Electron
  apps, whose compact buttons leave ~3 pt of margin). With SIP on there is no way to attach a window to another
  app's window. The buttons still hide while a window is resized from its top or left edge, and a window that
  doesn't move with the pointer at all gets the old behavior (hidden until release).
- When an app opens a new window its traffic lights show until Fenestra has placed the panel (a moment after the
  window appears, longer while macOS animates the window in).
- Background: with Screen Recording, the title bar's look is sampled from the area the buttons cover (around the
  traffic lights, row by row, most common color so icons and title text don't tint it) when a window appears,
  changes size or gets focus (at most every 3 s); if an app later changes its title bar color (for example Safari
  tinting it to the page), the patch is outdated until the next sample. Without Screen Recording it's a plain system
  window color.
- Automatic size uses Windows' 46 pt width only where it covers nothing of the app's toolbar; otherwise, and always
  in Chromium/Electron apps, the buttons are only as wide as the traffic lights.
- Close quits an app through its normal Quit, so it may still ask to save. An app with a window in a full-screen
  Space isn't quit.
- Snapping, Snap Assist and Win+Z came in Phase 4 (see below for what still differs there).
- Maximized windows keep macOS rounded corners and border.
- The window menu (right-click the caption buttons, or Option+Space) came in Phase 6 and the polish pass.
- Tooltips are macOS style: Minimize and Close only (maximize shows Snap Layouts instead, as on Windows).
- Windows without traffic lights (custom title bars, some games and panels) keep their own controls; Fenestra's own
  Settings window keeps its traffic lights.
- Minimize still animates toward the hidden Dock's position.

### Following a dragged window (2026-11-15)

Until 2026-11-15 the buttons hid during a drag, because an earlier attempt to follow wobbled. Measured this time
(trace of every drag event and frame captures of real drags), the wobble had three causes, each fixed:

1. **AppKit sends a window move only at the end of the run loop pass** (0 of 100 `setFrame` moves were in the
   window list right after the call; 100 of 100 after `CATransaction.flush()`), and even flushed it is drawn a
   frame late. The panel is now moved with SkyLight's `SLSMoveWindow` (immediate, 0.002 ms).
2. **The event tap was listen-only**, so the window server moved the window without waiting. It is now an active
   tap (it changes nothing): each drag event waits the ~0.04 ms it takes to place the panel.
3. **Reading the window list per event** cost 0.5 to 12 ms during a drag and was often one event stale. Windows
   the window server drags (Finder, TextEdit, most native apps) keep the grab point under the pointer, so the panel
   goes to `pointer - grab offset` with no read at all; a check after each event (off the event path) learns
   where macOS holds the window (top of a display, known up front too) and catches a changed grab offset.

Two kinds of window behave differently:

- **Chromium and Electron apps (Brave, Chrome, Claude, VS Code...) move their own windows**, one mouse event late
  and unevenly, so the pointer can't predict them. For those, `DragChaser` reads that one window's position every
  0.6 ms on a background queue during the drag and moves the panel the moment it changes.
- **A snapped or maximized window dragged away** is resized by Fenestra under the pointer ~0.1 s into the drag;
  from then on that drag is followed the same way (watching the window, not the pointer).

Fenestra's own snaps, maximize and restore also watch the window for 0.25 s, so the buttons ride along instead of
being put back at the old spot on release. Nothing runs between drags: the tap is off, the chase loop stops 40 ms
after the last drag event, idle CPU stays 0.0%.

Settings for testing (none needed normally, `defaults write local.fenestra.Fenestra <key> ...`, then restart):

| Key | Effect |
|---|---|
| `captionDragMove appkit` | move the panel through AppKit (`setFrame` + flush) instead of `SLSMoveWindow` |
| `captionDragLagMs <ms>` | how far back along the motion the panel is placed for window-server drags (default 3) |
| `captionDragTrace -bool true` | per-event trace to ~/Library/Logs/Fenestra-follow.txt, plus a capture of the display during each drag counting frames that show traffic lights (`dragcapture:` lines in the app log, crops in ~/Library/Logs/Fenestra-dragtest/frame-*.png). Costly: only for measuring |

Every followed drag (pointer mode) logs `captions drag: followed window <id>, N events, N checks off by more
than 1.5 pt, max N pt, N ms per event`.

## Phase 4: snapping, Snap Assist, Alt+Tab, Task View

Windows 11 25H2 window management, with your key mapping (Windows key = Control+Option, Alt = Option).
macOS's own edge tiling is switched off (three `com.apple.WindowManager` keys, see the table above) so it
doesn't react to the same drags. Options: Fenestra settings > **Windows** (Snap windows, snap layouts bar on drag,
Snap Assist, Option+Tab).

| Do this | Result |
|---|---|
| Drag a window by its title bar until the pointer touches the left or right edge | translucent preview of that half; let go and it snaps there |
| ... the edge near a corner (within 64 pt), or the top edge near a corner | quarter |
| ... the top edge | maximize (the work area, never a full-screen Space) |
| Drag toward the top center | snap layouts bar: a small handle, then the layouts when the pointer reaches it; drop on a zone |
| Edge shared with the other display (top of the portable display) | the pointer passes through there, so rest it at the edge for 0.3 s |
| Drag a window Fenestra snapped or maximized | it gets back its size from before snapping, under the pointer |
| After any snap into a layout (drag, keys, Snap Layouts flyout, the bar) | Snap Assist: the other windows in the empty zone; click one (or arrows + Return) and it fills that zone, then the next empty zone asks. Esc or a click elsewhere ends it. Zones another window already fills are skipped |
| Control+Option+Left / Right | snap left / right half; from the other half: restore; from the same half: the other half (no display to the side, yours are stacked); quarters move sideways |
| Control+Option+Up | normal: maximize; half or bottom quarter: top quarter; top quarter: maximize |
| Control+Option+Down | maximized: restore; half or top quarter: bottom quarter; otherwise minimize |
| Control+Option+Shift+Left / Right | move the window to the other display (keeps its zone, or its relative place) |
| Control+Option+Shift+Up | stretch to the full work-area height |
| Control+Option+Z | Snap Layouts flyout for the focused window (click a zone) |
| Option+Tab (hold Option) | window switcher with live thumbnails, most recent first, starting on the previous window; Tab / Shift+Tab / arrows move, release Option to switch, Esc cancels, Delete or the X closes a window. A quick Option+Tab switches without showing it |
| Task View button or Control+Option+Tab | all windows as thumbnails, each on its own display, over a blurred backdrop; the taskbar stays usable. Click (or arrows + Return) to switch, X to close, click the backdrop or Esc to leave |
| Control+Option+D | show desktop (same as the taskbar corner) |

### Phase 4: APIs used

| Feature | API | Tier |
|---|---|---|
| Turn off macOS tiling | `com.apple.WindowManager` `EnableTilingByEdgeDrag`, `EnableTopTilingByEdgeDrag`, `EnableTilingOptionAccelerator` (names from the Desktop & Dock settings extension), `killall WindowManager` | defaults, undocumented keys |
| Recognize a window drag | shared `AXObserver` hub: `kAXWindowMovedNotification` while the left button is down (same signal the caption buttons react to), grab point in the title band; `kAXWindowResizedNotification` aborts (edge resize) | Accessibility |
| Follow the pointer during a drag | listen-only `CGEvent.tapCreate` (`.cgSessionEventTap`, left drag and up), enabled only while a window is dragged | public (needs Accessibility) |
| Preview, snap layouts bar, Snap Assist | `NSPanel` (borderless, non-activating), `NSVisualEffectView`, preview ordered with `order(.below, relativeTo:)` under the dragged window, Core Animation frame animation | public |
| Move/resize, maximize, restore | `kAXSizeAttribute` / `kAXPositionAttribute` via `CaptionController.setFrame`, work area = `NSScreen.visibleFrame` minus `TaskbarController.reservedHeight` | Accessibility |
| Shortcuts that the app in front must not get (Option+Tab, Control+Option+arrows/Tab/Z/D) | active `CGEvent.tapCreate` (`.defaultTap`) on key down/up and modifier changes, on its own thread so typing never waits for the main thread. Carbon `RegisterEventHotKey` can't do Option-only hot keys since macOS 15 | public (needs Accessibility) |
| Window list, most recent first | `WindowTracker` (AX, event driven) + one `CGWindowListCopyWindowInfo` read for the stacking order; focus events for minimized/hidden windows | Accessibility + public |
| Thumbnails | `SCScreenshotManager.captureImage` with `SCContentFilter(desktopIndependentWindow:)`, all windows at once (task group) | public, Screen Recording |
| Switch to a window | `kAXRaiseAction`, `kAXMainAttribute`, `kAXFrontmostAttribute`, `NSRunningApplication.unhide()` | Accessibility + public |
| Close from a card | AX press of the window's close button | Accessibility |

### Phase 4 test checklist (about 5 minutes)

| # | Do this | Windows 11 25H2 | Fenestra should |
|---|---|---|---|
| 1 | `defaults read com.apple.WindowManager` | n/a | `EnableTilingByEdgeDrag`, `EnableTopTilingByEdgeDrag`, `EnableTilingOptionAccelerator` = 0 |
| 2 | Drag a TextEdit window by its title bar to the left edge of the main display, hold | preview of the left half | translucent rounded preview with the app icon, just under the window |
| 3 | Let go | window snaps to the left half; Snap Assist shows the other windows on the right | same; the half stops at the taskbar |
| 4 | Click a window in Snap Assist | it fills the right half | same |
| 5 | Drag the snapped TextEdit window away from the edge | it gets its old size back under the pointer | same |
| 6 | Drag to the top-right corner, let go | top-right quarter, Snap Assist for the other three quarters | same (one empty zone at a time) |
| 7 | Drag to the top edge (away from the center) | maximize | same |
| 8 | Drag toward the top center, onto the bar, over a zone, let go | snap layouts bar drops down, zone highlights, window snaps there | same |
| 9 | Drag a window on the portable display to its top edge and rest there | maximize on that display | same after 0.3 s (that edge is shared with the main display) |
| 10 | Control+Option+Left, then Up, then Down | left half, top-left quarter, bottom-left quarter | same |
| 11 | Control+Option+Right on a left-snapped window | restores its earlier size | same |
| 12 | Control+Option+Up on a normal window, then Down | maximize, restore | same |
| 13 | Control+Option+Shift+Right | moves to the other display | same |
| 14 | Hold Option, press Tab a few times, let go | switcher with thumbnails, last-used first; switches on release | same, on the main display |
| 15 | Quick Option+Tab | goes back to the previous window, no switcher flash | same |
| 16 | In the switcher: Delete, Esc | closes the selected window / cancels | same |
| 17 | Click the Task View button, or Control+Option+Tab | windows overview | same, per display; Esc or a backdrop click closes; taskbar stays usable |
| 18 | `top -pid $(pgrep -x Fenestra)` with nothing moving | n/a | under 1% CPU (measured 0.0%, 32 MB) |

### Phase 4: still different from real Windows 11

- Windows key + arrows is Control+Option+arrows, Alt+Tab is Option+Tab (your mapping). Control+Alt+Tab (sticky
  switcher) isn't offered: Control+Option+Tab is Windows key + Tab (Task View).
- macOS lets an app keep its window from being resized below its minimum size or to exact sizes (Terminal snaps to
  character cells), so a snapped window can end a few points short of its zone. Fenestra logs when that happens.
- Restoring the size when you drag a snapped window away happens about 0.1 s into the drag (Accessibility reports
  window moves in batches), so the window jumps to its old size slightly after it starts moving.
- Drags are recognized from the title band (top 100 pt of a window). Apps that move their window from elsewhere (drag
  by background) don't snap.
- The top edge of the portable display is shared with the main display: the pointer passes through it, so there you
  rest at the edge for 0.3 s. On Windows that edge is hard to hit too.
- Snap Assist offers one empty zone at a time. Snap groups came in the polish pass (see below for what differs).
- No "suggested" snap layouts with app icons. Windows key + Z numbers came in the polish pass.
- Control+Option+Left on a left quarter makes it the left half; Windows' exact cycling through quarters and displays
  may differ there. Your displays are stacked vertically, so Left/Right never go to the other display (Shift+Left/Right do).
- The switcher always opens on the main display and lists windows of the current Space only (full-screen apps are
  left out). Windows of apps without a regular Dock presence (menu bar apps) aren't listed.
- Minimized windows show their last thumbnail if Fenestra saw them before; otherwise the app icon (macOS can't
  capture minimized windows).
- Task View has no desktops strip and no "drag a window to snap it" from the overview. Windows that span both displays
  appear on the display holding their center.
- Thumbnails are still frames taken when the switcher or Task View opens, not live video.
- Shortcuts use key positions (U.S. layout positions for Z and D), so they stay put on the Romanian layout.

## Phase 5: multiple displays

Windows 11 25H2 Settings > System > Display > **Multiple displays**, and the multiple-display options of
Settings > Personalization > Taskbar > Taskbar behaviors. Options: Fenestra settings > **Windows** > Multiple
displays, and **Taskbar** > Taskbar behaviors.

| Setting | Default | Does |
|---|---|---|
| Remember window locations based on monitor connection | on | When a display goes away, macOS moves its windows onto the remaining display. Fenestra remembers where each one was (place and size relative to that display, snapped zone or maximized, and its Restore Down size) and puts it back when the display returns, about 1 to 3 s after it appears. If the display comes back elsewhere in the arrangement or at another resolution, windows keep their relative place |
| Minimize windows when a monitor is disconnected | on | Those windows are minimized instead of piling up on the remaining display; on reconnect they come back to their display. A window you had minimized yourself stays minimized, and goes back to its display when you restore it |
| Show my taskbar on all displays | on (you chose it in Phase 5) | Every display gets a taskbar: Start, Search, Task View, app buttons, then the clock with the bell and the show-desktop corner. Tray icons and Quick Settings stay on the main taskbar, as on Windows. Maximize, snapping and Task View keep each display's taskbar clear. Start and the calendar open on the taskbar you click |
| When using multiple displays, show my taskbar apps on | All taskbars | **All taskbars**: the same buttons everywhere. **Main taskbar and taskbar where window is open**: the main taskbar shows everything, the others only apps with a window on that display. **Taskbar where window is open**: each taskbar shows the apps with a window on its display; pinned apps and apps without windows stay on the main taskbar. With "Combine taskbar buttons: Never", each window's button sits on its own display's taskbar |

How it works: Fenestra keeps a small record of every window's place, refreshed with one window list read
0.5 s after window activity stops (nothing while idle, nothing with a single display). The moment macOS announces a
display change, before it moves any window, the record is frozen, so it still says where windows were. Then:
display gone, its windows are minimized (or left where macOS put them) and kept as "waiting for that display";
display back, each waiting window is put back with the same calls that maximize and snap windows (Phase 3 and 4),
so Restore Down and dragging a snapped window away still work afterward. Displays are told apart by their
ColorSync UUID, which stays the same across unplugging and restarts.

### Phase 5: APIs used

| Feature | API | Tier |
|---|---|---|
| Display added or removed | `NSApplication.didChangeScreenParametersNotification`; `CGDisplayRegisterReconfigurationCallback` (`kCGDisplayBeginConfigurationFlag` freezes the record before windows move) | public |
| Display identity | `CGDisplayCreateUUIDFromDisplayID` (ColorSync), `NSScreenNumber` | public |
| Window record | `CGWindowListCopyWindowInfo` (`.optionOnScreenOnly`, bounds, owner, window number), coalesced after `WindowEvents` (moved, resized, created, destroyed, minimized) | public |
| Minimize, unminimize | `kAXMinimizedAttribute`; `kAXWindowDeminiaturizedNotification` for windows you minimized yourself | Accessibility |
| Put windows back | `kAXSizeAttribute` / `kAXPositionAttribute` through `CaptionController.setFrame`; snapped/maximized state through `WindowSnap` and `CaptionController` | Accessibility |
| AX window to window ID | `_AXUIElementGetWindow` (HIServices) | **private** (already used) |
| Taskbar per display | one `NSPanel` per `NSScreen` (same level and behavior as Phase 1), rebuilt on screen changes; full-screen hiding per display with `CGDisplayBounds` | public |
| Buttons on the display of their window | each window's AX frame when its app's window list is read; window moves are followed (after mouse release) only while that option is on | Accessibility |
| Show desktop for one display | windows whose center is on that display: `kAXMinimizedAttribute`; `kAXWindowDeminiaturizedNotification` ends it when you restore one yourself | Accessibility |
| Normal pointer over the taskbar, Start and flyouts (it kept a window's resize arrow coming off its bottom edge) | `NSTrackingArea` (`.activeAlways`, entered/moved/cursorUpdate) + `NSCursor.arrow.set()`; connection property `SetsCursorInBackground` via `CGSSetConnectionProperty` so a background app's cursor change applies | public + **private** |
| Test harness only | `CGConfigureDisplayMirrorOfDisplay`, `CGConfigureDisplayOrigin`, `CGCompleteDisplayConfiguration(.forSession)` (mirroring a display looks like unplugging it to macOS and apps) | public |

### Phase 5 test checklist (about 5 minutes)

| # | Do this | Windows 11 25H2 | Fenestra should |
|---|---|---|---|
| 1 | Look at the bottom of the portable display | secondary taskbar: Start, Search, Task View, apps, clock and bell, no tray icons | same, with the show-desktop corner |
| 2 | Click Start on the portable display's taskbar | Start opens on that display | same |
| 3 | Click its clock | calendar opens on that display | same |
| 4 | Maximize a window on the portable display | stops above that display's taskbar | same |
| 5 | Taskbar settings > "show my taskbar apps on": Taskbar where window is open; move a window to the other display and let go | its button moves to that display's taskbar | same, a moment after you let go |
| 6 | On the portable display: snap a TextEdit window left, maximize another, leave a third as is. Unplug the portable display | its windows are minimized | same (they show on the main display for about half a second first) |
| 7 | Plug it back in | the windows return to their places | within about 3 s: same place and size, left half, maximized; Restore Down on the maximized one gives its old size |
| 8 | Windows settings: turn off "Minimize windows when a monitor is disconnected", unplug, plug in | windows move to the main display, then return | same |
| 9 | Minimize a window on the portable display yourself, unplug, plug in, then click its taskbar button | it comes back on the portable display | same |
| 10 | Turn off "Show my taskbar on all displays" | secondary taskbar disappears | same; a maximized window on the portable display can then fill it |
| 10b | Click the far-right corner of the portable display's taskbar, then again | shows the desktop on all displays | only the portable display's windows minimize (your choice); the second click brings them back. Control+Option+D still clears every display |
| 11 | Hover a window's bottom edge (resize arrow), then move down onto the taskbar | normal pointer | same (fixed 2026-11-15) |
| 12 | `top -pid $(pgrep -x Fenestra)` with nothing moving | n/a | under 1% CPU (measured 0.0%, 33 MB) |

Automated version (needs `captionDebug`; it flickers both displays twice and moves windows, so close what you're
doing first; 20 checks, all PASS on 2026-11-15): object "TextEdit displays" on `local.fenestra.debug.dragtest`. It opens three TextEdit windows on the
second display (plain, snapped left, maximized), simulates unplugging by mirroring that display onto the main one,
checks minimize (round 1) or move (round 2, minimize off), stops mirroring and checks every frame and state; it puts
the arrangement and the main display's mode back and closes its windows. Results in
~/Library/Logs/Fenestra-dragtest/displays.txt.

### Phase 5: still different from real Windows 11

- Windows come back about 1 to 2 s after the display reappears. Windows minimized on disconnect are moved into
  place while still minimized, so they come out of the hidden Dock straight to their spot (an app that ignores that
  gets placed again right after, a visible jump).
- With "Minimize windows when a monitor is disconnected", macOS shows the windows on the main display for a moment
  (about 0.2 s) before they minimize: it moves them before telling apps the display is gone.
- The record is refreshed 0.5 s after windows stop changing: a window moved in the last half second before unplugging
  returns to where it was before that move.
- Windows are remembered while Fenestra and the app keep running (macOS window numbers last one session). An app
  that is quit and reopened places its own windows.
- Windows in a full-screen Space aren't recorded (macOS handles those).
- Tapping Command opens Start on the display under the pointer if it has a taskbar, else on the main display.
- Clicks, thumbnails and the running pill per taskbar came in the polish pass (see below).
- Alt+Tab still opens on the main display (Phase 4).
- Minimize uses macOS's Scale effect (your choice): the Dock draws it for every app, so Fenestra can't replace it with
  Windows' animation. Windows still shrink toward the hidden Dock at the bottom of the portable display, not toward
  their taskbar button.
- The show-desktop corner of each taskbar clears only its own display (your choice; Windows clears all displays). It
  minimizes that display's windows (with the minimize animation) instead of hiding apps, because an app can have
  windows on both displays. Control+Option+D and Start's Win+X "Desktop" still hide every app at once, like Windows key + D.
- "Share any window from my taskbar" (Teams) isn't offered.
- The hidden macOS Dock still sits at the bottom of the portable display, under its taskbar (it never slides in).

## Phase 6: menu bar migration

The macOS menu bar is auto-hidden, its icons move into the taskbar's tray, and app menus (Apple, the app menu,
File, Edit...) open from each window instead. With SIP on the menu bar can't be removed, only auto-hidden; on top of
that Fenestra makes it invisible and click-through, so it no longer slides in when the pointer touches the top edge.
Options: Fenestra settings > **Windows** > Menu bar and app menus, and **Taskbar** > Other system tray icons.

| Setting | Default | Does |
|---|---|---|
| Hide the macOS menu bar | on | `NSGlobalDomain _HIHideMenuBar = true` ("Automatically hide and show the menu bar: Always"), backed up and restored like every other key. Applied live: maximized windows and the work area reach the top of each display. Off: your original value goes back |
| Keep it hidden when the pointer touches the top of the screen | on | The hidden menu bar's opacity is set to 0 (private SkyLight `SLSSetMenuBarInsetAndAlpha`): its slide-in at the top edge shows nothing and clicks go through to the windows under it. macOS resets it when Mission Control runs, so Fenestra sets it again after Mission Control (the Dock's `AXExpose*` notifications), Space changes, app switches, wake and display changes. Quit, crash and switching it off put opacity 1 back (`restore.sh` runs `Fenestra --menubar-reset`). Only while the menu bar is hidden |
| Show a menu button next to the title bar buttons | on | A fourth button (three lines) right of close. Click: the app's whole menu bar as a dropdown under it (Apple menu, app menu in bold, File, Edit, View...), each a submenu read when it opens. Choosing an item runs the app's real command. The window comes forward first, so the command applies to it. In Automatic button size it is left out where it would cover the app's own controls, and in Chromium and Electron apps (Brave, Claude): their menus are one right-click or Option tap away |
| Tap Option to open the app's menus (Alt) | on | Press and release Option alone (under 0.6 s, no other key, modifier or click in between): the front app's menus open under its window's caption buttons (top-left of the display if it has no window). Arrow keys, Return and Esc work in it (let go of Option first: Option+Up/Down jumps to the first/last item, as in every macOS menu). Option+Tab, Option+key typing and Option-click are unaffected |
| Right-click the caption buttons | always | Windows' window menu: Restore, Minimize, Maximize, Close, then the app's menus |
| Other system tray icons | all off | Every menu bar icon, listed by name. On: shown on the taskbar right of ^. Off: in the hidden icons flyout (^). Right-click a tray icon to move it between the two |

Tray icons: each menu bar icon shows as its app's icon (a Windows tray shows app icons), system items as a symbol
(Screen Mirroring, Focus, Now Playing...). Wi-Fi, sound, Bluetooth, display, battery, clock, Control Center,
keyboard layout and Spotlight are left out: the taskbar already has them. Icons you hid in System Settings >
Menu Bar stay hidden. Clicking an icon whose menu can be read while closed (apps that attach a plain menu to their
icon) opens that menu above the tray, like Windows. Other icons (apps that build their menu on click, panels such as
Screen Mirroring or Claude's quick window) are pressed: the menu bar slides in and they open at the top right of the
main display, where macOS draws them.

The ^ flyout also keeps Fenestra's own icons: settings and permissions.

How it works: on Tahoe every menu bar icon's window belongs to Control Center, but each app still publishes its own
icons through Accessibility (`AXExtrasMenuBar`). Fenestra reads them once at start on a background queue (about 0.35
to 0.8 s of round trips over all processes, off the main thread), then only for an app that launches (1.5 s and 5 s
later), drops an app's icons when it quits, and re-reads everything when the ^ flyout opens (at most every 3 s).
Nothing is polled. App menus are read when you open them, one submenu at a time (opening the dropdown about 1 to 4
ms, a submenu 2 to 20 ms).

### Phase 6: APIs used

| Feature | API | Tier |
|---|---|---|
| Keep it hidden at the top edge | `SLSMainConnectionID` + `SLSSetMenuBarInsetAndAlpha(cid, 0, 1, alpha)` from SkyLight via `dlsym` (`System/MenuBarBlocker.swift`); Dock app element AX notifications `AXExposeShowAllWindows`, `AXExposeShowFrontWindows`, `AXExposeShowDesktop`, `AXExposeExit` | private SkyLight + Accessibility |
| Hide the menu bar | `defaults write NSGlobalDomain _HIHideMenuBar`; distributed notification `AppleInterfaceMenuBarHidingChangedNotification` (posted from `osascript -l JavaScript`, no Apple events, no Automation prompt) so running apps apply it at once | public key + undocumented notification |
| Menu bar icons | `AXExtrasMenuBar` of each app (`AXUIElementCreateApplication`), children `AXMenuBarItem` / `AXMenuExtra`: `kAXIdentifierAttribute`, `kAXDescriptionAttribute`, `kAXPositionAttribute`, `kAXSizeAttribute` | Accessibility |
| Click an icon | its `AXMenu` child read while closed (mirrored into an `NSMenu` above the tray, items pressed with `kAXPressAction`), else `kAXPressAction` on the icon itself | Accessibility |
| App menus | `kAXMenuBarAttribute` > `AXMenuBarItem` > `AXMenu` > `AXMenuItem`: `kAXTitleAttribute`, `kAXEnabledAttribute`, `kAXMenuItemMarkCharAttribute`, `kAXMenuItemCmdChar/Modifiers/Glyph/VirtualKeyAttribute`; built lazily with `NSMenuDelegate.menuNeedsUpdate`; `kAXPressAction` runs the item | Accessibility |
| Option alternates left out | AX lists them like normal items (`AXMenuItemPrimaryUIElement` points at the item itself); an item right after another with the same key plus Option is treated as its alternate | heuristic |
| Option tap | the Phase 4 `CGEventTap` thread now also sees `flagsChanged` timing for Option and mouse-down events (clicks only mark Option as used, nothing is swallowed) | Accessibility |
| Menu button, window menu | `NSMenu.popUp(positioning:at:in:)` from the caption panel (no activation: the menu tracks the keyboard while Fenestra stays in the background) | public |

### Phase 6 test checklist (about 5 minutes)

| # | Do this | Windows 11 25H2 | Fenestra should |
|---|---|---|---|
| 1 | Look at the top of both displays | no menu bar | none; windows and Maximize reach the very top |
| 2 | Move the pointer to the top edge and wait, also after opening and closing Mission Control | nothing | nothing (with "Keep it hidden" off: the macOS menu bar slides down) |
| 3 | Click ^ on the taskbar | hidden icons flyout | Claude and Screen Mirroring icons, then Fenestra's settings and permissions icons |
| 4 | Click the Screen Mirroring icon | its flyout opens above the taskbar | the menu bar slides in and Screen Mirroring opens at the top right |
| 5 | Right-click Claude's icon > Show on the taskbar | (Windows: drag it out of the flyout) | the icon moves next to ^; right-click > Hide in the overflow menu puts it back |
| 6 | Taskbar settings > Other system tray icons | per-app switches | same list, same effect |
| 7 | In a TextEdit or Finder window, click the three-line button right of close | (Notepad: File, Edit, View in the title bar) | dropdown with Apple menu, app menu, File, Edit, View...; hover File, choose New: the app's own command runs |
| 8 | Tap Option alone in Finder | Alt: menu bar keyboard focus | Finder's menus open under its caption buttons; Down, Right, Return work; Esc closes |
| 9 | Option+Tab, then type Option+A in a text field, Option-click a link | unaffected | no menu opens |
| 10 | Right-click a window's caption buttons | window menu: Restore, Move, Size, Minimize, Maximize, Close | Restore, Minimize, Maximize, Close, then the app's menus |
| 11 | Claude or Brave window | n/a | no menu button (it would cover tabs or toolbar); right-click and Option tap give the menus |
| 12 | Windows settings > turn off "Hide the macOS menu bar", then on | n/a | the menu bar appears at once, then hides again |
| 13 | `top -pid $(pgrep -x Fenestra)` with nothing moving | n/a | under 1% CPU (measured 0.0%, 33 MB) |

Diagnostics (read-only, needs `captionDebug`): distributed notification `local.fenestra.debug.menubar` with object
"dump" (every app's icons, the menu bar windows, icon captures to ~/Library/Logs/Fenestra-dragtest/extra-*.png),
"build Finder" (the dropdown Fenestra would show, logged; nothing opens), "attrs Finder" (AX attributes of the Apple
menu items) or "press <identifier or bundle ID>" (presses one icon, logs where its menu opened, then closes it with
Esc). Results: `grep menubartest ~/Library/Logs/Fenestra-app.log`.

### Phase 6: still different from real Windows 11

- The menu bar is auto-hidden and invisible, not gone: it still exists, and menus of menu bar icons still open under
  where it would be. With SIP on there is no way to remove it outright.
- Menus of most menu bar icons, and panels such as Screen Mirroring, open at the top right of the main display under
  the menu bar (macOS draws them there; another app's menus and panels can't be moved). Only icons whose menu can be
  read while closed open above the tray.
- Tray icons are app icons, not the live menu bar glyphs: those windows are off screen while the menu bar is hidden,
  so they can't be captured. Icons that show text or live values (CPU meters, timers) don't show that in the tray.
- New menu bar icons appear when their app launches (checked 1.5 s and 5 s later) or when you open ^. An icon an
  already running app adds later shows up the next time you open ^.
- Right-clicking a tray icon shows Fenestra's menu (Open, Show on the taskbar / Hide in the overflow menu, Taskbar
  settings), not the app's own right-click menu (Claude's: usage limits, Quit). Claude's icon offers only `AXPress`
  through Accessibility (`AXShowMenu` is refused), and a right-click event posted to the hidden icon's Control Center
  window does nothing. The remaining route (slide the menu bar in by moving the pointer to the top edge, right-click
  the real icon, put the pointer back) is untested and undecided.
- Moving icons between the taskbar and ^ is a right-click menu or the settings list, not drag and drop. No
  reordering: icons keep the menu bar's order.
- App menus have no item icons, and a few Control-key alternates still show (Finder's "Get Summary Info"). Items
  drawn with custom views show by title only. Menus are read when opened, so an app that updates a menu only as it
  appears in the real menu bar may show it as of the last time it was opened there.
- Option tap opens the menus as a dropdown; Windows' Alt underlines access keys in the window's own menu bar.
  The window menu's Move and Size came in the polish pass.
- Chromium and Electron windows get no menu button in Automatic size (no reliable way to see their title bar
  controls); choose "Windows size" or "Compact" to force it.

## Clipboard history (Control+Option+V)

Windows key + V. Everything you copy (text, images, and files copied in Finder) is kept in a list; press
Control+Option+V to open it at the text cursor and click an item (or press Return on it) to paste it into the app you
were typing in. Options: Fenestra settings > **Windows** > Clipboard (Windows: Settings > System > Clipboard).

| Setting or control | Default | Does |
|---|---|---|
| Clipboard history | on | Off: copies are no longer watched (no timer runs) and the history is cleared (pinned items stay). Control+Option+V then shows "Clipboard history is off" with a Turn on button, as on Windows |
| Items to keep | 25 (Windows) | 10, 25, 50 or 100 unpinned items; the oldest unpinned item drops off. Pinned items don't count |
| Clear clipboard data | button | Clears the history except pinned items, and what is on the clipboard now (Windows' Clear) |
| Clear all (in the flyout) | button | Removes every item except pinned ones |
| ... on an item (See more) | | Turns into Delete (trash) and Pin / Unpin. Pinned items show a pin and are listed first |

Scope decided with you (2026-11-15): 25 items by default and configurable; **memory only**, so the history, pinned
items included, starts empty when Fenestra restarts (Windows keeps pinned items); clicking pastes into the front
app; pin, delete and Clear all as on Windows; files copied in Finder are kept too (Windows doesn't).

What is kept: plain text, plus its rich text (RTF) and HTML when the whole item stays under 4 MB, so formatting comes
back when you paste; images as PNG (TIFF and JPEG copies are converted once) with a 640 px preview; file references
(not the file contents). Items over 4 MB are left out, as on Windows. Copies that password managers and similar apps
mark as concealed or transient (nspasteboard.org types, 1Password, KeeWeb) are never kept. The log shows each item's
kind and size, never its content.

How it works: macOS has no notification for clipboard changes, so a background queue compares
`NSPasteboard.changeCount` every 0.5 s (0.25 s leeway so the wakeup is batched with others). That call takes about
1 microsecond (measured: 0.0002% of a core at two checks a second). Content is read only when the count changes,
80 ms later so a copy written in several steps has settled, and off the main thread. Opening the flyout checks at
once, so a copy made a moment ago is already there. The flyout never takes keyboard focus: while it is open the
existing Phase 4 event tap passes Up, Down, Return and Esc to it, and the app keeps its text cursor, so the paste
(the item goes on the clipboard, then Command+V is sent) lands where you were typing. Any other key closes it and
goes to the app.

### Clipboard history: APIs used

| Feature | API | Tier |
|---|---|---|
| Notice copies | `NSPasteboard.general.changeCount` on a `DispatchSourceTimer` (0.5 s, 0.25 s leeway, utility queue) | public |
| Read a copy | `NSPasteboard.types`, `string(forType:)`, `data(forType:)` for `.string`, `.rtf`, `.html`, `.png`, `.tiff`, `public.jpeg`; `readObjects(forClasses: [NSURL], options: [.urlReadingFileURLsOnly])` | public, subject to macOS pasteboard privacy (`NSPasteboard.accessBehavior`, macOS 15.4) |
| Leave out passwords | nspasteboard.org marker types (`org.nspasteboard.ConcealedType`, `TransientType`, `AutoGeneratedType`) and 1Password's own | convention |
| Images | ImageIO: `CGImageSourceCreateThumbnailAtIndex` (preview), `CGImageDestination` (PNG) | public |
| Duplicates | CryptoKit `SHA256` of the text, PNG or file list: copying the same thing again moves it to the top | public |
| Paste | `NSPasteboard.writeObjects` (one `NSPasteboardItem` with every kept type, plus TIFF for images; file URLs for files), then Command+V as `CGEvent` posted to `.cghidEventTap` | public + Accessibility |
| Control+Option+V and the flyout's keys | the Phase 4 `CGEventTap` thread (`HotKeys`): key code 9 with Control+Option; while open, key codes 125, 126, 36, 76, 53 | Accessibility |
| Open at the text cursor | `AXUIElementCreateSystemWide` > `kAXFocusedUIElementAttribute` > `kAXSelectedTextRangeAttribute` > `kAXBoundsForRangeParameterizedAttribute` (background thread, 0.2 s timeout); the pointer when that fails | Accessibility |
| Flyout | `FlyoutManager` (`FlyoutChrome`, `FirstClickHostingView`, `ArrowCursor`), `FlyoutPanel` with `keyable = false` so it never becomes the key window | public (+ the existing private cursor property) |

### Clipboard history test checklist (about 5 minutes)

| # | Do this | Windows 11 25H2 | Fenestra should |
|---|---|---|---|
| 1 | In TextEdit, type a line, select a word, Command+C; select another word, Command+C | both are in the history | same |
| 2 | Press Control+Option+V | panel opens at the text cursor on the Clipboard tab, newest first, first item focused | flyout under the text cursor: "Clipboard history", Clear all, newest first, first item outlined |
| 3 | Press Down, then Return | the second item is pasted at the cursor | same; the flyout closes and TextEdit keeps focus |
| 4 | Take a screenshot to the clipboard (Control+Shift+Command+4), open the history | image item with a preview | image preview at the top |
| 5 | Click the image item with TextEdit (rich text) in front | image is pasted | image is pasted |
| 6 | In Finder, select two files, Command+C, open the history | (files aren't kept) | "2 items" with the first file's icon and both names; clicking it in a Finder window pastes (copies) the files |
| 7 | On an item click ..., then the pin | item pinned | pin shows, item moves to the pinned group at the top |
| 8 | Click Clear all | everything except pinned items goes | same |
| 9 | ... on the pinned item > trash | item deleted | same |
| 10 | Copy a password from a password manager, open the history | not kept when the manager excludes it | not kept (log: `left out a copy marked concealed or transient`) |
| 11 | Open the history in a Claude or Brave text field, then press any letter | (panel at the cursor) | flyout at the text cursor, or at the pointer if the app doesn't publish it (the log says which); the letter closes it and is typed |
| 12 | Settings > Windows > Clipboard: Items to keep 10, copy 12 things | (fixed at 25) | 10 unpinned items |
| 13 | Turn Clipboard history off, press Control+Option+V | "turn on" prompt | "Clipboard history is off" with Turn on |
| 14 | `top -pid $(pgrep -x Fenestra)` with nothing moving | n/a | under 1% CPU (measured 2026-11-15: 0.0% in 11 of 12 samples, 0.2% in one, 42 MB, after 15 to 74 s with no input) |

Diagnostics (read-only): distributed notification `local.fenestra.debug.clipboard` with object "open" (toggles the
flyout like Control+Option+V) or "list" (logs each item's kind, size and types, no content). Results:
`grep -E "clipboard|cliptest" ~/Library/Logs/Fenestra-app.log`.

### Clipboard history: still different from real Windows 11

- Only the clipboard: no emoji, GIF, kaomoji or symbols tabs and no search box (not wanted), no sync across
  devices, no suggested actions.
- Memory only (your choice): pinned items don't survive a Fenestra restart; Windows keeps them across restarts.
- Files copied in Finder are kept (your choice); Windows' history ignores them. Only references are kept: a file
  moved or deleted afterwards can't be pasted from the history.
- Not checked against a real Windows PC: where pinned items sit (Fenestra lists them first), whether pasting an older
  item moves it to the top (Fenestra moves it), and whether copying the same text twice makes one entry or two
  (Fenestra makes one).
- Copies are noticed within 0.5 s; if two copies replace each other faster than that, only the second is kept.
- Keyboard: Up, Down, Tab, Shift+Tab, Return and Esc (Tab reaches ..., then Delete and Pin, since the polish pass).
  Space isn't taken, so typing carries on; Windows also accepts Space on a focused button.
- Opens at the pointer in apps that don't publish their text cursor through Accessibility (not yet checked per app;
  Chromium and Electron apps are the likely ones). Each opening logs `flyout at text cursor` or `flyout at pointer`.
- Only plain text, RTF, HTML, images and file references come back when pasting from the history; app-private
  formats (Keynote shapes, Figma layers) don't. Windows' history has the same limit (text, HTML, bitmaps).
- The 4 MB limit is checked on the kept data (the PNG for images, which is usually smaller than the copied TIFF).
- Memory grows with images: at most the number of items times 4 MB, typically far less (Fenestra used 42 MB in
  all after the tests, 34 MB before).
- macOS may ask once whether Fenestra may read what other apps copy (pasteboard privacy, macOS 15.4 and later).

## Polish pass: closer to Windows 11 (2026-11-15)

Picked by the user from the "still different" lists above (the Windows-styled jump list, tooltips and tray drag and
drop were declined, except End task).

- **End task.** Right-click a running taskbar app: End task (just above Close window, as on Windows 11) force quits
  every process of the app, like Force Quit in the Apple menu. Unsaved changes are lost. Finder never shows it
  (your choice; Windows offers it for File Explorer).
  Setting: Taskbar settings > Taskbar behaviors > "End task" (on by default because you asked for it; Windows hides
  it under Settings > System > For developers).
- **Each taskbar acts on its own display.** With "Show my taskbar apps on" set to "Taskbar where window is open" (or
  the other taskbars with "Main taskbar and taskbar where window is open"): a button's click, its hover thumbnails,
  its right-click "Close window / Close all windows" count, and its highlight use only the windows on that taskbar's
  display (the main taskbar also takes displays without a taskbar). A pinned app whose windows are all on another
  display shows no running pill on the main taskbar, and clicking it opens a new window (Windows starts a new one).
  Close all windows there closes only that display's windows; the app quits only if those were all of them.
- **Windows key + Z numbers (Control+Option+Z).** The Snap Layouts flyout opens with a number on each layout. Press
  the number of a layout, then the number of a zone. Arrow keys move the highlight and Return picks, Esc or any other
  key closes it. Digits work on the top row and the keypad, on every keyboard layout.
- **Alt+Space (Option+Space).** Opens the focused window's window menu at its top-left corner, also for windows
  without Fenestra's buttons. Setting: Windows tab > Menu bar and app menus > "Option+Space opens the window menu".
  Option+Space no longer types a non-breaking space while this is on, and apps that use Option+Space as a global
  shortcut (some launchers) lose it.
- **Move and Size in the window menu.** Windows order: Restore, Move, Size, Minimize, Maximize, Close (Move and Size
  are off while maximized). Move: arrow keys move the window by 10 points. Size: the first arrow picks the edge
  (Left = left edge, Up = top edge; a second direction adds the other edge, for a corner), the next arrows move it.
  Return or a click keeps it, Esc puts the window back. A label at the top of the display says which keys work.
- **Tab in clipboard history.** Tab moves from the selected item to its ... (See more), then Delete and Pin once ...
  is open; Shift+Tab goes back; Return activates; Up and Down go to the next item and start from the item again.
- **Snap groups.** Windows placed together through Snap Assist (one snapped, the others picked for the rest of the
  layout) form a group. Hover a taskbar app with a window in a group: the group shows before its window thumbnails,
  as a miniature of the layout with each window in its zone. Click it: every window of the group comes back
  (restored if minimized), with the hovered app's window in front. A window leaves the group when it is no longer
  where it was snapped (dragged away, resized, maximized, closed, snapped elsewhere); a group of one is gone.

### Polish pass: APIs used

- End task: `NSRunningApplication.forceTerminate()` (public).
- Per-display scope: window frames through Accessibility, the display holding each window's center (`Displays`).
- Win+Z numbers, Option+Space, Move/Size keys, clipboard Tab: the existing HotKeys `CGEventTap` (keyboard modes on
  its own thread; key codes are layout positions). Move/Size: AX `kAXPositionAttribute` / `kAXSizeAttribute`.
- Snap groups: Fenestra's own record of where it snapped each window (`WindowSnap`), checked against AX frames
  when the group is read; restore with AX minimize/raise and `NSRunningApplication.unhide()`.

### Polish pass test checklist (about 5 minutes)

1. Right-click a running app on the taskbar: End task sits above Close window. Try it on TextEdit with an empty
   document: TextEdit quits at once, no save question.
2. Settings > Taskbar > "When using multiple displays, show my taskbar apps on" = "Taskbar where window is open".
   Put a Safari window on the portable display only: the main taskbar's Safari icon has no pill; clicking it opens a
   new Safari window. Hover the portable taskbar's Safari button: only that display's window in the thumbnails.
   (Set it back to "All taskbars" afterward if that's your preference.)
3. Focus a window, press Control+Option+Z: numbers on the layouts. Press 1, then 2: the window fills the right half.
   Again with Right arrow, Return, Return: the left two thirds. Control+Option+Z then Esc: nothing changes.
4. Press Option+Space: the window menu opens at the window's top-left. Choose Move, press arrows, then Return.
   Option+Space > Size, Right (picks the right edge), Right Right, Return: the window is 20 points wider. Esc during
   Move puts the window back. Check that arrow keys work inside the menu itself.
5. Control+Option+V, Tab: the ... button gets a ring. Return opens Delete and Pin, Tab moves to them, Shift+Tab back.
6. Snap a window to the left half by dragging it to the left edge, pick a second window in Snap Assist. Minimize both.
   Hover either app on the taskbar: a group card with both windows in their halves; click it: both come back.
   Drag one away, hover again: the group card is gone.

Automated test (moves windows and presses keys for about 30 s; warn first): `defaults write local.fenestra.Fenestra
captionDebug -bool true`, restart, post object "TextEdit polish" on `local.fenestra.debug.dragtest`; results in the
app log (`polishtest`) and ~/Library/Logs/Fenestra-dragtest/polish.txt. Run on 2026-11-15: 14/14 PASS.

### Polish pass: still different from real Windows 11

- End task can't be undone and doesn't ask, like Windows. It force quits all processes of the app (Windows ends
  the app's process tree).
- On the main taskbar, clicking a pinned app whose windows are all elsewhere asks the app for a new window
  (Command-N or its New Window menu item); macOS decides which display it opens on.
- Win+Z: a number pressed outside the layout's range is ignored; Windows ignores it too. Esc closes instead of
  going back one step.
- Move/Size are keyboard only: moving the mouse doesn't move the window (Windows lets the mouse take over). There is
  no four-way pointer, a label instead (macOS doesn't let a background app change the pointer over other apps).
  Steps are 10 points; apps may refuse some sizes (Terminal's character cells), and Size continues from what they took.
- Snap groups form only through Snap Assist (as on Windows 11), are kept in memory (not across a Fenestra restart),
  and aren't shown in Alt+Tab or Task View. The group card is a still miniature, and hovering it doesn't preview the
  group on the desktop.

## More switches in Settings (2026-11-15)

Asked for so that (almost) everything Fenestra does can be turned off. Defaults keep today's behavior.

| Where | Switch | Default |
|---|---|---|
| Taskbar > Taskbar behaviors | The corner shows the desktop on every display (off: only its own display) | off |
| Start > Start | Tap Command alone to open Start (Windows key) | on |
| Windows > Title bar buttons | Closing an app's last window quits the app (Finder stays open); off = Mac behavior, also for the jump list's Close window(s) | on |
| Windows > Snap windows | Show my snapped windows when I hover over taskbar apps (snap groups) | on |
| Windows > Switching windows | Control+Option+Tab opens Task view; Control+Option+D shows the desktop on every display | on |
| Fenestra > macOS changes | one switch per group of macOS settings Fenestra changes (see "Every system change Fenestra makes") | all on |

Still fixed: the Control+Option key choice itself (Windows key = Control+Option, Alt = Option), and the hiding of the
taskbar for full-screen windows (Windows has no switch for that either).

## Quick snap (2026-11-15)

Fast drags were let go just before the edge, so they didn't snap (Windows needs the pointer at the edge too). Also,
after a few idle seconds an app may report its window's move to Accessibility late (after the release), or not
at all in time. Settings > Windows > Snap windows > Quick snap: Off / Gentle / Normal (default) / Strong
(`QuickSnap.Tuning` in Settings.swift).

How a release short of an outer edge still snaps (DragSnap.swift):

| Rule | Normal | What it means |
|---|---|---|
| Top magnet | 40 pt | let go this close below the top of a display = touching it |
| Close call | 120 pt, 400 pt/s or 60 pt in 0.25 s | near an outer edge and still moving toward it, or having come toward it |
| Throw | 1200 pt/s, 0.3 s, 600 pt | moving fast enough to reach the edge within that time and distance |

Edges shared with another display never count (the pointer passes through them). Zones: half at a side edge,
quarter near a top corner (64 pt), maximize at the top.

Where the release is seen (all three apply the same rules):

1. A drag session (window moved while the button was down): pointer samples from the drag event tap.
2. The first window move arrives after the release (`quickDrag`): samples from a global monitor that records
   `leftMouseDragged` positions only while a button is held.
3. No move reported at all 0.15 s after the release (`releaseCheck`): the window under the press (one
   `CGWindowListCopyWindowInfo` per click) is compared with its position now; if it moved with the pointer it was a
   title bar drag.

Every drag logs one line: `drag: <id> ended (...) after N ms, N pointer updates, last at x,y, up at x,y, zone ...`
with the rule that matched or why nothing did (speed, distance to the edge). Idle cost: none (measured 0.0% CPU).

## Flyout opening speed (2026-11-15)

Quick Settings and the calendar are built ahead of time: Fenestra keeps one drawn, hidden copy of each
(`FlyoutManager.prepare(id:)`, made 1.5 s after launch and again 0.5 s after each close, so every opening still
starts from a fresh view; a copy from another day is rebuilt so the calendar's date is right). Opening one only
positions and shows it. Quick Settings re-reads Wi-Fi, Bluetooth and the other tile states when it opens
(`FlyoutManager.didShow`). Every flyout draws its first frame before the slide-up starts, so the slide begins
at the bottom instead of jumping most of the way in one frame.

| Measure (switching Quick Settings / calendar) | Before | After |
|---|---|---|
| Click to first movement | 58 to 145 ms | 3 to 15 ms |
| First visible frame | ~60% of the slide | at the bottom |
| Idle CPU / memory | 0.0% / 33 to 42 MB | 0.0% / ~60 MB |

Diagnostics (needs `captionDebug`): distributed notification `local.fenestra.debug.flyout` (any object) opens Quick
Settings, switches to the calendar and back, and logs each step's timeline (`grep flyouttest
~/Library/Logs/Fenestra-app.log`). Each opening logs `flyout: <id> prepared|built now, animation starts N ms after
the click`.
