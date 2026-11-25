#!/usr/bin/env bash
# pin-unitask.sh <version> <SHA256SUMS>: records a unitask release in the plugin, so install.sh
# downloads exactly these archives and refuses any other bytes:
#   - UNITASK_VERSION=<version> in install.sh;
#   - the unitask lines of expected_sha256 (between "unitask:begin" and "unitask:end") replaced
#     with the archives listed in <SHA256SUMS> ("<sha256>  <file>" per line, as sha256sum prints);
#   - the plugin's patch version bumped, so `claude plugin update` delivers the new install.sh.
# Run by .github/workflows/unitask-release.yml; works locally too (GNU or BSD tools).
set -euo pipefail

VERSION="${1:?usage: pin-unitask.sh <version> <SHA256SUMS>}"
SUMS="${2:?usage: pin-unitask.sh <version> <SHA256SUMS>}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="$REPO/plugins/mospolytech-lms/scripts/install.sh"
MANIFEST="$REPO/plugins/mospolytech-lms/.claude-plugin/plugin.json"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad version: $VERSION" >&2; exit 1; }
grep -q '# unitask:begin' "$INSTALL" && grep -q '# unitask:end' "$INSTALL" \
  || { echo "unitask markers not found in $INSTALL" >&2; exit 1; }

# One case line per archive of this version: "    <file>)  echo <sha256> ;;"
lines="$(awk -v v="unitask-$VERSION-" '
  NF == 2 && $1 ~ /^[0-9a-f]{64}$/ && index($2, v) == 1 { printf "    %-50s echo %s ;;\n", $2 ")", $1 }
' "$SUMS")"
count="$(printf '%s\n' "$lines" | grep -c . || true)"
[[ "$count" == 5 ]] || { echo "expected 5 unitask-$VERSION archives in $SUMS, found $count" >&2; exit 1; }

tmp="$(mktemp)"
PIN_LINES="$lines" awk '
  /# unitask:begin/ { print; print ENVIRON["PIN_LINES"]; skip = 1; next }
  /# unitask:end/   { skip = 0 }
  !skip
' "$INSTALL" > "$tmp"
sed -E "s/^UNITASK_VERSION=[0-9.]+/UNITASK_VERSION=$VERSION/" "$tmp" > "$INSTALL"
rm -f "$tmp"

current="$(sed -nE 's/^  "version": "([0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' "$MANIFEST")"
[[ -n "$current" ]] || { echo "version not found in $MANIFEST" >&2; exit 1; }
next="${current%.*}.$(( ${current##*.} + 1 ))"
tmp="$(mktemp)"
sed -E "s/^  \"version\": \"$current\"/  \"version\": \"$next\"/" "$MANIFEST" > "$tmp" && cat "$tmp" > "$MANIFEST"
rm -f "$tmp"

bash -n "$INSTALL"
echo "unitask $VERSION pinned ($count archives), plugin $current -> $next"
