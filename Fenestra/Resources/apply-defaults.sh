#!/bin/bash
# Fenestra: apply the macOS defaults the shell needs. Idempotent; run by Fenestra at every start.
# Before a key is changed for the first time, its original value is saved to
#   ~/Library/Application Support/Fenestra/defaults-backup.txt
# and restore.sh puts it back. DEVELOPMENT.md lists every key below and why.

set -u
SUPPORT="$HOME/Library/Application Support/Fenestra"
BACKUP="$SUPPORT/defaults-backup.txt"
mkdir -p "$SUPPORT"
touch "$BACKUP"

# group|domain|key|type|value. Each group is one switch in Fenestra's settings (Fenestra tab > macOS changes).
# A group that is switched off gets your original values back (from the backup), the same way the menu bar
# key has always worked. FENESTRA_OFF lists the groups that are off, comma separated.
KEYS=(
  # Phase 1: hide the Dock (it keeps running: it also powers Cmd+Tab, Mission Control and minimizing)
  "dock|com.apple.dock|autohide|bool|true"
  "dock|com.apple.dock|autohide-delay|float|1000"
  "dock|com.apple.dock|autohide-time-modifier|float|0"
  "dock|com.apple.dock|minimize-to-application|bool|true"
  # Phase 1: Explorer-like Finder settings
  "finder|com.apple.finder|ShowPathbar|bool|true"
  "finder|com.apple.finder|ShowStatusBar|bool|true"
  "finder|com.apple.finder|_FXSortFoldersFirst|bool|true"
  "finder|com.apple.finder|NewWindowTarget|string|PfHm"
  "finder|NSGlobalDomain|AppleShowAllExtensions|bool|true"
  # Phase 3: double-clicking a title bar fills the screen (Windows: maximize); the taskbar area is kept clear
  "doubleclick|NSGlobalDomain|AppleActionOnDoubleClick|string|Fill"
  # Phase 4: Fenestra does Windows-style snapping, so macOS tiling must not react to the same drags
  "tiling|com.apple.WindowManager|EnableTilingByEdgeDrag|bool|false"
  "tiling|com.apple.WindowManager|EnableTopTilingByEdgeDrag|bool|false"
  "tiling|com.apple.WindowManager|EnableTilingOptionAccelerator|bool|false"
  # Clicking the wallpaper must not hide every window (Windows has no such behavior; your choice 2026-11-15).
  # false = "Click wallpaper to reveal desktop: Only in Stage Manager"
  "wallpaper|com.apple.WindowManager|EnableStandardClickToShowDesktop|bool|false"
  # Phase 5: minimize with the Scale effect (shrinks and fades), closer to Windows than Genie (your choice)
  "minimize|com.apple.dock|mineffect|string|scale"
  # Phase 6: auto-hide the menu bar ("Automatically hide and show the menu bar: Always"), Fenestra's
  # "Hide the macOS menu bar" setting (FENESTRA_HIDE_MENUBAR=0 also switches it off, as before).
  "menubar|NSGlobalDomain|_HIHideMenuBar|bool|true"
)
OFF=",${FENESTRA_OFF:-},"
[ "${FENESTRA_HIDE_MENUBAR:-1}" != 1 ] && OFF="${OFF}menubar,"

normalize() { # $1 type, $2 value  -> value as `defaults read` prints it
  case "$1" in
    bool) [ "$2" = "true" ] && echo 1 || echo 0 ;;
    *) echo "$2" ;;
  esac
}

changed_dock=0; changed_finder=0; changed_wm=0; changed_menubar=0
mark_changed() { # $1 domain, $2 key
  case "$1" in
    com.apple.dock) changed_dock=1 ;;
    com.apple.finder) changed_finder=1 ;;
    com.apple.WindowManager) changed_wm=1 ;;
    NSGlobalDomain)
      [ "$2" = "AppleShowAllExtensions" ] && changed_finder=1
      [ "$2" = "_HIHideMenuBar" ] && changed_menubar=1 ;;
  esac
}
for entry in "${KEYS[@]}"; do
  IFS='|' read -r g d k t v <<< "$entry"

  # Back up the original value once.
  if ! grep -q "^$d|$k|" "$BACKUP"; then
    if cur="$(defaults read "$d" "$k" 2>/dev/null)"; then
      rt="$(defaults read-type "$d" "$k" 2>/dev/null | awk '{print $3}')"
      case "$rt" in
        boolean) bt=bool; [ "$cur" = "1" ] && cur=true || cur=false ;;
        float) bt=float ;;
        integer) bt=int ;;
        *) bt=string ;;
      esac
      echo "$d|$k|$bt|$cur" >> "$BACKUP"
    else
      echo "$d|$k|absent|" >> "$BACKUP"
    fi
  fi

  # A group switched off in Fenestra's settings: put the backed-up original back.
  if [[ "$OFF" == *",$g,"* ]]; then
    IFS='|' read -r _ _ ot ov <<< "$(grep "^$d|$k|" "$BACKUP" | head -1)"
    cur="$(defaults read "$d" "$k" 2>/dev/null)"
    if [ "$ot" = "absent" ]; then
      if [ -n "$cur" ]; then defaults delete "$d" "$k" 2>/dev/null; mark_changed "$d" "$k"; fi
    elif [ "$cur" != "$(normalize "$ot" "$ov")" ]; then
      defaults write "$d" "$k" "-$ot" "$ov"; mark_changed "$d" "$k"
    fi
    continue
  fi

  # Apply only when different, so we restart the Dock / Finder only when needed.
  cur="$(defaults read "$d" "$k" 2>/dev/null)"
  if [ "$cur" != "$(normalize "$t" "$v")" ]; then
    defaults write "$d" "$k" "-$t" "$v"
    mark_changed "$d" "$k"
  fi
done

[ "$changed_dock" = 1 ] && killall Dock 2>/dev/null
[ "$changed_finder" = 1 ] && killall Finder 2>/dev/null
# WindowManager (Stage Manager, tiling) is relaunched by launchd at once and then reads the new keys.
[ "$changed_wm" = 1 ] && killall WindowManager 2>/dev/null
# Every app re-reads the menu bar setting on this notification (what System Settings posts). JavaScript for
# Automation only posts a distributed notification here: no Apple events, so no Automation prompt.
if [ "$changed_menubar" = 1 ]; then
  osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("AppleInterfaceMenuBarHidingChangedNotification", $(), $(), true)' >/dev/null 2>&1
fi
echo "dock=$changed_dock finder=$changed_finder windowmanager=$changed_wm menubar=$changed_menubar"
exit 0
