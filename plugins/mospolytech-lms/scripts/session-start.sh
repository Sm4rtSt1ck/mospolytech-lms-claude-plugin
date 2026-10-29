#!/usr/bin/env bash
# SessionStart hook: installs the binaries, prepares the workspace, checks the LMS token and
# tells Claude (additionalContext) and the user (systemMessage, only on problems) where things are.
# Never fails the session: every problem becomes a message.
set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DATA="${CLAUDE_PLUGIN_DATA:-}"
WS_RAW="${CLAUDE_PLUGIN_OPTION_WORKSPACE_DIR:-}"
URL="${CLAUDE_PLUGIN_OPTION_MOODLE_URL:-https://online.mospolytech.ru}"
URL="${URL%/}"
TOKEN="${CLAUDE_PLUGIN_OPTION_MOODLE_TOKEN:-}"

cat >/dev/null   # hook input is not needed

warnings=()
context=()

json_str() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\r'/}; s=${s//$'\n'/\\n}
  printf '"%s"' "$s"
}

is_windows() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac; return 1; }
to_unix() { if is_windows && command -v cygpath >/dev/null; then cygpath -u "$1"; else printf '%s' "$1"; fi; }

if is_windows; then
  LOGIN_CMD="powershell -ExecutionPolicy Bypass -File \"$(cygpath -w "$ROOT/scripts/login.ps1" 2>/dev/null || echo "$ROOT/scripts/login.ps1")\""
else
  LOGIN_CMD="bash \"$ROOT/scripts/login.sh\""
fi

# ---------- Binaries ----------
first_install=false
if [[ -z "$DATA" ]]; then
  warnings+=("mospolytech-lms: не задан CLAUDE_PLUGIN_DATA — плагин загружен необычным способом, инструменты не установлены.")
else
  if out="$("$ROOT/scripts/install.sh" 2>&1)"; then
    [[ "$out" == *"installed: moodle-mcp"* ]] && first_install=true
  else
    warnings+=("mospolytech-lms: не удалось скачать moodle-mcp/Typst: ${out##*$'\n'}. Проверьте интернет и перезапустите сессию.")
  fi
fi

# ---------- Workspace ----------
WS=""
if [[ -z "$WS_RAW" ]]; then
  warnings+=("mospolytech-lms: не задана рабочая папка. Откройте /plugin → Installed → mospolytech-lms → Configure.")
else
  WS="$(to_unix "${WS_RAW/#\~/$HOME}")"
  mkdir -p "$WS/documents" "$WS/cache/courses" "$WS/fonts" 2>/dev/null \
    || warnings+=("mospolytech-lms: не удалось создать рабочую папку $WS_RAW.")
  [[ -f "$WS/profile.yaml" ]] || cp "$ROOT/profile.example.yaml" "$WS/profile.yaml" 2>/dev/null
  [[ -f "$WS/cache/index.md" ]] || printf '# Курсы LMS\n\n| course_id | Полное название | shortname | Алиасы | Обновлён |\n|---|---|---|---|---|\n' > "$WS/cache/index.md"
fi

# Settings for bin/typst-gost, which runs from the Bash tool and gets no plugin variables.
if [[ -n "$DATA" ]]; then
  fonts=""
  [[ -n "$WS" ]] && fonts="$WS/fonts"
  if grep -qi microsoft /proc/version 2>/dev/null && [[ -d /mnt/c/Windows/Fonts ]]; then
    fonts="${fonts:+$fonts:}/mnt/c/Windows/Fonts"
  fi
  printf 'LMS_WORKSPACE=%s\nLMS_FONT_PATHS=%s\n' "$WS" "$fonts" > "$DATA/env"
fi

# ---------- LMS token ----------
lms_status="не проверено"
if [[ -z "$TOKEN" ]]; then
  lms_status="токен не задан"
  warnings+=("mospolytech-lms: нет токена LMS. Выполните в терминале: $LOGIN_CMD — скрипт спросит логин и пароль от LMS и сохранит токен в настройки плагина. Затем перезапустите сессию.")
elif command -v curl >/dev/null; then
  cacert=()
  [[ -n "$DATA" && -s "$DATA/ca-bundle.pem" ]] && ! is_windows && cacert=(--cacert "$DATA/ca-bundle.pem")
  # ${a[@]+...} keeps an empty array safe under `set -u` on macOS bash 3.2
  resp="$(curl -sS --max-time 8 ${cacert[@]+"${cacert[@]}"} "$URL/webservice/rest/server.php" \
            --data-urlencode "wstoken=$TOKEN" -d wsfunction=core_webservice_get_site_info \
            -d moodlewsrestformat=json 2>&1)"
  if [[ "$resp" == *'"userid"'* ]]; then
    lms_status="подключено, токен действителен"
  elif [[ "$resp" == *invalidtoken* || "$resp" == *accessexception* ]]; then
    lms_status="токен недействителен"
    warnings+=("mospolytech-lms: токен LMS недействителен или отозван. Получите новый: $LOGIN_CMD")
  else
    lms_status="LMS недоступна"
  fi
fi

# The MCP server starts in parallel with this hook, so on the very first run it finds no binary.
if $first_install; then
  warnings+=("mospolytech-lms: инструменты только что установлены, и сервер LMS мог не успеть запуститься. Выполните /mcp → plugin:mospolytech-lms:moodle → Reconnect или перезапустите сессию.")
fi

# ---------- Output ----------
if [[ -n "$WS" ]]; then
  context+=("mospolytech-lms: рабочая папка ${WS_RAW}; профиль ${WS_RAW}/profile.yaml; кеш ${WS_RAW}/cache; работы — paths.documents_dir из профиля (по умолчанию ${WS_RAW}/documents).")
fi
context+=("mospolytech-lms: LMS ${URL} — ${lms_status}. Отчёты Typst собираются командой typst-gost. Получение токена: ${LOGIN_CMD}.")
# Read shows PDF pages only with poppler; without it scans cannot be read at all.
if ! command -v pdftoppm >/dev/null; then
  context+=("mospolytech-lms: poppler (pdftoppm) не установлен — Read не покажет страницы PDF и сканы заданий. Готовый отчёт смотри через typst-gost → PNG; если задание — скан, попроси пользователя установить poppler (см. README плагина).")
fi

ctx="$(printf '%s\n' "${context[@]}")"
msg=""
((${#warnings[@]})) && msg="$(printf '%s\n' "${warnings[@]}")"

printf '{'
[[ -n "$msg" ]] && printf '"systemMessage":%s,' "$(json_str "${msg%$'\n'}")"
printf '"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$(json_str "${ctx%$'\n'}")"
exit 0
