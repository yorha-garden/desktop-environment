#!/usr/bin/env bash
# Compile YoRHa Desktop, the native widget layer that replaces Übersicht.
#   bin/build-desktop.sh [output]    default: native/.build/yorha-desktop
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$REPO/native/.build/yorha-desktop}"

mkdir -p "$(dirname "$OUT")"
swiftc -O "$REPO"/native/YoRHaDesktop/*.swift -o "$OUT"
echo "$OUT"
