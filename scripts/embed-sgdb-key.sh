#!/bin/bash
# Writes the SteamGridDB key from STEAMGRIDDB_API_KEY into Sources/RACore/SteamGridDBKey.swift for a build, masked so it isn't plain text in the program.
# Takes it from the environment so it stays out of command lines and logs. Never commit the file this changes.
set -euo pipefail
cd "$(dirname "$0")/.."
key="${STEAMGRIDDB_API_KEY:?STEAMGRIDDB_API_KEY is not set}"
masked=""
for ((i = 0; i < ${#key}; i++)); do
  printf -v byte '%d' "'${key:i:1}"
  masked+="$((byte ^ 0x5A)),"
done
printf 'enum SteamGridDBKey {\n    static let masked: [UInt8] = [%s]\n}\n' "$masked" > Sources/RACore/SteamGridDBKey.swift
