#!/usr/bin/env bash
# Builds the upstream dnstt client (https://www.bamsoftware.com/software/dnstt/)
# for all Android ABIs and installs it as android/app/src/main/jniLibs/<abi>/libdnstt.so.
# It runs as a child process, separate from LibXray's Go runtime.
# Android extracts lib*.so into the app's native library directory (patch_android.py sets
# useLegacyPackaging), and executables there may be run by the app.
#
# Run after `flutter create` (needs android/). Requires git and Go.
#   DNSTT_REF=<tag-or-branch>   pin a version (default: the repository's default branch)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${DNSTT_SRC:-https://www.bamsoftware.com/git/dnstt.git}"
REF="${DNSTT_REF:-}"

[ -d "$ROOT/android/app/src/main" ] || { echo "ERROR: android/ not found; run flutter create first"; exit 1; }
command -v go >/dev/null || { echo "ERROR: Go is not installed"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The upstream bamsoftware.com Git server does not support shallow clones.
git clone "$SRC" "$WORK/dnstt"

if [ -n "$REF" ]; then
  git -C "$WORK/dnstt" checkout "$REF"
fi
echo "dnstt commit: $(git -C "$WORK/dnstt" rev-parse HEAD)"
go version

cd "$WORK/dnstt/dnstt-client"

# abi  GOARCH  GOARM  expected `file` text
build() {
  local abi="$1" goarch="$2" goarm="$3" want="$4"
  local dir="$ROOT/android/app/src/main/jniLibs/$abi"
  local out="$dir/libdnstt.so"
  mkdir -p "$dir"
  # Static, no cgo: nothing from the host system is linked in.
  CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" GOARM="$goarm" \
    go build -trimpath -ldflags="-s -w" -o "$out" .
  [ -s "$out" ] || { echo "ERROR: $abi build produced no file"; exit 1; }
  local info
  info="$(file -b "$out")"
  echo "$abi: $info ($(du -h "$out" | cut -f1))"
  case "$info" in
    *"$want"*) ;;
    *) echo "ERROR: $abi binary has the wrong architecture (wanted '$want')"; exit 1 ;;
  esac
}

build arm64-v8a   arm64 ""  "ARM aarch64"
build armeabi-v7a arm   7   "ARM, EABI5"
build x86          386   ""  "Intel 80386"
build x86_64      amd64 ""  "x86-64"

echo "libdnstt.so installed for arm64-v8a, armeabi-v7a, x86, x86_64"
