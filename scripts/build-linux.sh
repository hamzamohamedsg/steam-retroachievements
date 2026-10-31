#!/bin/bash
# Cross-builds the Linux program on a Mac with Swift's Static Linux SDK and packs it with inject.js into build/.
# Needs the swift.org toolchain matching the SDK (swiftly), not Command Line Tools: swift sdk install <static-linux bundle>.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="${SDK:-x86_64-swift-linux-musl}"
~/.swiftly/bin/swift build -c release --swift-sdk "$SDK" --scratch-path .build-linux --product SteamRetroAchievements -Xlinker -s
OUT="build/steam-retroachievements-linux"
rm -rf "$OUT" && mkdir -p "$OUT"
cp .build-linux/release/SteamRetroAchievements "$OUT/steam-retroachievements"
cp steam/inject.js "$OUT/"
tar -czf "$OUT.tar.gz" -C build "$(basename "$OUT")"
echo "Built $OUT.tar.gz"
