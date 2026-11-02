#!/usr/bin/env bash
# PreToolUse guard for moodle submit_assignment: refuses an empty submission and, unless the
# user turned it off (submit_confirmation = «не спрашивать»; older installs saved "off"), asks
# for confirmation in Claude Code's own permission dialog — independent of what the model decided.
# The dialog names the work, the course and the files instead of bare LMS ids.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/hook-lib.sh"

assignment="$(json_field assignment_id)"
item="$(json_field item_id)"
text="$(json_field text)"
finalize="$(json_field finalize)"
[[ "$item" == null ]] && item=""

if [[ -z "$item" && -z "$text" ]]; then
  # finalize=true without files or text submits what is already saved in the LMS
  [[ "$finalize" == true ]] || decide deny "Пустой ответ: нет ни файла, ни текста."
fi

case "${CLAUDE_PLUGIN_OPTION_SUBMIT_CONFIRMATION:-}" in "не спрашивать"|off) exit 0 ;; esac

# The work: the assignment.json snapshot the skill saved in the work folder.
work="" course="" drafts=""
root="$(documents_root)"
if [[ -n "$root" && -n "$assignment" ]]; then
  for f in "$root"/*/*/assignment.json; do
    [[ -f "$f" ]] || continue
    snapshot="$(cat "$f")"
    [[ "$(json_get "$snapshot" assignment_id)" == "$assignment" ]] || continue
    work="$(json_get "$snapshot" name)"
    course="$(json_get "$snapshot" course)"
    course="${course%"${course##*[![:space:]]}"}"
    drafts="$(json_get "$snapshot" draft_required)"
    break
  done
fi

# The files: names recorded by record-upload.sh for this draft item_id.
files=""
if [[ -n "$item" && -f "${CLAUDE_PLUGIN_DATA:-}/uploads.tsv" ]]; then
  files="$(awk -F'\t' -v id="$item" '$1 == id { print $2 }' "$CLAUDE_PLUGIN_DATA/uploads.tsv" | awk '!seen[$0]++' | paste -sd ',' - | sed 's/,/, /g')"
fi

msg="Отправка в LMS от вашего имени"
if [[ -n "$work" ]]; then
  msg+=$'\n'"Работа: «$work»${course:+ — $course}"
else
  msg+=$'\n'"Работа: задание ${assignment:-?} в LMS"
fi
if [[ -n "$item" ]]; then
  msg+=$'\n'"Файл: ${files:-загруженный файл (черновик $item)}"
fi
if [[ -n "$text" ]]; then
  words="$(printf '%s' "$text" | sed 's/<[^>]*>/ /g' | wc -w | tr -d ' ')"
  msg+=$'\n'"Ответ текстом, слов: ${words}"
fi
if [[ "$finalize" == true || "$drafts" == false ]]; then
  msg+=$'\n'"После «Yes» работа сразу уйдёт преподавателю."
elif [[ "$drafts" == true ]]; then
  msg+=$'\n'"После «Yes» ответ сохранится черновиком, на проверку он не уйдёт."
else
  msg+=$'\n'"После «Yes» ответ сохранится в LMS."
fi
decide ask "$msg"
