#!/usr/bin/env bash
# SessionStart hook: installs the binaries, prepares the workspace and progress.json, points unitask
# at progress.json, checks the LMS token and the optional MCP servers, and tells Claude
# (additionalContext) and the user (systemMessage, only on problems) where things are.
# Never fails the session: every problem becomes a message.
set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DATA="${CLAUDE_PLUGIN_DATA:-}"
WS_RAW="${CLAUDE_PLUGIN_OPTION_WORKSPACE_DIR:-}"
URL="${CLAUDE_PLUGIN_OPTION_MOODLE_URL:-https://online.mospolytech.ru}"
URL="${URL%/}"
TOKEN="${CLAUDE_PLUGIN_OPTION_MOODLE_TOKEN:-}"

# Reads the hook input (not needed here) and provides json_str, is_windows, to_unix, profile_path.
source "$ROOT/scripts/hook-lib.sh"

warnings=()
context=()

# Commands the user runs in their own terminal (they ask for passwords, so never from Claude).
user_cmd() {
  if is_windows; then
    printf 'powershell -ExecutionPolicy Bypass -File "%s"' "$(cygpath -w "$ROOT/scripts/$1.ps1" 2>/dev/null || echo "$ROOT/scripts/$1.ps1")"
  else
    printf 'bash "%s"' "$ROOT/scripts/$1.sh"
  fi
}
LOGIN_CMD="$(user_cmd login)"
SETUP_CMD="$(user_cmd setup)"
native_path() { if is_windows && command -v cygpath >/dev/null; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
EXE=""; is_windows && EXE=".exe"

# ---------- Binaries ----------
first_install=false
path_added=()
if [[ -z "$DATA" ]]; then
  warnings+=("mospolytech-lms: не задан CLAUDE_PLUGIN_DATA — плагин загружен необычным способом, инструменты не установлены.")
else
  out="$("$ROOT/scripts/install.sh" 2>&1)"
  [[ "$out" == *"installed: moodle-mcp"* ]] && first_install=true
  while IFS= read -r line; do
    case "$line" in
      "failed: moodle-mcp:"*|"failed: typst:"*)
        warnings+=("mospolytech-lms: не удалось установить ${line#failed: }. Проверьте интернет и перезапустите сессию.") ;;
      "failed: unitask: no checksum recorded"*)
        context+=("mospolytech-lms: unitask для этой версии плагина ещё не выпущен — программа не установлена.") ;;
      "failed: unitask:"*|"failed: pandoc:"*)
        warnings+=("mospolytech-lms: не удалось установить ${line#failed: }. Остальное работает; повторная попытка — при следующем запуске.") ;;
      "path-added: "*) path_added+=("${line#path-added: }") ;;
      "failed: user-path:"*)
        warnings+=("mospolytech-lms: не удалось добавить unitask в терминал: ${line#failed: user-path: }. Запустите его полным путём: ${DATA}/unitask/unitask") ;;
      "path-skipped: "*) warnings+=("mospolytech-lms: ${line#path-skipped: } — команда unitask не добавлена.") ;;
      "unsupported platform"*) warnings+=("mospolytech-lms: $line — инструменты не установлены.") ;;
    esac
  done <<< "$out"
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

# ---------- progress.json ----------
# The study tracker (skill homework-info, unitask). Default: <ws>/progress.json; paths.progress_file
# in profile.yaml moves it. A missing file gets an empty skeleton of the current semester.
PROGRESS=""
if [[ -n "$WS" ]]; then
  PROGRESS="$(profile_path progress_file progress.json)"
  if [[ ! -f "$PROGRESS" ]] && mkdir -p "$(dirname "$PROGRESS")" 2>/dev/null; then
    y="$(date +%Y)"; m="$(date +%m)"; m="${m#0}"
    if ((m >= 2 && m <= 8)); then sem="$y-spring"; elif ((m == 1)); then sem="$((y - 1))-autumn"; else sem="$y-autumn"; fi
    printf '{\n  "updated": "%s",\n  "semester": "%s",\n  "subjects": {}\n}\n' "$(date +%Y-%m-%d)" "$sem" > "$PROGRESS" \
      && context+=("mospolytech-lms: создан пустой progress.json (${sem}).")
  fi
fi

# unitask opens the file from its own settings. Point it at progress.json when it has no file yet
# or its file is gone; a path the user chose in unitask itself is left alone.
UNITASK="$DATA/unitask/unitask$EXE"
if [[ -n "$DATA" && -n "$PROGRESS" && -f "$PROGRESS" && -x "$UNITASK" ]]; then
  cur="$("$UNITASK" -get-file 2>/dev/null | tr -d '\r')"
  cur_unix="$(to_unix "$cur")"
  if [[ -z "$cur" || ! -f "$cur_unix" ]]; then
    "$UNITASK" -set-file "$(native_path "$PROGRESS")" >/dev/null 2>&1 \
      || warnings+=("mospolytech-lms: не удалось прописать progress.json в настройки unitask.")
  elif [[ "$(cd "$(dirname "$cur_unix")" && pwd -P)/${cur_unix##*/}" != "$(cd "$(dirname "$PROGRESS")" && pwd -P)/${PROGRESS##*/}" ]]; then
    context+=("mospolytech-lms: unitask открывает другой файл: ${cur}. Если progress.json переехал, обнови paths.progress_file в profile.yaml.")
  fi
fi

# pandoc downloaded by install.sh: put the data bin directory on PATH for this session's Bash tool.
PANDOC=""
if command -v pandoc >/dev/null; then PANDOC="$(command -v pandoc)"
elif [[ -n "$DATA" && -x "$DATA/bin/pandoc$EXE" ]]; then
  PANDOC="$DATA/bin/pandoc$EXE"
  [[ -n "${CLAUDE_ENV_FILE:-}" ]] && printf 'export PATH="%s:$PATH"\n' "$DATA/bin" >> "$CLAUDE_ENV_FILE" 2>/dev/null
fi

# Settings for bin/typst-gost and bin/unitask, which run from the Bash tool and get no plugin variables.
if [[ -n "$DATA" ]]; then
  fonts=""
  [[ -n "$WS" ]] && fonts="$WS/fonts"
  if grep -qi microsoft /proc/version 2>/dev/null && [[ -d /mnt/c/Windows/Fonts ]]; then
    fonts="${fonts:+$fonts:}/mnt/c/Windows/Fonts"
  fi
  printf 'LMS_WORKSPACE=%s\nLMS_FONT_PATHS=%s\nLMS_PROGRESS_FILE=%s\n' "$WS" "$fonts" "$PROGRESS" > "$DATA/env"
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

# ---------- Optional MCP servers (scripts/setup.sh) ----------
# Registered by the user (claude mcp add, user scope → ~/.claude.json) or in a project .mcp.json.
mcp_registered() {
  local f
  for f in "$HOME/.claude.json" "$WS/.mcp.json" "$PWD/.mcp.json"; do
    [[ -f "$f" ]] && grep -q "\"$1\"[[:space:]]*:[[:space:]]*{" "$f" 2>/dev/null && return 0
  done
  return 1
}
opt_on() { case "$1" in true|1|yes|да) return 0 ;; esac; return 1; }
if opt_on "${CLAUDE_PLUGIN_OPTION_CONNECT_TELEGRAM:-}" && ! mcp_registered telegram; then
  warnings+=("mospolytech-lms: в настройках отмечен Telegram, но telegram-mcp не подключён. Выполните в терминале: $SETUP_CMD telegram")
fi
if opt_on "${CLAUDE_PLUGIN_OPTION_CONNECT_LK:-}" && ! mcp_registered mospolytech; then
  warnings+=("mospolytech-lms: в настройках отмечен личный кабинет, но mospolytech-mcp не подключён. Выполните в терминале: $SETUP_CMD lk")
fi

if ((${#path_added[@]})); then
  warnings+=("mospolytech-lms: команда unitask добавлена в терминал ($(IFS=';'; echo "${path_added[*]}")). Откройте новое окно терминала, чтобы она заработала.")
fi

# ---------- Output ----------
if [[ -n "$WS" ]]; then
  context+=("mospolytech-lms: рабочая папка ${WS_RAW}; профиль ${WS_RAW}/profile.yaml; кеш ${WS_RAW}/cache; работы — paths.documents_dir из профиля (по умолчанию ${WS_RAW}/documents).")
fi
context+=("mospolytech-lms: LMS ${URL} — ${lms_status}. Отчёты Typst собираются командой typst-gost. Получение токена: ${LOGIN_CMD}.")
if [[ -n "$PROGRESS" ]]; then
  context+=("mospolytech-lms: учёт задач — ${PROGRESS} (paths.progress_file в profile.yaml); его показывает unitask. Чаты Telegram — ${WS_RAW}/telegram.yaml.")
fi
if [[ -n "$PANDOC" ]]; then
  context+=("mospolytech-lms: .docx читай так: \"${PANDOC}\" -t gfm --wrap=none файл.docx")
else
  context+=("mospolytech-lms: pandoc недоступен — .docx читай через python3 -I (zipfile, word/document.xml).")
fi
context+=("mospolytech-lms: необязательные компоненты (telegram-mcp, mospolytech-mcp для личного кабинета) ставятся командой ${SETUP_CMD} — без аргументов покажет, что уже стоит.")
# Read shows PDF pages only with poppler; without it scans cannot be read at all.
if ! command -v pdftoppm >/dev/null; then
  context+=("mospolytech-lms: poppler не установлен — Read не покажет страницы PDF. Смотри PDF и сканы заданий командой pdf-pages <файл.pdf> <папка> [страницы] и читай получившиеся PNG.")
fi

ctx="$(printf '%s\n' "${context[@]}")"
msg=""
((${#warnings[@]})) && msg="$(printf '%s\n' "${warnings[@]}")"

printf '{'
[[ -n "$msg" ]] && printf '"systemMessage":%s,' "$(json_str "${msg%$'\n'}")"
printf '"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$(json_str "${ctx%$'\n'}")"
exit 0
