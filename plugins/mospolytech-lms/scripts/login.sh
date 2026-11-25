#!/usr/bin/env bash
# Gets an LMS web-service token (asks for login and password in the terminal) and saves it to the
# plugin's secure settings. Run it yourself in a terminal: Claude's Bash tool has no TTY to prompt.
# usage: login.sh [lms-url]
set -euo pipefail

URL="${1:-${CLAUDE_PLUGIN_OPTION_MOODLE_URL:-https://online.mospolytech.ru}}"
URL="${URL%/}"

DATA="${CLAUDE_PLUGIN_DATA:-}"
if [[ -z "$DATA" ]]; then
  for d in "$HOME"/.claude/plugins/data/mospolytech-lms*; do
    if [[ -x "$d/bin/moodle-mcp" || -x "$d/bin/moodle-mcp.exe" ]]; then DATA="$d"; break; fi
  done
fi
[[ -n "$DATA" ]] || { echo "moodle-mcp не установлен. Откройте Claude Code с включённым плагином mospolytech-lms — он скачает инструменты при старте — и запустите скрипт снова." >&2; exit 1; }

[[ -s "$DATA/ca-bundle.pem" && "$(uname -s)" == Linux ]] && export SSL_CERT_FILE="$DATA/ca-bundle.pem"

# moodle-mcp asks for the password on the terminal; "! command" in Claude Code has none.
if [[ ! -t 0 && -z "${LMS_LOGIN_NO_TTY_CHECK:-}" ]]; then   # the variable is for tests/run.sh only
  echo "Нужен настоящий терминал: запустите эту команду в отдельном окне терминала, а не через «!» в Claude Code —" >&2
  echo "там нельзя ввести логин и пароль:  bash \"$0\"" >&2
  exit 1
fi

echo "Вход в LMS $URL: введите логин и пароль (пароль нигде не сохраняется)."
# Prompts go to the terminal; stdout carries Moodle's token.php JSON: {"token":"…","privatetoken":…}
out="$("$DATA/bin/moodle-mcp" auth --url "$URL" --output json)"
token="$(printf '%s' "$out" | tr -d '\r\n' | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
[[ -n "$token" ]] || { echo "Не удалось получить токен: в ответе LMS нет поля token." >&2; exit 1; }

values="{\"moodle_token\":\"$token\",\"moodle_url\":\"$URL\"}"
if command -v claude >/dev/null; then
  for id in mospolytech-lms@mospolytech mospolytech-lms; do
    if printf '%s' "$values" | claude plugin configure "$id" --values-stdin >/dev/null 2>&1; then
      echo "Токен сохранён в настройки плагина. Перезапустите сессию Claude Code."
      exit 0
    fi
  done
fi

echo
echo "Не получилось сохранить токен автоматически. Вставьте его вручную:"
echo "/plugin → Installed → mospolytech-lms → Configure → «Токен LMS»"
echo
echo "$token"
