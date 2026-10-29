#!/usr/bin/env bash
# PreToolUse guard for moodle upload_file: only non-empty files from the documents folder
# may go to the LMS — not scratchpads, /tmp, or files outside the student's works.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/hook-lib.sh"

path="$(json_field path)"
[[ -n "$path" ]] || decide deny "upload_file без пути к файлу."
path="$(to_unix "$path")"
case "$path" in /*) ;; *) path="$(json_field cwd)/$path" ;; esac

[[ -f "$path" ]] || decide deny "Файл не найден: $path"
[[ -s "$path" ]] || decide deny "Файл пустой: $path"

root="$(documents_root)"
[[ -n "$root" ]] || decide deny "Не найдена папка работ: задайте рабочую папку плагина (/plugin → mospolytech-lms → Configure) и paths.documents_dir в profile.yaml."

file_dir="$(real_dir "$(dirname "$path")")"
case "$file_dir/" in
  "$root"/*) exit 0 ;;
  *) decide deny "В LMS загружаются только файлы из папки работ ($root). Сохраните итоговый файл в папку работы и загрузите его оттуда: $path" ;;
esac
