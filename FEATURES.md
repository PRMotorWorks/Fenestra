# Fenestra: every feature

Everything Fenestra does, by area. Fenestra follows Windows 11 (25H2): the Windows key is **Control+Option** and
Alt is **Option**. Almost everything here can be switched off: right-click an empty part of the taskbar >
**Taskbar settings**.

Back to the [README](README.md) · [Install guide](INSTALL.md)

**Contents:** [Taskbar](#taskbar) · [Start menu](#start-menu) · [System tray](#system-tray) ·
[Quick Settings](#quick-settings) · [Calendar and notifications](#calendar-and-notifications) ·
[Title bar buttons](#title-bar-buttons) · [Snapping](#snapping) · [Switching windows](#switching-windows) ·
[Menu bar and app menus](#menu-bar-and-app-menus) · [Clipboard history](#clipboard-history) ·
[Multiple displays](#multiple-displays) · [Mac settings Fenestra adjusts](#mac-settings-fenestra-adjusts) ·
[Safety and uninstall](#safety-and-uninstall) · [Keyboard shortcuts](#keyboard-shortcuts) ·
[Differences from Windows 11](#differences-from-windows-11)

---

## Taskbar

- Start, Search and Task view buttons, then your pinned and open apps.
- **Alignment:** centered or left.
- **Search:** hidden, icon only, icon and label, or a search box.
- **Running apps:** a line under each open app, longer for the app in front.
- **Click** an app to switch to it, click again to minimize it. **Middle-click** opens a new window (can be switched
  off).
- **Drag** icons to reorder them. Right-click to pin or unpin.
- **Window previews:** hover an app for live thumbnails of its windows. Close a window right from its preview.
  An app with several windows shows a picker when you click it.
- **Jump list** (right-click an app): recent files, open a new window, pin or unpin, **Close window**
  (or Close all windows) and **End task** (force quits the app; can be switched off).
- **Unread badges** on apps like Mail and Messages.
- **Combine taskbar buttons:** always (one button per app), when the taskbar is full, or never (a labeled button
  per window).
- **Smaller taskbar buttons:** always, never, or when the taskbar is full.
- **Show desktop:** the far right corner hides every window; click again to bring them back. Optionally on every
  display at once.
- **Auto-hide** the taskbar. It also steps aside by itself for full-screen videos, games and full-screen windows.
- **Right-click an empty part of the taskbar:** Task Manager (Activity Monitor), Taskbar settings, Permissions, and
  Quit Fenestra and restore the Dock.

## Start menu

- **Open it** from the Start button or by **tapping Command alone**, like the Windows key. It slides up in about
  200 ms. The key can be changed in Settings > Keyboard: either Command, left or right Command, or Control (for
  keyboards where Karabiner-Elements swaps Control and Command), or off.
- **Pinned apps:** right-click any app to pin, unpin, move to front, pin to the taskbar, or open its file location.
  "Show all" appears when you have more than 16 pins.
- **Recommended:** recently added apps and recently opened files (each can be switched off).
- **All apps:** by category, as a list, or as a grid. Click a category to open it.
- **Search as you type:** apps and settings instantly, documents a moment later. Arrow keys, Return and Esc work.
- **Folder shortcuts** next to the power button (Documents, Downloads, Pictures and others, your choice).
- **Power menu:** Sleep, Restart, Shut down. **Your account:** Lock, Sign out, account settings.
- **Lock button** next to the power button (optional, Settings > Start).
- **Right-click Start** for the Windows key + X menu, with Mac equivalents.

## System tray

- **Wi-Fi, sound and battery icons** open Quick Settings. Each has a **live tooltip**: network name, output device
  and volume, battery level.
- **Scroll over the speaker** to change the volume in 5% steps.
- **Battery:** a charging bolt while charging, a plug when connected but not charging, optional percentage. Hidden
  on Macs without a battery.
- **Keyboard layout** indicator (ENG US). Click it to switch layouts. Automatic mode hides it while the Keyboard
  layout tile is in Quick Settings.
- **Clock:** optional seconds. Click it for the calendar.
- **Notification bell:** shows the notifications you've received.
- **The ^ arrow** holds the Mac's menu bar icons (other apps' status icons). Any of them can sit on the taskbar
  instead: right-click it, or choose in Taskbar settings. Clicking one opens its menu above the tray.

## Quick Settings

- **Wi-Fi:** turn it on or off; the network list opens right under the tile. Click a network to connect. Known
  networks join without asking for the password again. Phone hotspots are labeled.
- **Bluetooth:** turn it on or off, and connect or disconnect paired devices from the list.
- **Sliders:** brightness (built-in screen, and external monitors that support it) and volume, with an output
  picker that includes AirPlay.
- **Tiles:** Airplane mode, Battery saver (Low Power Mode), Night light (Night Shift), Focus (Do Not Disturb),
  Nearby sharing (AirDrop: Off, Contacts only, Everyone for 10 minutes), Cast (Screen Mirroring), Accessibility,
  Keyboard layout and Live captions.
- **Mac extras you can add:** Dark mode, Screen saver, Capture screen, Capture selection, Screenshot and record,
  Voice memo, Quick note, Calculator and Clock.
- **Edit the tiles** like on Windows: the pencil button lets you remove tiles, add tiles and drag to reorder them.
  The same list is in Taskbar settings, with a reset button.
- **Footer:** battery status, the pencil, and a shortcut to settings.

## Calendar and notifications

- Click the clock for **today's date and a month calendar**. Browse months with the arrows.
- **Notifications** you received while Fenestra runs. The list grows up to almost the full screen height, as on Windows 11. A link to open the macOS Notification Center can be switched on in Settings > System tray (off by default).

## Title bar buttons

- Every window's colored traffic lights become Windows-style **minimize, maximize and close** buttons, with the
  Windows hover colors (close turns red). The button background matches each window's title bar.
- **Maximize** fills the screen above the taskbar, never a separate full-screen Space. It turns into **Restore
  Down**, which puts the window back to its previous size.
- **Close** closes the window, and **closing an app's last window quits the app**, like Windows (it can still ask
  to save; Finder never quits). Can be switched back to Mac behavior.
- **Button size:** automatic (Windows size where there's room, compact where the app has its own controls next to
  the traffic lights), always Windows size, or always compact.
- The buttons **follow the window while you drag it**, or can hide during drags instead.
- **Double-click a title bar** to maximize or restore.
- **Window menu:** right-click the buttons, or press **Option+Space** (Alt+Space): Restore, Move, Size, Minimize,
  Maximize, Close, then the app's menus. Move and Size work with the arrow keys, like Windows.

## Snapping

- **Drag a window to an edge** to snap it to that half, or **near a corner** for a quarter, with a preview first.
  Drag it to the **top** to maximize.
- **Snap layouts bar:** drag a window toward the top center and drop it on a zone.
- **Snap Layouts flyout:** rest the pointer on the maximize button. Layouts adapt to the display: halves, two
  thirds and one third, thirds, half and quarters, quadrants; extra layouts on ultrawide monitors; stacked layouts
  on portrait monitors.
- **Control+Option+Z** opens Snap Layouts from the keyboard, with numbers: press a layout's number, then a zone's.
- **Snap Assist:** after a snap, your other windows are offered for the rest of the layout. Click one, or use the
  arrows and Return.
- **Snap groups:** windows snapped together through Snap Assist come back together. Hover their app on the
  taskbar and click the group.
- **Drag a snapped window away** and it gets back its size from before.
- **Quick snap** (a Mac extra): fling a window toward an edge and let go a little early, and it still snaps there.
  Off, Gentle, Normal or Strong.
- **Keyboard snapping:**

  | Keys | Does |
  |---|---|
  | Control+Option+Left / Right | snap to the left or right half; quarters move sideways |
  | Control+Option+Up | maximize, or from a half to the top quarter |
  | Control+Option+Down | restore, or from a half to the bottom quarter, or minimize |
  | Control+Option+Shift+Left / Right | move the window to the other display |
  | Control+Option+Shift+Up | stretch the window to the full height |

## Switching windows

- **Option+Tab** (Alt+Tab): hold Option for a switcher with live thumbnails, most recent first. Tab, Shift+Tab and
  the arrows move, and a tap on Shift goes back one window; let go of Option to switch; Esc cancels; Delete or the
  X closes a window. A quick Option+Tab switches straight back to the previous window. It can list every
  display's windows or only the current display's (Settings > Keyboard).
- **Task view** (Control+Option+Tab, or the taskbar button): every open window as a thumbnail, each on its own
  display, over a blurred backdrop. Click one to switch or X to close it.
- **Control+Option+D** shows the desktop.

## Menu bar and app menus

- The **macOS menu bar is hidden**, and stays hidden even when the pointer touches the top of the screen, so
  windows can use the full height.
- **Menu button** next to the title bar buttons: the app's whole menu (Apple menu, the app menu, File, Edit,
  View...) as a dropdown. Every item runs the app's real command.
- **Tap Option alone** to open the front app's menus, like Alt on Windows. The arrow keys, Return and Esc work.
- Prefer the menu bar? Turn "Hide the macOS menu bar" off and keep everything else.

## Clipboard history

- **Control+Option+V** opens the history at your text cursor: the last 25 things you copied (10, 25, 50 or 100).
- **Text, links, images, and files copied in Finder.**
- Click an item, or press Return, to paste it into the app you were typing in.
- **Pin** favorites (they stay at the top and never drop off), **delete** items, or **Clear all**.
- **Private by design:** passwords copied from password managers are never saved, and the history lives only in
  memory, so it starts empty when Fenestra restarts.
- Fully keyboard-driven: arrows, Tab to an item's options, Return.

## Middle-click in browsers

- **Middle-click a link** in Safari, Chrome, Brave, Edge, Vivaldi, Opera or Firefox to open it in a **new window**
  (browsers on their own open a background tab). Can be switched off in Settings > Windows > Mouse.
- **Middle-click a tab** to close it: these browsers already do that themselves, and Fenestra leaves it to them.

## Multiple displays

- **A taskbar on every display**, each with Start, Search, Task view, its apps, a clock, the bell and its own
  show-desktop corner. Start and the calendar open on the display you click.
- **Which apps each taskbar shows:** the same on all taskbars; everything on the main taskbar and only that
  display's apps on the others; or each taskbar only the apps with a window on its display. Clicks, previews and
  Close all windows then act on that display's windows only.
- **Pin an app to one taskbar:** right-click it and choose **Pin to this taskbar only** (or set it per app in
  Settings > Taskbar > Pinned apps). If that display isn't connected, the pin shows on the main taskbar.
- **Alt+Tab on the current display only:** optionally list only the windows on the display with the window in
  front, or the display with the pointer. The switcher then opens on that display.
- **Unplug a monitor** and its windows minimize instead of piling onto the other screen. **Plug it back in** and
  they return to where they were, at the same size, snapped or maximized as before.

## Mac settings Fenestra adjusts

To feel like Windows, Fenestra changes a few macOS settings. Your original values are saved first and put back when
Fenestra quits or is uninstalled. Each group has its own switch in **Taskbar settings > Fenestra > macOS changes**.

- **Dock:** hidden (it keeps running in the background, because macOS needs it for minimizing and Mission Control).
- **Minimize effect:** Scale instead of Genie, closer to Windows.
- **Finder, like File Explorer:** path bar and status bar shown, folders sorted first, file extensions shown, new
  windows open your home folder.
- **Double-click a title bar** maximizes the window.
- **macOS's own window tiling** is turned off, so it doesn't fight Fenestra's snapping.
- **Clicking the wallpaper** no longer hides all your windows (Windows doesn't do that).
- **Menu bar:** hidden (see above).

## Safety and uninstall

- **Quit any time:** right-click the taskbar > **Quit Fenestra and restore the Dock**. Your Mac is back to normal
  at once.
- **Crash protection:** if Fenestra ever crashes, your Dock and menu bar come back immediately and Fenestra
  restarts. After 3 crashes in 2 minutes it turns itself off and tells you.
- **Uninstall:** Taskbar settings > Fenestra > **Uninstall…** restores every setting and removes the app, its
  login item, its settings, its logs and the Wi-Fi passwords it saved.
- **Dragged it to the Trash?** At the next login your settings are put back and the login item is removed.
- **Emergency restore** from Terminal: `~/Library/Application\ Support/Fenestra/restore.sh`
- **No network access:** Fenestra never connects to the internet. No analytics, no accounts, no update checks.
- **Light:** 0% CPU when idle, about 60 MB of memory, one native app. Runs on Apple silicon and Intel.

## Keyboard shortcuts

| On Windows | On a Mac with Fenestra | Does |
|---|---|---|
| Windows key | tap **Command** | Start |
| Windows + arrows | **Control+Option+arrows** | Snap windows |
| Windows + Shift + arrows | **Control+Option+Shift+arrows** | Move to another display, stretch |
| Windows + Z | **Control+Option+Z** | Snap layouts, then numbers |
| Windows + Tab | **Control+Option+Tab** | Task view |
| Windows + D | **Control+Option+D** | Show desktop |
| Windows + V | **Control+Option+V** | Clipboard history |
| Alt+Tab | **Option+Tab** | Switch windows |
| Alt | tap **Option** | App menus |
| Alt+Space | **Option+Space** | Window menu |

Settings > Keyboard lists every shortcut in one place. Task view, Snap layouts, Show desktop, Clipboard history and
the window menu can each be given another key combination: click the shortcut and press the new keys.

## Settings

Settings has a search field (Command+F): type any word, such as "lock", "pin" or "alt tab", and the matching
settings appear with their switches, ready to change, each with a link to its page.

## Differences from Windows 11

Fenestra runs on top of macOS with System Integrity Protection left on, so a few things work a little differently:

- The title bar buttons sit at the **top left**, where the traffic lights were, and they are an overlay rather than
  part of the window. A window brought forward without a click can show its traffic lights for a moment.
- Minimizing animates toward the bottom of the screen rather than into the taskbar icon.
- The bell only shows notifications received while Fenestra is running.
- Jump lists use the native Mac menu style. Their recent files are recent files of the types the app opens.
- No Widgets, Copilot, virtual desktops, web results in Start, or progress bars on taskbar icons.
- The Focus tile turns Do Not Disturb on and off; changes made elsewhere aren't detected.
- Some monitors don't report their brightness, so the slider shows the last value you set.
- Snap groups and clipboard history are kept in memory, so they reset when Fenestra restarts.

Fenestra is an independent project and isn't affiliated with Microsoft. Windows is a trademark of Microsoft
Corporation.
