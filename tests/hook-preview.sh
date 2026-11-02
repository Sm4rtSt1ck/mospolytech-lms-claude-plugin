#!/usr/bin/env bash
# Shows the real submit-confirmation dialog in Claude Code without touching the LMS.
# Builds a throwaway project whose .claude/settings.local.json runs guard-submit.sh on a harmless
# `echo lms-hook-preview` Bash call, with a sample work and uploaded file. Answering «Yes» in the
# dialog only runs that echo.
# usage: bash tests/hook-preview.sh [project-dir]   then: cd <project-dir> && claude
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$REPO/plugins/mospolytech-lms/scripts/guard-submit.sh"
DIR="${1:-$(mktemp -d)}"
mkdir -p "$DIR/.claude" "$DIR/ws/documents/6132-buhuchet/pr-1" "$DIR/data"

# A sample work the way lms-lab saves it, and the upload record-upload.sh would have made.
printf '{"assignment_id":99279,"attachments":[],"course":"Бухгалтерский учет ","draft_required":false,"name":"Задание практика 1","submission":{"files":[],"status":"new"}}\n' \
  > "$DIR/ws/documents/6132-buhuchet/pr-1/assignment.json"
printf '1793495664000000\tИванов_123-456_БухУчет_Практика1.pdf\n' > "$DIR/data/uploads.tsv"

# What submit_assignment would receive; the guard reads it from stdin like a real hook input.
printf '{"tool_name":"mcp__plugin_mospolytech-lms_moodle__submit_assignment","tool_input":{"assignment_id":99279,"item_id":1793495664000000}}' \
  > "$DIR/data/input.json"

q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
cmd="CLAUDE_PLUGIN_OPTION_WORKSPACE_DIR=$(q "$DIR/ws") CLAUDE_PLUGIN_DATA=$(q "$DIR/data") bash $(q "$GUARD") < $(q "$DIR/data/input.json")"
cmd_json="${cmd//\\/\\\\}"; cmd_json="${cmd_json//\"/\\\"}"
cat > "$DIR/.claude/settings.local.json" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "if": "Bash(echo lms-hook-preview*)", "command": "$cmd_json" }
        ]
      }
    ]
  }
}
EOF

cat <<EOF
Готово. Откройте Claude Code в этой папке:

  cd "$DIR" && claude

и попросите: выполни команду echo lms-hook-preview

Появится то же окно подтверждения, что и перед отправкой работы. «Yes» выполнит только echo,
в LMS ничего не уходит. Чтобы поменять текст в окне, правьте guard-submit.sh — при следующем
вызове echo окно покажет новую версию, перезапускать Claude Code не нужно.
EOF
