# Fenestra

A Windows 11 style desktop for your Mac: taskbar, Start menu, Quick Settings, title bar buttons, window snapping,
Alt+Tab, Task view and clipboard history.

Requires macOS Tahoe (26) or later. No Xcode or developer tools needed.

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
