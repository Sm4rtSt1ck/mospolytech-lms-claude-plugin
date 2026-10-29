# Shared helpers for the PreToolUse guards. Sourced, not executed.
# Hook input is JSON on stdin; Git Bash on Windows has no jq or python, so fields are pulled
# out with sed. Only flat string/number fields of tool_input are needed.

HOOK_INPUT="$(cat)"

# json_field <name>: value of the first "name": "<string>" or "name": <number> in the input.
json_field() {
  printf '%s' "$HOOK_INPUT" | tr -d '\n' \
    | sed -nE "s/.*\"$1\"[[:space:]]*:[[:space:]]*(\"(([^\"\\\\]|\\\\.)*)\"|([-0-9.a-z]+)).*/\2\4/p" \
    | head -1 \
    | sed 's/\\\//\//g; s/\\"/"/g; s/\\\\/\\/g'
}

json_str() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\r'/}; s=${s//$'\n'/\\n}
  printf '"%s"' "$s"
}

# decide <allow|deny|ask> <reason>
decide() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":%s}}\n' \
    "$1" "$(json_str "$2")"
  exit 0
}

is_windows() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac; return 1; }
to_unix() { if is_windows && command -v cygpath >/dev/null; then cygpath -u "$1"; else printf '%s' "$1"; fi; }

# Absolute physical path of an existing directory, or empty.
real_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# Documents root: paths.documents_dir from <workspace>/profile.yaml, relative to the workspace,
# default <workspace>/documents. Empty when the workspace is not configured.
documents_root() {
  local ws dir
  ws="$(to_unix "${CLAUDE_PLUGIN_OPTION_WORKSPACE_DIR:-}")"
  ws="${ws/#\~/$HOME}"
  [[ -n "$ws" ]] || return 0
  dir="$(sed -n 's/^[[:space:]]*documents_dir:[[:space:]]*["'\'']\{0,1\}\([^"'\''#]*\)["'\'']\{0,1\}.*/\1/p' "$ws/profile.yaml" 2>/dev/null | head -1)"
  dir="${dir%"${dir##*[![:space:]]}"}"
  dir="$(to_unix "${dir:-documents}")"
  dir="${dir/#\~/$HOME}"
  case "$dir" in /*) ;; *) dir="$ws/$dir" ;; esac
  real_dir "$dir"
}
