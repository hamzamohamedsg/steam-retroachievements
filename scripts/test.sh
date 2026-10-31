#!/bin/bash
# Uses Apple's Command Line Tools Swift (the swiftly 6.3 toolchain on PATH doesn't match the macOS 27 SDK)
# and points it at the Swift Testing macro plugin, which CLT ships but doesn't wire up by default.
cd "$(dirname "$0")/.." && exec /usr/bin/swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing "$@"
