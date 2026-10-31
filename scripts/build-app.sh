#!/bin/bash
# Builds Steam RetroAchievements.app, signs it ad-hoc and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
/usr/bin/swift build -c release --product SteamRetroAchievements
APP="build/Steam RetroAchievements.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SteamRetroAchievements "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp steam/inject.js "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
osascript -e 'quit app id "local.steam-retroachievements"' 2>/dev/null || true
sleep 1
DEST="$HOME/Applications/Steam RetroAchievements.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "Installed $DEST"
