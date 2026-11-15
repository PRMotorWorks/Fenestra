#!/bin/bash
# Fenestra watchdog. launchd runs this at login (agent local.fenestra.shell).
# It starts Fenestra and waits for it to exit, using no CPU while waiting.
#   - Fenestra quit normally      -> restore Dock and menu bar, stay stopped.
#   - Mac logging out / shutting down -> leave settings as they are.
#   - Fenestra crashed            -> restore Dock and menu bar at once, then launchd restarts it.
#   - 3 crashes within 2 minutes  -> restore, turn Fenestra off at login, show a notification.

set -u
SUPPORT="$HOME/Library/Application Support/Fenestra"
STATE="$SUPPORT/state"
CRASHES="$SUPPORT/crashes.log"
APP="$HOME/Applications/Fenestra.app"
[ -d "$APP" ] || APP="/Applications/Fenestra.app"
mkdir -p "$SUPPORT"

echo "starting $(date +%s)" > "$STATE"
# `open` launches through LaunchServices, so macOS attributes permissions to Fenestra itself
# (not to this script). -W waits until the app exits.
/usr/bin/open -W -a "$APP" --args --from-agent

read -r status _ < "$STATE" 2>/dev/null || status="unknown"
case "$status" in
  stopped)
    "$SUPPORT/restore.sh" --soft
    exit 0 ;;
  session-end)
    exit 0 ;;
  handoff)
    exit 0 ;;
esac

# Anything else (still "running" or "starting") means the app died without a clean exit.
now="$(date +%s)"
echo "$now" >> "$CRASHES"
"$SUPPORT/restore.sh" --soft
echo "crashed $now" > "$STATE"
recent="$(awk -v n="$now" '$1 > n - 120' "$CRASHES" | wc -l | tr -d ' ')"
if [ "$recent" -ge 3 ]; then
  launchctl disable "gui/$(id -u)/local.fenestra.shell"
  osascript -e 'display notification "Fenestra crashed 3 times in 2 minutes, so it was turned off. Your Dock and menu bar are back. Open Fenestra.app to try again." with title "Fenestra"' >/dev/null 2>&1
  exit 0
fi
exit 1   # non-zero: launchd restarts Fenestra after its throttle interval
