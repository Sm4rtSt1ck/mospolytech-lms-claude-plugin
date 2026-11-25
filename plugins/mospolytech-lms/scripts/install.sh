#!/usr/bin/env bash
# Downloads moodle-mcp, Typst, pandoc and unitask for this platform into $CLAUDE_PLUGIN_DATA and
# builds the CA bundle for the LMS certificate. Idempotent: prints "installed: <tool> <version>"
# only for what it actually downloaded and "failed: <tool>: <reason>" for what it could not install.
# Each tool is installed on its own, so one failed download does not stop the others. Exit status is
# non-zero only when a required tool (moodle-mcp, Typst) is missing. Every session start runs this,
# so a plugin update that adds a tool or bumps a version installs it at the next session.
# Runs on Linux, macOS, WSL and Git Bash on Windows.
set -uo pipefail

MOODLE_MCP_VERSION=0.2.1   # bump together with expected_sha256 below
TYPST_VERSION=0.15.1
PANDOC_VERSION=3.13
UNITASK_VERSION=0.1.0      # built by .github/workflows/unitask-release.yml from unitask/
UNITASK_REPO=Sm4rtSt1ck/mospolytech-lms-claude-plugin

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DATA="${CLAUDE_PLUGIN_DATA:?CLAUDE_PLUGIN_DATA is not set}"
BIN="$DATA/bin"
mkdir -p "$BIN" "$DATA/unitask"

EXE=""
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)   TARGET=x86_64-unknown-linux-gnu;  TYPST_TARGET=x86_64-unknown-linux-musl;  PANDOC_ASSET=linux-amd64.tar.gz ;;
  Linux-aarch64)  TARGET=aarch64-unknown-linux-gnu; TYPST_TARGET=aarch64-unknown-linux-musl; PANDOC_ASSET=linux-arm64.tar.gz ;;
  Darwin-arm64)   TARGET=aarch64-apple-darwin;      TYPST_TARGET=aarch64-apple-darwin;       PANDOC_ASSET=arm64-macOS.zip ;;
  Darwin-x86_64)  TARGET=x86_64-apple-darwin;       TYPST_TARGET=x86_64-apple-darwin;        PANDOC_ASSET=x86_64-macOS.zip ;;
  MINGW*|MSYS*|CYGWIN*)
    TARGET=x86_64-pc-windows-msvc; TYPST_TARGET=x86_64-pc-windows-msvc; PANDOC_ASSET=windows-x86_64.zip; EXE=".exe" ;;
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
    pandoc-3.13-linux-amd64.tar.gz)                    echo 38aa33b325a2bc96a4c39409631212db55702f564250bcdbead180b3bf646389 ;;
    pandoc-3.13-linux-arm64.tar.gz)                    echo 21e1d4ba09bd0b334590d204580fd4f6629b21be4ab6a32b26cc98982e9e0c68 ;;
    pandoc-3.13-arm64-macOS.zip)                       echo f436d18bebbfb3ddd326597686dacab9fac5dc23bd060495020f35a28a43a7c3 ;;
    pandoc-3.13-x86_64-macOS.zip)                      echo 1823278715aa405aaf21b59cde5dc789346aa8d4fc307467f9a9ee84162bedc5 ;;
    pandoc-3.13-windows-x86_64.zip)                    echo 23e1f2e978a3df80db8bf65c9c59534f41a23140480cfb4f783a882ab7dc6a4e ;;
    # unitask-0.1.0-*: added after the first unitask release (see .github/workflows/unitask-release.yml)
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
    *.zip)
      if [[ -n "$EXE" ]]; then
        powershell.exe -NoProfile -Command \
          "Expand-Archive -Force -LiteralPath '$(cygpath -w "$1")' -DestinationPath '$(cygpath -w "$2")'"
      else
        unzip -q "$1" -d "$2"
      fi ;;
    *.tar.gz) tar xzf "$1" -C "$2" ;;
    *.tar.xz) tar xJf "$1" -C "$2" ;;
  esac
}

# install_tool <name> <version> <url> [<dir>]: downloads, unpacks and puts <name>$EXE into <dir>
# (default $BIN). Runs in a subshell, so "exit 1" in a helper fails only this tool.
install_tool() (
  name=$1 version=$2 url=$3 dir="${4:-$BIN}"
  marker="$dir/.$name-version" dst="$dir/$name$EXE"
  if [[ -x "$dst" && "$(cat "$marker" 2>/dev/null)" == "$version" ]]; then
    exit 0
  fi
  archive="$TMP/${url##*/}" dest="$TMP/$name"
  # No recorded checksum means the archive would be refused anyway; do not download it.
  [[ -n "$(expected_sha256 "${url##*/}")" ]] || { echo "no checksum recorded for ${url##*/}" >&2; exit 1; }
  mkdir -p "$dest"
  fetch "$url" "$archive" || { echo "cannot download ${url##*/}" >&2; exit 1; }
  verify "$archive"
  unpack "$archive" "$dest" || { echo "cannot unpack ${url##*/}" >&2; exit 1; }
  found="$(find "$dest" -type f -name "$name$EXE" | head -1)"
  [[ -n "$found" ]] || { echo "$name$EXE not found in ${url##*/}" >&2; exit 1; }
  # Copy next to the target and rename over it: overwriting a running binary in place fails with
  # "Text file busy" on Linux (the MCP server starts together with this script), and Windows locks
  # a running .exe but still lets it be renamed away.
  cp "$found" "$dst.new" && chmod +x "$dst.new" || { echo "cannot write $dst" >&2; exit 1; }
  if ! mv -f "$dst.new" "$dst" 2>/dev/null; then
    rm -f "$dst.old" 2>/dev/null
    mv -f "$dst" "$dst.old" && mv -f "$dst.new" "$dst" || { echo "cannot replace $dst" >&2; exit 1; }
  fi
  echo "$version" > "$marker"
  echo "installed: $name $version"
)

exec 3>&1
missing_required=false
# try <required|optional> <name> <install_tool args...>: installs and reports a failure as one line.
try() {
  local kind=$1 name=$2 err
  shift 2
  if ! err="$(install_tool "$@" 2>&1 1>&3)"; then
    echo "failed: $name: ${err##*$'\n'}"
    [[ "$kind" == required ]] && missing_required=true
  fi
  return 0
}

if [[ -n "$EXE" ]]; then MCP_EXT=zip; TYPST_EXT=zip; UNITASK_EXT=zip; else MCP_EXT=tar.gz; TYPST_EXT=tar.xz; UNITASK_EXT=tar.gz; fi
try required moodle-mcp moodle-mcp "$MOODLE_MCP_VERSION" \
  "https://github.com/G36maid/moodle-mcp/releases/download/v$MOODLE_MCP_VERSION/moodle-mcp-$MOODLE_MCP_VERSION-$TARGET.$MCP_EXT"
try required typst typst "$TYPST_VERSION" \
  "https://github.com/typst/typst/releases/download/v$TYPST_VERSION/typst-$TYPST_TARGET.$TYPST_EXT"
# pandoc reads .docx from Telegram and the student portal; a system pandoc is used as is.
if ! command -v pandoc >/dev/null || [[ "$(command -v pandoc)" == "$BIN/pandoc$EXE" ]]; then
  try optional pandoc pandoc "$PANDOC_VERSION" \
    "https://github.com/jgm/pandoc/releases/download/$PANDOC_VERSION/pandoc-$PANDOC_VERSION-$PANDOC_ASSET"
fi
# unitask lives in its own directory: that directory goes into the user's PATH, and only unitask
# should appear there.
try optional unitask unitask "$UNITASK_VERSION" \
  "https://github.com/$UNITASK_REPO/releases/download/unitask-v$UNITASK_VERSION/unitask-$UNITASK_VERSION-$TARGET.$UNITASK_EXT" \
  "$DATA/unitask"
if [[ -x "$DATA/unitask/unitask$EXE" && "${LMS_NO_USER_PATH:-}" != 1 ]]; then
  "$ROOT/scripts/user-path.sh" "$DATA/unitask" || true
fi

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

$missing_required && exit 1
exit 0
