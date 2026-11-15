# Installing Fenestra

Fenestra gives your Mac a Windows 11 style taskbar, Start menu, title bar buttons, window snapping and more.
No Xcode or developer tools are needed.

**Requires:** macOS Tahoe (26) or later. About 5 minutes.

## 1. Copy Fenestra to Applications

1. Open **Fenestra.dmg** (double-click it).
2. In the window that opens, drag **Fenestra** onto the **Applications** folder.
3. Eject the disk image (the eject button next to "Fenestra" in Finder's sidebar).

## 2. Open Fenestra the first time

1. Open the **Applications** folder and double-click **Fenestra**.
2. If macOS says it can't verify Fenestra:
   1. Click **Done** (not Move to Bin).
   2. Open **System Settings > Privacy & Security** and scroll down to **Security**.
   3. Next to "Fenestra was blocked to protect your Mac", click **Open Anyway**, then **Open Anyway** again and
      enter your Mac password.

   You only do this once. (A copy of Fenestra signed by a registered Apple developer skips this step.)
3. Fenestra sets itself up to start at every login and restarts itself. After a few seconds the taskbar appears
   at the bottom of the screen and the Dock and menu bar hide.

## 3. Give Fenestra its permissions

A Fenestra window lists the permissions. Each opens the right page of System Settings:

| Permission | Needed for |
|---|---|
| **Accessibility** (required) | the taskbar's window buttons, title bar buttons, snapping, Alt+Tab, keyboard shortcuts |
| **Screen & System Audio Recording** (recommended) | window thumbnails and matching title bar colors. Nothing is recorded or saved |
| **Location** (optional) | showing Wi-Fi network names (macOS hides them otherwise; your location is never read) |

macOS may also ask once for Bluetooth, for pasting from other apps (choose **Allow**), and to control System
Events (for Restart and Shut down in Start). If something doesn't work right after you grant a permission,
right-click an empty part of the taskbar, choose **Quit Fenestra and restore the Dock**, and open Fenestra from
Applications again.

You can reopen the permissions list any time: right-click the taskbar > **Permissions…**.

## 4. Make it yours

Right-click an empty part of the taskbar > **Taskbar settings**. Almost everything can be switched on or off there,
including each change Fenestra makes to macOS (Settings > Fenestra > macOS changes).

| Windows | On a Mac with Fenestra |
|---|---|
| Windows key | tap **Command** alone (opens Start) |
| Windows key + arrows | **Control+Option+arrows** (snap windows) |
| Windows key + Z | **Control+Option+Z** (snap layouts; then press numbers) |
| Windows key + Tab | **Control+Option+Tab** (Task view) |
| Windows key + D | **Control+Option+D** (show desktop) |
| Windows key + V | **Control+Option+V** (clipboard history) |
| Alt+Tab | **Option+Tab** |
| Alt (menus) | tap **Option** alone |
| Alt+Space | **Option+Space** (window menu) |

## Updating

Right-click the taskbar > **Quit Fenestra and restore the Dock**. Drag the new Fenestra from its disk image onto
Applications and choose **Replace**, then open it. Your settings and permissions stay.

## Uninstalling

Right-click the taskbar > **Taskbar settings** > **Fenestra** tab > **Uninstall…**. Your Dock, menu bar and every
macOS setting Fenestra changed go back to how they were, and the app, its login item, its settings, its logs and the
Wi-Fi passwords it saved are removed. Afterward you can remove its permissions in System Settings > Privacy &
Security, and, if you set up the Focus tile, the shortcuts "Fenestra Focus On" and "Fenestra Focus Off" in Shortcuts.

Dragged Fenestra to the Trash instead? That works too: at the next login it puts your Mac settings back and removes
its login item by itself. If you switch Fenestra off in System Settings > General > Login Items instead, your Mac
settings come back when you quit Fenestra or log out.

## If something goes wrong

- **Fenestra crashed:** it restores your Dock and menu bar at once and restarts. After 3 crashes within 2 minutes
  it turns itself off and shows a notification; open Fenestra from Applications to try again.
- **Get the normal Mac back right away:** open Terminal (Spotlight: Command+Space, type Terminal) and run
  `~/Library/Application\ Support/Fenestra/restore.sh`
- **Remove everything from Terminal:**
  `~/Library/Application\ Support/Fenestra/restore.sh --uninstall`
- **Can't reach anything:** restart the Mac and hold **Shift** at the login window. Login items (Fenestra included)
  don't start, so the normal Mac is back; then run the restore command above.
