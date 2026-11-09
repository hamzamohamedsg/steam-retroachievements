#!/bin/bash
# Builds Steam RetroAchievements.app, signs it ad-hoc and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
# With STEAMGRIDDB_API_KEY set the build gets artwork; the key file is put back afterwards so it can't be committed.
if [ -n "${STEAMGRIDDB_API_KEY:-}" ]; then
  empty_key_file="$(cat Sources/RACore/SteamGridDBKey.swift)"
  trap 'printf "%s\n" "$empty_key_file" > Sources/RACore/SteamGridDBKey.swift' EXIT
  scripts/embed-sgdb-key.sh
fi
/usr/bin/swift build -c release --product SteamRetroAchievements
APP="build/Steam RetroAchievements.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SteamRetroAchievements "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp steam/inject.js Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
osascript -e 'quit app id "local.steam-retroachievements"' 2>/dev/null || true
sleep 1
DEST="$HOME/Applications/Steam RetroAchievements.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "Installed $DEST"
