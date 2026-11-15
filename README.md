<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="Fenestra icon">
</p>

<h1 align="center">Fenestra</h1>

<p align="center">
  <b>The Windows 11 desktop, on your Mac.</b><br>
  Taskbar, Start menu, Quick Settings, Snap Layouts, Alt+Tab, Task view and clipboard history.<br>
  Native, free, and fully reversible.
</p>

<p align="center">
  <a href="https://github.com/PRMotorWorks/Fenestra/releases/latest/download/Fenestra.dmg"><img src="https://img.shields.io/badge/Download-Fenestra%20for%20Mac-2F6BEA?style=for-the-badge&logo=apple&logoColor=white" alt="Download Fenestra for Mac"></a>
</p>

<p align="center">
  <a href="https://github.com/PRMotorWorks/Fenestra/releases/latest"><img src="https://img.shields.io/github/v/release/PRMotorWorks/Fenestra?label=version&color=2F6BEA" alt="Latest version"></a>
  <img src="https://img.shields.io/badge/macOS-Tahoe%2026%2B-0B1E4A?logo=apple" alt="macOS Tahoe 26 or later">
  <img src="https://img.shields.io/badge/Apple%20silicon%20%2B%20Intel-universal-0B1E4A" alt="Universal app">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-1FB5A3" alt="MIT license"></a>
  <a href="https://github.com/PRMotorWorks/Fenestra/releases"><img src="https://img.shields.io/github/downloads/PRMotorWorks/Fenestra/total?color=FF8A5B" alt="Downloads"></a>
</p>

<p align="center">
  <img src="docs/images/hero.jpg" alt="Fenestra's taskbar and Start menu on macOS" width="900">
</p>

Switched from Windows and miss the taskbar? Use a PC at work and a Mac at home? Fenestra replaces the Dock and menu
bar with the Windows 11 desktop you already know: same buttons, same shortcuts, same muscle memory. It's a native
Mac app, it idles at 0% CPU, and quitting it puts your Mac back exactly how it was.

## Features

### Taskbar and Start

<img src="docs/images/start-menu.jpg" alt="Start menu with pinned apps, recommended files and all apps" width="100%">

- **Start menu** with pinned apps, recent files, and All apps by category, list or grid. Type to search apps,
  files and settings. Tap **Command** alone to open it, like the Windows key.
- **Taskbar** with your pinned and open apps, centered or left aligned, with the running-app line under each icon.
- Click to switch, click again to minimize. Drag to reorder, middle-click for a new window, unread badges included.
- The far right corner shows the desktop. Auto-hide is available, and the taskbar steps aside for full-screen video.

<p>
  <img src="docs/images/taskbar-preview.jpg" alt="Window previews when hovering a taskbar app" width="100%">
  <img src="docs/images/jump-list.jpg" alt="Jump list on right-click" width="100%">
</p>

Hover an app for live previews of its windows. Right-click it for the jump list: recent files, new window, pin,
Close window and End task.

### Quick Settings and the calendar

<p>
  <img src="docs/images/quick-settings.jpg" alt="Quick Settings" width="49%">
  <img src="docs/images/calendar.jpg" alt="Notifications and calendar" width="40%">
</p>

- **Quick Settings:** Wi-Fi and Bluetooth lists to connect devices, volume and brightness sliders (external
  monitors too), and tiles for Airplane mode, Battery saver, Night light, Focus, Nearby sharing (AirDrop), Cast,
  Accessibility, Keyboard layout and Live captions.
- Edit the tiles like on Windows: reorder, remove, or add Mac extras such as Dark mode, screenshots, Quick Note and
  Calculator.
- Live tooltips on the tray icons, scroll over the speaker to change the volume, and a charging badge on the battery.
- The clock opens the calendar and your notifications. The **^** arrow holds the Mac's menu bar icons.

### Snap Layouts and Snap Assist

<img src="docs/images/snap-layouts.jpg" alt="Snap Layouts when hovering the maximize button" width="100%">

- Every window gets Windows-style **minimize, maximize and close** buttons, plus a menu button with the app's menus
  (File, Edit...), since the menu bar is hidden.
- Hover maximize for **Snap Layouts** (halves, thirds, quarters), or drag a window to an edge or corner to snap it.
- **Quick snap** (a Mac extra): fling a window toward an edge and let go early, and it still lands there.

<img src="docs/images/snap-assist.jpg" alt="Snap Assist offering the other windows to fill the rest of the screen" width="100%">

**Snap Assist** fills the rest of the screen with your other windows. Snapped windows form a group that comes back
together from the taskbar.

### Alt+Tab and Task view

<img src="docs/images/alt-tab.jpg" alt="Alt+Tab window switcher" width="100%">

<img src="docs/images/task-view.jpg" alt="Task view showing every open window" width="100%">

**Option+Tab** switches windows with live previews, and **Task view** shows everything at a glance.

### Clipboard history

<img src="docs/images/clipboard-history.jpg" alt="Clipboard history with text, a link and an image" width="40%" align="right">

**Control+Option+V** shows the last things you copied: text, links, images and files. Paste any of them, pin
favorites, or delete them. Passwords copied from password managers are never saved.

### Multiple displays

A taskbar on every display, each with its own clock and show-desktop corner. Unplug a monitor and its windows
minimize; plug it back in and they return to where they were.

<br clear="right">

## Keyboard shortcuts

| On Windows | On a Mac with Fenestra | Does |
|---|---|---|
| Windows key | tap **Command** | Start |
| Windows + arrows | **Control+Option+arrows** | Snap windows |
| Windows + Z | **Control+Option+Z** | Snap layouts |
| Windows + Tab | **Control+Option+Tab** | Task view |
| Windows + D | **Control+Option+D** | Show desktop |
| Windows + V | **Control+Option+V** | Clipboard history |
| Alt+Tab | **Option+Tab** | Switch windows |
| Alt | tap **Option** | App menus |
| Alt+Space | **Option+Space** | Window menu |

## Install

1. **[Download Fenestra.dmg](https://github.com/PRMotorWorks/Fenestra/releases/latest/download/Fenestra.dmg)**,
   open it, and drag **Fenestra** onto **Applications**.
2. Open Fenestra from Applications. macOS says it can't verify the app (Fenestra isn't notarized by Apple yet):
   click **Done**, then go to **System Settings > Privacy & Security**, scroll down and click **Open Anyway**.
   You only do this once.
3. After a few seconds the taskbar appears, and the Dock and menu bar hide.
4. Turn on **Accessibility** (required) and **Screen & System Audio Recording** (for window previews) in the
   window Fenestra shows.

Right-click an empty part of the taskbar for **Taskbar settings**. Almost everything can be switched off there.
The full guide, with updating and troubleshooting, is in [INSTALL.md](INSTALL.md).

## FAQ

<details>
<summary><b>Does it change my Mac permanently?</b></summary>

No. Fenestra hides the Dock and menu bar while it runs and records every setting it changes. Quitting puts them
back, and **Taskbar settings > Fenestra > Uninstall…** removes the app and everything it created. If it ever
crashes, your Dock and menu bar come back immediately. Even dragging it to the Trash is handled: your settings are
restored at the next login.
</details>

<details>
<summary><b>Why does macOS warn me the first time?</b></summary>

Apple only skips that warning for apps signed with a paid Apple Developer ID and notarized. Fenestra is signed but
not notarized yet. The code is all here: you can read it, or build it yourself with Xcode (see
[DEVELOPMENT.md](DEVELOPMENT.md)).
</details>

<details>
<summary><b>Does it collect data or need the internet?</b></summary>

No. Fenestra has no network code at all: no analytics, no accounts, no update pings. Screen Recording is used only
for live window thumbnails; nothing is recorded or saved. Location access, if you grant it, is only because macOS
hides Wi-Fi network names without it.
</details>

<details>
<summary><b>Will it slow my Mac down?</b></summary>

It idles at 0% CPU and uses about 40 MB of memory. It's a single native AppKit and SwiftUI app, not a web wrapper.
</details>

<details>
<summary><b>Which Macs does it run on?</b></summary>

Any Mac running macOS Tahoe (26) or later, Apple silicon or Intel.
</details>

<details>
<summary><b>Can I keep some Mac things, like the menu bar?</b></summary>

Yes. Every change Fenestra makes to macOS has its own switch in **Taskbar settings > Fenestra > macOS changes**, and
most features can be turned off one by one.
</details>

## Uninstall

Taskbar settings > **Fenestra** tab > **Uninstall…**. Your Dock, menu bar and Mac settings go back to how they were.

## Building from source

Fenestra builds with Xcode and has no dependencies. See [DEVELOPMENT.md](DEVELOPMENT.md) for the architecture,
every system change it makes, and test checklists. Bug reports and pull requests are welcome.

## License

[MIT](LICENSE). Fenestra is an independent project and is not affiliated with, endorsed by, or sponsored by
Microsoft. Windows is a trademark of Microsoft Corporation, used here only to describe what Fenestra does.
