#!/bin/bash
# Builds Fenestra, installs it to ~/Applications, and registers the login agent + watchdog.
# Re-run after every code change. Undo everything with ./restore.sh --uninstall
set -euo pipefail
cd "$(dirname "$0")"

SUPPORT="$HOME/Library/Application Support/Fenestra"
LABEL="local.fenestra.shell"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$HOME/Applications/Fenestra.app"

echo "Building (Release)..."
xcodebuild -project Fenestra.xcodeproj -target Fenestra -configuration Release SYMROOT="$PWD/build" build \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
[ -d build/Release/Fenestra.app ] || { echo "Build failed."; exit 1; }

echo "Stopping any running copy..."
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
pkill -x Fenestra 2>/dev/null || true
sleep 1

echo "Installing to $APP"
mkdir -p "$HOME/Applications" "$SUPPORT" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
rm -rf "$APP"
ditto build/Release/Fenestra.app "$APP"
for s in restore.sh apply-defaults.sh fenestra-run.sh; do
  install -m 755 "Fenestra/Resources/$s" "$SUPPORT/$s"
done

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>AssociatedBundleIdentifiers</key><array><string>local.fenestra.Fenestra</string></array>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SUPPORT/fenestra-run.sh</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/Fenestra.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/Fenestra.log</string>
</dict>
</plist>
EOF

echo "Starting Fenestra (and at every login)..."
launchctl enable "gui/$UID/$LABEL"
launchctl bootstrap "gui/$UID" "$PLIST"
echo "Done. To undo: ./restore.sh  (or ./restore.sh --uninstall to remove everything)"
