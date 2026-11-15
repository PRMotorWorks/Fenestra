#!/bin/bash
# Fenestra restore script.
# Brings back the Dock, the menu bar and every macOS default Fenestra changed.
#
#   restore.sh              Stop Fenestra, keep it from starting at login, restore everything.
#                           Start it again later by opening Fenestra.app.
#   restore.sh --soft       Restore defaults only (used by the watchdog and when you quit Fenestra).
#   restore.sh --uninstall  PANIC: restore everything, then remove the app, login agent and data.
#
# Safe to run any number of times. Never needs SIP changes.

set -u
MODE="${1:-}"
SUPPORT="$HOME/Library/Application Support/Fenestra"
BACKUP="$SUPPORT/defaults-backup.txt"
AGENT_LABEL="local.fenestra.shell"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
UID_NUM="$(id -u)"

say() { [ "$MODE" = "--soft" ] || echo "$@"; }

# 1. Stop the shell (not in --soft mode: the watchdog calls --soft after the shell is already gone).
if [ "$MODE" != "--soft" ]; then
  launchctl disable "gui/$UID_NUM/$AGENT_LABEL" 2>/dev/null
  launchctl bootout "gui/$UID_NUM/$AGENT_LABEL" 2>/dev/null
  pkill -x Fenestra 2>/dev/null
  say "Fenestra stopped and disabled at login."
fi

# 2. Put every changed default back to its value from before Fenestra first touched it.
#    Backup line format: domain|key|type|value   (type "absent" means the key did not exist)
restored_dock=0; restored_finder=0; restored_menubar=0; restored_wm=0
restore_key() {
  local d="$1" k="$2" t="$3" v="$4"
  if [ "$t" = "absent" ]; then
    defaults delete "$d" "$k" 2>/dev/null
  else
    defaults write "$d" "$k" "-$t" "$v"
  fi
  case "$d" in
    com.apple.dock) restored_dock=1 ;;
    com.apple.finder) restored_finder=1 ;;
    com.apple.WindowManager) restored_wm=1 ;;
    NSGlobalDomain)
      [ "$k" = "_HIHideMenuBar" ] && restored_menubar=1
      [ "$k" = "AppleShowAllExtensions" ] && restored_finder=1 ;;
  esac
}

if [ -f "$BACKUP" ]; then
  while IFS='|' read -r d k t v; do
    [ -n "$d" ] && restore_key "$d" "$k" "$t" "$v"
  done < "$BACKUP"
else
  # No backup (deleted?): fall back to the macOS defaults for every key Fenestra may change.
  for k in autohide autohide-delay autohide-time-modifier minimize-to-application mineffect; do
    defaults delete com.apple.dock "$k" 2>/dev/null
  done
  for k in ShowPathbar ShowStatusBar _FXSortFoldersFirst NewWindowTarget; do
    defaults delete com.apple.finder "$k" 2>/dev/null
  done
  defaults delete NSGlobalDomain AppleShowAllExtensions 2>/dev/null
  defaults delete NSGlobalDomain AppleActionOnDoubleClick 2>/dev/null
  defaults delete NSGlobalDomain _HIHideMenuBar 2>/dev/null
  for k in EnableTilingByEdgeDrag EnableTopTilingByEdgeDrag EnableTilingOptionAccelerator \
           EnableStandardClickToShowDesktop; do
    defaults delete com.apple.WindowManager "$k" 2>/dev/null
  done
  restored_dock=1; restored_finder=1; restored_menubar=1; restored_wm=1
fi

# 3. Make the changes take effect now.
[ "$restored_dock" = 1 ] && killall Dock 2>/dev/null
[ "$restored_finder" = 1 ] && killall Finder 2>/dev/null
[ "$restored_wm" = 1 ] && killall WindowManager 2>/dev/null
if [ "$restored_menubar" = 1 ]; then
  # Tells every running app the menu bar setting changed (the notification System Settings posts). JavaScript
  # for Automation only posts a distributed notification here: no Apple events, so no Automation prompt.
  osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("AppleInterfaceMenuBarHidingChangedNotification", $(), $(), true)' >/dev/null 2>&1
fi
say "Dock, menu bar and defaults restored."

# 4. Panic uninstall.
if [ "$MODE" = "--uninstall" ]; then
  rm -f "$AGENT_PLIST"
  rm -rf "$HOME/Applications/Fenestra.app" "/Applications/Fenestra.app" 2>/dev/null
  defaults delete local.fenestra.Fenestra 2>/dev/null
  if [ -f /etc/sudoers.d/fenestra ]; then
    echo "Removing the Battery saver permission (asks for your Mac password):"
    sudo rm -f /etc/sudoers.d/fenestra
  fi
  # Wi-Fi password copies Fenestra kept in the login keychain (Settings > Uninstall already removed them; from
  # Terminal macOS may ask once to allow it).
  for _ in $(seq 1 200); do
    security delete-generic-password -s "Fenestra Wi-Fi" >/dev/null 2>&1 || break
  done
  # Keep a copy of the original settings outside the deleted folder, just in case; remove Fenestra's logs.
  if [ -d "$SUPPORT" ]; then
    mkdir -p "$HOME/Library/Logs"
    cp "$BACKUP" "$HOME/Library/Logs/Fenestra-defaults-backup.txt" 2>/dev/null
    rm -rf "$SUPPORT"
  fi
  rm -rf "$HOME/Library/Logs/Fenestra.log" "$HOME/Library/Logs/Fenestra-app.log" "$HOME/Library/Logs/Fenestra-dragtest"
  echo "Fenestra uninstalled. Permissions it was given can be removed in"
  echo "System Settings > Privacy & Security (Accessibility, Screen & System Audio Recording, Location)."
  echo "If you set up the Focus tile, delete the shortcuts \"Fenestra Focus On\" and \"Fenestra Focus Off\" in Shortcuts."
fi
exit 0
