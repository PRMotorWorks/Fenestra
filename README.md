# Fenestra

A Windows 11 style desktop for your Mac: taskbar, Start menu, Quick Settings, title bar buttons, window snapping,
Alt+Tab, Task view and clipboard history.

Requires macOS Tahoe (26) or later. No Xcode or developer tools needed.

## What it brings from Windows 11

**Taskbar**
- Start, Search and Task view buttons, then your pinned and open apps, centered or left aligned.
- A line under open apps, longer for the app in front. Drag icons to reorder; right-click to pin or unpin.
- Hover an app for previews of its windows (close a window from its preview). Click to switch, click again
  to minimize, as on Windows.
- Right-click an app for its jump list: recent files, open a new window, pin, Close window and End task.
  Middle-click opens a new window.
- Unread badges, smaller buttons when full, and optional labels (one button per window).
- The far right corner shows the desktop. Auto-hide is available, and the taskbar hides for full-screen videos,
  games and full-screen windows.

**System tray and Quick Settings**
- Wi-Fi, sound and battery icons open Quick Settings: Wi-Fi and Bluetooth lists to connect devices, volume and
  brightness sliders (external monitors too), and tiles for Airplane mode, Battery saver, Night light, Focus,
  Nearby sharing (AirDrop), Cast, Accessibility, Keyboard layout and Live captions.
- Edit the tiles like on Windows (pencil button): reorder them, remove them, or add Mac extras such as Dark mode,
  screenshots, Quick Note and Calculator.
- The clock opens a calendar; the bell keeps notifications you've received.
- The ^ arrow holds the Mac's menu bar icons; any of them can sit on the taskbar instead.

**Start menu**
- Pinned apps, a Recommended section with recent apps and files, and All apps (by category, list or grid).
- Type to search apps, files and settings.
- Folder shortcuts and the power menu at the bottom (Sleep, Restart, Shut down, Lock, Sign out).
- Right-click Start for the Windows key + X menu.

**Windows**
- Minimize, maximize and close buttons replace the colored traffic lights, plus a menu button with the app's
  menus (File, Edit...), since the Mac menu bar is hidden.
- Maximize fills the screen above the taskbar. Closing an app's last window quits the app, like on Windows.
- Right-click the buttons, or press Option+Space, for the window menu: Restore, Move, Size, Minimize, Maximize,
  Close. Tap Option alone to open the app's menus, like Alt.

**Snapping**
- Drag a window to a screen edge or corner to snap it to half or a quarter, with a preview first. Drag it away
  and it gets its old size back.
- Quick snap (a Mac extra): throw a window toward an edge and let go a little early, and it still snaps there.
  Choose Off, Gentle, Normal or Strong in Taskbar settings > Windows.
- Drag a window to the top of the screen for the snap layouts bar, or hover the maximize button for Snap Layouts
  (halves, thirds, quarters and more). Control+Option+Z opens them from the keyboard, with numbers to pick a spot.
- Snap Assist fills the rest of the layout with your other windows. Windows snapped together form a group that
  comes back together from the taskbar.

**Switching windows**
- Option+Tab: the Alt+Tab switcher with window previews.
- Task view: every open window at a glance, from its taskbar button or Control+Option+Tab.
- Control+Option+D shows the desktop.

**Clipboard history**
- Control+Option+V shows the last things you copied: text, images and files. Paste any of them, pin favorites,
  or delete them.

**Multiple displays**
- A taskbar on every display, each with its own clock and show-desktop corner.
- Unplug a monitor and its windows minimize; plug it back in and they return to where they were.

Almost everything can be switched off in Taskbar settings, including each change Fenestra makes to macOS. Quitting
or uninstalling puts your Dock, menu bar and Mac settings back.

## Install

1. **Download:** go to [Releases](https://github.com/PRMotorWorks/Fenestra/releases/latest) and click
   **Fenestra-1.0.dmg** under Assets.
2. **Copy:** open the downloaded file and drag **Fenestra** onto the **Applications** folder in the window that
   appears. Then eject the disk image.
3. **Open:** double-click **Fenestra** in your Applications folder.
4. **Allow it (first time only):** macOS says it can't verify Fenestra. Click **Done**, open
   **System Settings > Privacy & Security**, scroll down and click **Open Anyway** next to "Fenestra was blocked",
   then **Open Anyway** again and enter your Mac password.
5. **Wait a few seconds:** the taskbar appears at the bottom of the screen and the Dock and menu bar hide.
   Fenestra now starts by itself at every login.
6. **Give permissions:** in the window Fenestra shows, turn on **Accessibility** (required) and
   **Screen & System Audio Recording** (for window previews) in the System Settings pages it opens.

That's it. The full guide, with permissions, updating and troubleshooting, is in [INSTALL.md](INSTALL.md); the
disk image includes it too.

## Use

| Windows | Mac with Fenestra |
|---|---|
| Windows key | tap **Command** alone |
| Windows key + arrows | **Control+Option+arrows** |
| Windows key + Z | **Control+Option+Z** |
| Windows key + Tab | **Control+Option+Tab** |
| Windows key + D | **Control+Option+D** |
| Windows key + V | **Control+Option+V** |
| Alt+Tab | **Option+Tab** |

Settings: right-click an empty part of the taskbar > **Taskbar settings**.

## Uninstall

Taskbar settings > **Fenestra** tab > **Uninstall…**. Your Dock, menu bar and Mac settings go back to how they were.

## For developers

Building from source needs Xcode: see [DEVELOPMENT.md](DEVELOPMENT.md).
