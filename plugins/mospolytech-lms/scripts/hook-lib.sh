# Shared helpers for the PreToolUse guards. Sourced, not executed.
# Hook input is JSON on stdin; Git Bash on Windows has no jq or python, so fields are pulled
# out with sed. Only flat string/number fields of tool_input are needed.

HOOK_INPUT="$(cat)"

# json_get <json> <name>: value of the last "name": "<string>" or "name": <number> (the greedy
# sed match ends on the last occurrence). Keys inside escaped JSON strings are not matched.
json_get() {
  printf '%s' "$1" | tr -d '\n' \
    | sed -nE "s/.*\"$2\"[[:space:]]*:[[:space:]]*(\"(([^\"\\\\]|\\\\.)*)\"|([-0-9.a-z]+)).*/\2\4/p" \
    | head -1 \
    | sed 's/\\\//\//g; s/\\"/"/g; s/\\\\/\\/g'
}

# json_field <name>: json_get on the hook input.
json_field() { json_get "$HOOK_INPUT" "$1"; }

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
# profile_path <key> <default>: a path setting ("key: value") from <ws>/profile.yaml, made absolute:
# a relative value is resolved against the workspace. Prints nothing when no workspace is set.
profile_path() {
  local ws v
  ws="$(to_unix "${CLAUDE_PLUGIN_OPTION_WORKSPACE_DIR:-}")"
  ws="${ws/#\~/$HOME}"
  [[ -n "$ws" ]] || return 0
  v="$(sed -n "s/^[[:space:]]*$1:[[:space:]]*[\"']\{0,1\}\([^\"'#]*\)[\"']\{0,1\}.*/\1/p" "$ws/profile.yaml" 2>/dev/null | head -1)"
  v="${v%"${v##*[![:space:]]}"}"
  v="$(to_unix "${v:-$2}")"
  v="${v/#\~/$HOME}"
  case "$v" in /*) ;; *) v="$ws/$v" ;; esac
  printf '%s' "$v"
}

documents_root() {
  local dir
  dir="$(profile_path documents_dir documents)"
  [[ -n "$dir" ]] && real_dir "$dir"
}
