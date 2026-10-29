#!/usr/bin/env bash
# Downloads moodle-mcp and Typst for this platform into $CLAUDE_PLUGIN_DATA/bin and builds the
# CA bundle for the LMS certificate. Idempotent: prints "installed: <tool> <version>" only for
# what it actually downloaded. Runs on Linux, macOS, WSL and Git Bash on Windows.
set -euo pipefail

MOODLE_MCP_VERSION=0.2.1   # bump together with expected_sha256 below
TYPST_VERSION=0.15.1

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DATA="${CLAUDE_PLUGIN_DATA:?CLAUDE_PLUGIN_DATA is not set}"
BIN="$DATA/bin"
mkdir -p "$BIN"

EXE=""
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)   TARGET=x86_64-unknown-linux-gnu;  TYPST_TARGET=x86_64-unknown-linux-musl ;;
  Linux-aarch64)  TARGET=aarch64-unknown-linux-gnu; TYPST_TARGET=aarch64-unknown-linux-musl ;;
  Darwin-arm64)   TARGET=aarch64-apple-darwin;      TYPST_TARGET=aarch64-apple-darwin ;;
  Darwin-x86_64)  TARGET=x86_64-apple-darwin;       TYPST_TARGET=x86_64-apple-darwin ;;
  MINGW*|MSYS*|CYGWIN*)
    TARGET=x86_64-pc-windows-msvc; TYPST_TARGET=x86_64-pc-windows-msvc; EXE=".exe" ;;
  *) echo "unsupported platform: $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() { curl -fsSL --retry 2 --connect-timeout 15 -o "$2" "$1"; }

# SHA-256 of every release archive this script can download. Taken from the GitHub release
# asset digests; update together with the versions above. A mismatch aborts the install, so a
# replaced release asset never runs with access to the student's LMS account.
expected_sha256() {
  case "$1" in
    moodle-mcp-0.2.1-x86_64-unknown-linux-gnu.tar.gz)  echo f9cf1d338778565392f8f90d1379b6fafd7c99e84411f6081b0859f49d70892d ;;
    moodle-mcp-0.2.1-aarch64-unknown-linux-gnu.tar.gz) echo 0ba22feed0ad42ad69bda1d54a88b12f8d4fe793a6012f9a4968555565e76dd5 ;;
    moodle-mcp-0.2.1-aarch64-apple-darwin.tar.gz)      echo 4932e51e56b95d4030dcf22cbde9aa552b4503e0faa5e0ffcb3233e382724cd4 ;;
    moodle-mcp-0.2.1-x86_64-apple-darwin.tar.gz)       echo 54a9c8419cbd721ff64a94aad7258a64e37f107f95b5c9f2e353f93e01a7fbdd ;;
    moodle-mcp-0.2.1-x86_64-pc-windows-msvc.zip)       echo 7ba5f3c502f1ae8a62a9b927523bf2407569c4a6800f3fadf34cddfd8f7951c7 ;;
    typst-x86_64-unknown-linux-musl.tar.xz)            echo a6d077d0a95eed5a2eba715b2dae06be954f624ccbf85758a03f389ded33118c ;;
    typst-aarch64-unknown-linux-musl.tar.xz)           echo 5aa8d74a3d906e60ea12a66ac2f37f8eef1b14cbad7182a745e393a10c23dcee ;;
    typst-aarch64-apple-darwin.tar.xz)                 echo 48f62ed034aa3a7978309579ac6ca00045e2ef0da73114e8af27cfd8e74dc05a ;;
    typst-x86_64-apple-darwin.tar.xz)                  echo 7f9fdd9584866245de9a79e0add8f9236fae6f40a8a45e2c4771ccc14db4e0fa ;;
    typst-x86_64-pc-windows-msvc.zip)                  echo 19ce3551153c2fe7ee9fa2f95208310c8f4d3209fedb699e0333faf8913f6736 ;;
  esac
}

sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null; then shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# verify <archive>: refuses archives without a known checksum or with a different one.
verify() {
  local name="${1##*/}" want got
  want="$(expected_sha256 "$name")"
  [[ -n "$want" ]] || { echo "no checksum recorded for $name" >&2; exit 1; }
  got="$(sha256_of "$1")"
  [[ -n "$got" ]] || { echo "neither sha256sum nor shasum is available to verify $name" >&2; exit 1; }
  [[ "$got" == "$want" ]] || { echo "checksum mismatch for $name: expected $want, got $got" >&2; exit 1; }
}

# Unpacks an archive into $2; Windows releases are zip, and Git Bash ships no unzip.
unpack() {
  case "$1" in
    *.zip) powershell.exe -NoProfile -Command \
             "Expand-Archive -Force -LiteralPath '$(cygpath -w "$1")' -DestinationPath '$(cygpath -w "$2")'" ;;
    *.tar.gz) tar xzf "$1" -C "$2" ;;
    *.tar.xz) tar xJf "$1" -C "$2" ;;
  esac
}

# install <name> <version> <url>: downloads, unpacks and copies <name>$EXE into $BIN.
install_tool() {
  local name=$1 version=$2 url=$3 marker="$BIN/.$1-version"
  if [[ -x "$BIN/$name$EXE" && "$(cat "$marker" 2>/dev/null)" == "$version" ]]; then
    return
  fi
  local archive="$TMP/${url##*/}" dest="$TMP/$name"
  mkdir -p "$dest"
  fetch "$url" "$archive"
  verify "$archive"
  unpack "$archive" "$dest"
  local found
  found="$(find "$dest" -type f -name "$name$EXE" | head -1)"
  [[ -n "$found" ]] || { echo "$name$EXE not found in ${url##*/}" >&2; exit 1; }
  cp "$found" "$BIN/$name$EXE"
  chmod +x "$BIN/$name$EXE"
  echo "$version" > "$marker"
  echo "installed: $name $version"
}

if [[ -n "$EXE" ]]; then MCP_EXT=zip; TYPST_EXT=zip; else MCP_EXT=tar.gz; TYPST_EXT=tar.xz; fi
install_tool moodle-mcp "$MOODLE_MCP_VERSION" \
  "https://github.com/G36maid/moodle-mcp/releases/download/v$MOODLE_MCP_VERSION/moodle-mcp-$MOODLE_MCP_VERSION-$TARGET.$MCP_EXT"
install_tool typst "$TYPST_VERSION" \
  "https://github.com/typst/typst/releases/download/v$TYPST_VERSION/typst-$TYPST_TARGET.$TYPST_EXT"

# online.mospolytech.ru serves its certificate without the GlobalSign intermediate. Browsers,
# macOS and Windows fetch it via AIA; rustls on Linux does not, so the MCP server gets
# SSL_CERT_FILE = system CAs + the intermediate. Elsewhere the file is unused but kept valid.
INTER="$ROOT/certs/globalsign-gcc-r46-dv-tls-ca-2025.pem"
SYSTEM_CA=""
for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem /etc/ssl/ca-bundle.pem; do
  [[ -f "$f" ]] && { SYSTEM_CA="$f"; break; }
done
BUNDLE="$DATA/ca-bundle.pem"
if [[ ! -s "$BUNDLE" || "$INTER" -nt "$BUNDLE" || ( -n "$SYSTEM_CA" && "$SYSTEM_CA" -nt "$BUNDLE" ) ]]; then
  if [[ -n "$SYSTEM_CA" ]]; then cat "$SYSTEM_CA" "$INTER" > "$BUNDLE"; else cp "$INTER" "$BUNDLE"; fi
fi
