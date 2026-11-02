#!/usr/bin/env bash
# PostToolUse hook for moodle upload_file: remembers which file went into which draft item_id,
# so guard-submit.sh can name the file in the confirmation dialog instead of a bare number.
# Never blocks anything: every failure just means a less detailed dialog later.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/hook-lib.sh"

DATA="${CLAUDE_PLUGIN_DATA:-}"
[[ -n "$DATA" ]] || exit 0

# The result is {"uploaded":true,"item_id":N,"filename":"…",…}, possibly as escaped text inside an
# MCP content block, so take the last item_id number in the input (the request's own item_id,
# if any, comes first).
item="$(printf '%s' "$HOOK_INPUT" | tr -d '\n' | grep -oE 'item_id[\\"]*[[:space:]]*:[[:space:]]*[0-9]+' | tail -1 | grep -oE '[0-9]+$')"
[[ -n "$item" ]] || exit 0

name="$(json_field filename)"
[[ -n "$name" && "$name" != null ]] || { name="$(json_field path)"; name="${name##*[/\\]}"; }
[[ -n "$name" ]] || exit 0

log="$DATA/uploads.tsv"
printf '%s\t%s\n' "$item" "$name" >> "$log"
# Keep the log small: only recent uploads matter.
if [[ "$(wc -l < "$log")" -gt 200 ]]; then
  tail -100 "$log" > "$log.tmp" && mv "$log.tmp" "$log"
fi
exit 0
