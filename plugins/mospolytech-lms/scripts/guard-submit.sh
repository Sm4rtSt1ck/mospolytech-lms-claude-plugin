#!/usr/bin/env bash
# PreToolUse guard for moodle submit_assignment: refuses an empty submission and, unless the
# user turned it off (submit_confirmation = off), asks for confirmation in Claude Code's own
# permission dialog — independent of what the model decided.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/hook-lib.sh"

assignment="$(json_field assignment_id)"
item="$(json_field item_id)"
text="$(json_field text)"
finalize="$(json_field finalize)"

if [[ -z "$item" || "$item" == null ]] && [[ -z "$text" ]]; then
  # finalize=true without files or text submits what is already saved in the LMS
  [[ "$finalize" == true ]] || decide deny "Пустой ответ: нет ни файла (item_id), ни текста."
fi

[[ "${CLAUDE_PLUGIN_OPTION_SUBMIT_CONFIRMATION:-ask}" == off ]] && exit 0

desc=""
[[ -n "$item" && "$item" != null ]] && desc+="; файлы из черновика $item"
[[ -n "$text" ]] && desc+="; текст (${#text} симв.)"
[[ "$finalize" == true ]] && desc+="; с отправкой на проверку"
decide ask "Ответ уйдёт в LMS от вашего имени: задание ${assignment:-?}${desc}."
