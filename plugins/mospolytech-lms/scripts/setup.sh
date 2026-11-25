#!/usr/bin/env bash
# Shows what the plugin has installed and sets up the optional parts. Run it in your own terminal:
# logins ask for passwords and codes, which Claude's Bash tool cannot type.
#
#   setup.sh                  status and a menu of what can be added
#   setup.sh status           status only
#   setup.sh lms              LMS token (same as login.sh)
#   setup.sh telegram         telegram-mcp: read-only access to your Telegram chats
#   setup.sh lk               mospolytech-mcp in Docker: schedule, messages and notifications of the
#                             student portal (lk.mospolytech.ru)
#   setup.sh lk --down        stop the portal server (data is kept)
#
# Without a terminal (run by Claude) only the steps that need no input are done, and the script says
# which command to run by hand. Every step is idempotent: running it again continues where it stopped.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TELEGRAM_MCP_REPO=https://github.com/chigwell/telegram-mcp.git
TELEGRAM_MCP_TAG=v3.3.4          # PyPI "telegram-mcp" is a different project: always install from git
# mospolytech-mcp 1.0.1 (login fix: the portal API moved to old-e.mospolytech.ru). The release tag is
# not published yet, so the image is pinned by digest: the build of main at cb9fcd2, same as their prod.
LK_IMAGE=ghcr.io/edeev/mospolytech-mcp@sha256:d8969cbda6162e7b8dbc83b32aa5020cd1a11257000b45aed3c653c53e40357b
LK_PORT=8770                     # 8765 is telegram-mcp's default HTTP port
LK_DB_PORT=8771                  # Postgres for the server in host network mode (127.0.0.1 only)

is_windows() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac; return 1; }
is_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }
native() { if is_windows && command -v cygpath >/dev/null; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
tty_ok() { [[ -t 0 && -t 1 ]]; }
# Where to run interactive steps: a real terminal window. "! command" in Claude Code has no TTY.
in_terminal() { printf 'в отдельном окне терминала (не через «!» в Claude Code — там нельзя ввести пароль): %s %s' "$(native "$ROOT/scripts/setup.sh")" "$1"; }
if [[ -t 1 ]]; then G=$'\033[32m' Y=$'\033[33m' R=$'\033[31m' N=$'\033[0m'; else G="" Y="" R="" N=""; fi
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
no()   { printf '  %s·%s %s\n' "$Y" "$N" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$R" "$N" "$*"; }
say()  { printf '%s\n' "$*"; }
die()  { printf '%s%s%s\n' "$R" "$*" "$N" >&2; exit 1; }
ask_yes() { # ask_yes <question>: true on "y"/"д"; false without a terminal
  tty_ok || return 1
  local a; read -r -p "$1 [y/N] " a
  case "$a" in y|Y|yes|д|Д|да) return 0 ;; esac; return 1
}

# Where the optional servers live: outside the plugin folder, which is replaced on every update.
if is_windows && [[ -n "${LOCALAPPDATA:-}" ]]; then
  STATE="$(cygpath -u "$LOCALAPPDATA")/mospolytech-lms"
else
  STATE="${XDG_DATA_HOME:-$HOME/.local/share}/mospolytech-lms"
fi

# Plugin data directory (moodle-mcp, Typst, pandoc, unitask), found the same way as bin/typst-gost.
DATA="${CLAUDE_PLUGIN_DATA:-}"
if [[ -z "$DATA" ]]; then
  for d in "$HOME"/.claude/plugins/data/mospolytech-lms*; do
    [[ -d "$d/bin" ]] && { DATA="$d"; break; }
  done
fi
EXE=""; is_windows && EXE=".exe"

have_claude() { command -v claude >/dev/null; }
plugin_id() {
  local id
  for id in mospolytech-lms@mospolytech mospolytech-lms; do
    claude plugin configure "$id" >/dev/null 2>&1 && { printf '%s' "$id"; return 0; }
  done
  return 1
}
# workspace_dir from the plugin settings (sensitive values come back empty, so nothing secret here).
workspace_dir() {
  have_claude || return 0
  local id; id="$(plugin_id)" || return 0
  claude plugin configure "$id" --json 2>/dev/null | tr -d '\n' \
    | sed -n 's/.*"workspace_dir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed 's/\\\\/\\/g'
}
# mark_option <connect_telegram|connect_lk>: ticks the option once the component is connected.
mark_option() {
  have_claude || return 0
  local id; id="$(plugin_id)" || return 0
  printf '{"%s":"true"}' "$1" | claude plugin configure "$id" --values-stdin >/dev/null 2>&1 || true
}
mcp_registered() {
  if have_claude && claude mcp get "$1" >/dev/null 2>&1; then return 0; fi
  [[ -f "$HOME/.claude.json" ]] && grep -q "\"$1\"[[:space:]]*:[[:space:]]*{" "$HOME/.claude.json"
}

# ---------------------------------------------------------------- status
status() {
  say "Плагин mospolytech-lms"
  if [[ -z "$DATA" ]]; then
    bad "инструменты не установлены — откройте Claude Code с включённым плагином, он скачает их при старте"
  else
    local t
    for t in moodle-mcp typst pandoc; do
      if [[ -x "$DATA/bin/$t$EXE" ]]; then ok "$t $(cat "$DATA/bin/.$t-version" 2>/dev/null)"
      elif [[ "$t" == pandoc ]] && command -v pandoc >/dev/null; then ok "pandoc (системный)"
      else bad "$t не установлен — перезапустите сессию Claude Code"; fi
    done
    if [[ -x "$DATA/unitask/unitask$EXE" ]]; then
      if command -v unitask >/dev/null; then ok "unitask $(cat "$DATA/unitask/.unitask-version" 2>/dev/null) — команда unitask работает в терминале"
      else no "unitask установлен, но в этом терминале команды ещё нет — откройте новое окно"; fi
    else no "unitask не установлен (появится после выпуска релиза и перезапуска сессии)"; fi
  fi
  if have_claude; then
    # Plain output lists every option as "… (optional, sensitive, set)" or "(…, not set)".
    local line
    line="$( { claude plugin configure mospolytech-lms@mospolytech 2>/dev/null || claude plugin configure mospolytech-lms 2>/dev/null; } | grep 'moodle_token')"
    case "$line" in
      *"not set"*) no "токен LMS не задан — setup.sh lms" ;;
      *set*)       ok "токен LMS задан (проверяется при старте сессии)" ;;
    esac
  fi
  say ""
  say "Необязательно"
  if mcp_registered telegram; then ok "Telegram (telegram-mcp) подключён"
  else no "Telegram не подключён — setup.sh telegram"; fi
  if mcp_registered mospolytech; then ok "Личный кабинет (mospolytech-mcp) подключён"
  else no "Личный кабинет не подключён — setup.sh lk (нужен Docker)"; fi
  if command -v docker >/dev/null; then
    local derr
    if derr="$(docker info 2>&1 >/dev/null)"; then ok "Docker работает"
    elif [[ "$derr" == *"permission denied"* ]]; then no "Docker работает, но у $USER нет доступа (группа docker) — setup.sh lk подскажет"
    else no "Docker установлен, но не запущен"; fi
  else no "Docker не установлен (нужен только для личного кабинета)"; fi
}

# ---------------------------------------------------------------- docker
DOCKER=(docker)
ensure_docker() {
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    local err
    err="$(docker info 2>&1 >/dev/null)" && return 0
    if is_windows || [[ "$(uname -s)" == Darwin ]]; then
      die "Docker установлен, но не запущен. Запустите Docker Desktop и повторите: setup.sh lk"
    fi
    if [[ "$err" == *"permission denied"* ]]; then
      docker_permission
      return 0
    fi
    die "Служба Docker не запущена. Выполните: sudo systemctl start docker — и повторите setup.sh lk"
  fi
  say "Для личного кабинета нужен Docker (сервер и база данных работают в контейнерах)."
  tty_ok || die "Docker не установлен. Запустите $(in_terminal lk) — скрипт предложит установить Docker."
  if is_windows; then
    command -v winget >/dev/null || die "Установите Docker Desktop: https://docs.docker.com/desktop/setup/install/windows-install/ — и повторите setup.sh lk"
    ask_yes "Установить Docker Desktop через winget?" || die "Установите Docker Desktop вручную и повторите setup.sh lk"
    winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements \
      || die "winget не смог установить Docker Desktop"
    die "Docker Desktop установлен. Перезагрузите компьютер (нужен WSL 2), запустите Docker Desktop и повторите setup.sh lk"
  elif [[ "$(uname -s)" == Darwin ]]; then
    command -v brew >/dev/null || die "Установите Docker Desktop: https://docs.docker.com/desktop/setup/install/mac-install/ — и повторите setup.sh lk"
    ask_yes "Установить Docker Desktop через Homebrew (brew install --cask docker)?" || die "Установите Docker Desktop вручную и повторите setup.sh lk"
    brew install --cask docker || die "brew не смог установить Docker Desktop"
    open -a Docker 2>/dev/null || true
    die "Docker Desktop установлен и запускается. Дождитесь значка кита в строке меню и повторите setup.sh lk"
  else
    if is_wsl; then
      say "Вы в WSL. Удобнее всего — Docker Desktop в Windows с включённой интеграцией:"
      say "  https://docs.docker.com/desktop/setup/install/windows-install/  →  Settings → Resources → WSL integration"
      say "Можно и поставить Docker Engine прямо в WSL (нужен sudo)."
    fi
    ask_yes "Установить Docker Engine официальным скриптом get.docker.com (нужен sudo)?" \
      || die "Установите Docker (https://docs.docker.com/engine/install/) и повторите setup.sh lk"
    local tmp; tmp="$(mktemp -d)"
    curl -fsSL https://get.docker.com -o "$tmp/get-docker.sh" || die "не удалось скачать get.docker.com"
    sudo sh "$tmp/get-docker.sh" || die "установка Docker завершилась ошибкой"
    rm -rf "$tmp"
    sudo usermod -aG docker "$USER" 2>/dev/null || true
    sudo systemctl enable --now docker 2>/dev/null || sudo service docker start 2>/dev/null || true
    die "Docker установлен. Перелогиньтесь (или выполните: newgrp docker), чтобы работать с ним без sudo, и повторите setup.sh lk"
  fi
}

# The daemon runs, but this user may not talk to /var/run/docker.sock: not in the "docker" group,
# or added to it after this login session started (group membership applies to new sessions only).
docker_permission() {
  local in_group=false
  getent group docker 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep -qx "$USER" && in_group=true
  if $in_group; then
    say "Вы уже в группе docker, но эта сессия входа старше: группа применяется после нового входа."
    say "Выйдите из системы и войдите снова (или выполните в этом терминале: newgrp docker)."
  else
    say "Docker работает, но у пользователя $USER нет к нему доступа (нет в группе docker)."
    if ask_yes "Добавить $USER в группу docker (sudo usermod -aG docker $USER)?"; then
      sudo usermod -aG docker "$USER" && say "Готово. Группа заработает после нового входа в систему (или: newgrp docker)."
    fi
  fi
  tty_ok && command -v sudo >/dev/null || die "Повторите setup.sh lk после нового входа в систему."
  ask_yes "Продолжить сейчас через sudo docker?" || die "Повторите setup.sh lk после нового входа в систему."
  sudo docker info >/dev/null 2>&1 || die "sudo docker тоже не работает: проверьте sudo systemctl status docker"
  DOCKER=(sudo docker)
}

# ---------------------------------------------------------------- lk
# Docker Engine on Linux: the server joins the host network (docker-compose.host.yaml), so a VPN
# client's domain exclusions apply to its requests. Docker Desktop's host network is its own VM, so
# there the default bridge network stays.
COMPOSE_ARGS=(-f docker-compose.yaml)
lk_compose_files() {
  local os
  is_windows && return 0
  [[ "$(uname -s)" == Linux ]] || return 0
  os="$("${DOCKER[@]}" info --format '{{.OperatingSystem}}' 2>/dev/null)"
  [[ "$os" == *"Docker Desktop"* ]] && return 0
  COMPOSE_ARGS=(-f docker-compose.yaml -f docker-compose.host.yaml)
}
lk_compose() { (cd "$STATE/lk-mcp" && "${DOCKER[@]}" compose "${COMPOSE_ARGS[@]}" "$@"); }

# Postgres applies POSTGRES_PASSWORD only when it creates the database. If the pgdata volume is older
# than this .env (the folder was deleted and set up again, or an earlier attempt), migrate and the
# server fail with "password authentication failed". Start the database alone and set the password
# from .env over the container's local socket (trusted, no password needed); idempotent, keeps data.
lk_sync_db_password() {
  local envf="$STATE/lk-mcp/.env" user db pw i
  user="$(sed -n 's/^POSTGRES_USER=//p' "$envf")"
  db="$(sed -n 's/^POSTGRES_DB=//p' "$envf")"
  pw="$(sed -n 's/^POSTGRES_PASSWORD=//p' "$envf")"
  [[ -n "$user" && -n "$db" && "$pw" =~ ^[0-9a-f]+$ ]] || die "в $envf нет пароля базы; удалите файл и повторите setup.sh lk"
  lk_compose up -d db || die "не удалось запустить базу; подробности: cd \"$STATE/lk-mcp\" && docker compose logs db"
  # The first start initialises the data directory with a temporary server; retry until it is done.
  for i in $(seq 1 30); do
    if printf "ALTER USER \"%s\" PASSWORD '%s';\n" "$user" "$pw" \
         | lk_compose exec -T db psql -q -v ON_ERROR_STOP=1 -U "$user" -d "$db" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  die "не удалось выставить пароль базы; подробности: cd \"$STATE/lk-mcp\" && docker compose logs db"
}

lk() {
  local dir="$STATE/lk-mcp"
  if [[ "${1:-}" == --down ]]; then
    [[ -f "$dir/docker-compose.yaml" ]] || die "сервер личного кабинета не устанавливался"
    ensure_docker
    lk_compose_files
    lk_compose down && ok "сервер личного кабинета остановлен (данные сохранены)"
    return
  fi
  ensure_docker
  mkdir -p "$dir" || die "не удалось создать $dir"
  cp "$ROOT/templates/lk-mcp/docker-compose.yaml" "$ROOT/templates/lk-mcp/docker-compose.host.yaml" "$dir/"
  lk_compose_files
  if [[ ! -s "$dir/.env" ]]; then
    say "Создаю настройки сервера (пароль базы и ключ шифрования — случайные)…"
    local pw key
    pw="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    key="$("${DOCKER[@]}" run --rm "$LK_IMAGE" python -m mospolytech_mcp.crypto | tr -d '\r\n')" \
      || die "не удалось скачать образ mospolytech-mcp"
    [[ -n "$key" ]] || die "образ не выдал ключ шифрования"
    (umask 077; printf 'POSTGRES_DB=mospolytech_mcp\nPOSTGRES_USER=mospolytech_mcp\nPOSTGRES_PASSWORD=%s\nMCP_SECRET_KEY=%s\nLK_PORT=%s\n' \
      "$pw" "$key" "$LK_PORT" > "$dir/.env")
  fi
  # A newer plugin may pin a newer image: rewrite only the image line, keep the generated secrets.
  grep -v -e '^LK_IMAGE=' -e '^APP_TAG=' "$dir/.env" > "$dir/.env.new"
  printf 'LK_IMAGE=%s\n' "$LK_IMAGE" >> "$dir/.env.new"
  grep -q '^LK_DB_PORT=' "$dir/.env.new" || printf 'LK_DB_PORT=%s\n' "$LK_DB_PORT" >> "$dir/.env.new"
  (umask 077; cat "$dir/.env.new" > "$dir/.env"); rm -f "$dir/.env.new"
  say "Запускаю сервер личного кабинета (первый раз скачивается ~200 МБ)…"
  if [[ "${COMPOSE_ARGS[*]}" == *host* ]]; then
    say "Сервер работает в сети хоста: исключения доменов в VPN-клиенте действуют и на него."
  fi
  lk_sync_db_password
  lk_compose up -d --remove-orphans || die "docker compose up завершился ошибкой; подробности: cd \"$dir\" && docker compose ${COMPOSE_ARGS[*]} logs"
  local i
  for i in $(seq 1 60); do
    curl -fsS "http://127.0.0.1:$LK_PORT/health" >/dev/null 2>&1 && break
    sleep 2
  done
  curl -fsS "http://127.0.0.1:$LK_PORT/health" >/dev/null 2>&1 \
    || die "сервер не ответил на /health за 2 минуты; подробности: cd \"$dir\" && docker compose ${COMPOSE_ARGS[*]} logs mcp"
  ok "сервер работает: http://127.0.0.1:$LK_PORT (перезапускается вместе с Docker)"

  if mcp_registered mospolytech; then
    ok "mospolytech уже подключён к Claude Code"
    ask_yes "Подключить заново (например, с новым ключом)?" || return 0
    claude mcp remove mospolytech --scope user >/dev/null 2>&1 || true
  fi
  say ""
  say "Вход в личный кабинет: откройте в браузере http://127.0.0.1:$LK_PORT/login и войдите логином"
  say "и паролем ЛК. Пароль уходит только на ваш локальный сервер; страница выдаст ключ mpk_…"
  local cmd="claude mcp add --scope user --transport http mospolytech http://127.0.0.1:$LK_PORT/mcp --header \"Authorization: Bearer <ключ mpk_…>\""
  if ! tty_ok || ! have_claude; then
    say "Затем выполните в терминале:"
    say "  $cmd"
    return 0
  fi
  local k
  read -r -s -p "Вставьте ключ mpk_… (ввод скрыт): " k; echo
  [[ "$k" == mpk_* ]] || die "ключ должен начинаться с mpk_. Повторите setup.sh lk"
  claude mcp add --scope user --transport http mospolytech "http://127.0.0.1:$LK_PORT/mcp" \
    --header "Authorization: Bearer $k" >/dev/null || die "claude mcp add завершился ошибкой; выполните вручную: $cmd"
  mark_option connect_lk
  ok "личный кабинет подключён. Перезапустите сессию Claude Code."
}

# ---------------------------------------------------------------- telegram
find_uv() {
  command -v uv 2>/dev/null && return 0
  local c
  for c in "$HOME/.local/bin/uv" "$HOME/.cargo/bin/uv" "$HOME/.local/bin/uv.exe"; do
    [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# The generator names the session TELEGRAM_SESSION_STRING_<LABEL> when an account label was typed.
# The server is registered for the default account, so copy the first labelled session to the
# default name (the labelled line stays; nothing is lost).
promote_labelled_session() {
  local envf=$1 line
  grep -q '^TELEGRAM_SESSION_STRING=.' "$envf" 2>/dev/null && return 0
  line="$(grep -m1 '^TELEGRAM_SESSION_STRING_[A-Za-z0-9_]*=.' "$envf" 2>/dev/null)" || return 0
  (umask 077; printf 'TELEGRAM_SESSION_STRING=%s\n' "${line#*=}" >> "$envf")
  ok "сессия ${line%%=*} сохранена и как TELEGRAM_SESSION_STRING"
}

# Claude Code starts its own telegram-mcp for every session (and on Reconnect, before the old one
# exits). With the default exclusive session lock the second process waits 20 s and quits, so the
# server shows as failed. All of them run on this computer and reach Telegram from one IP, which is
# the case telegram-mcp's "shared" lock is for. An explicit value already in .env is kept.
ensure_shared_lock() {
  local envf=$1
  [[ -f "$envf" ]] || return 0
  grep -q '^TELEGRAM_SESSION_LOCK=' "$envf" && return 0
  (umask 077; printf 'TELEGRAM_SESSION_LOCK=shared\n' >> "$envf")
  ok "TELEGRAM_SESSION_LOCK=shared добавлен в .env (несколько сессий Claude Code делят одну сессию Telegram)"
}

telegram() {
  local dir="$STATE/telegram-mcp" uv
  ensure_shared_lock "$dir/.env"
  if mcp_registered telegram; then
    ok "telegram уже подключён к Claude Code — ничего не меняю"
    say "  (плагину нужен сервер с именем telegram; если он подключён с правом отправки, агенты всё равно только читают)"
    return 0
  fi
  command -v git >/dev/null || die "нужен git"
  if ! uv="$(find_uv)"; then
    say "telegram-mcp ставится через uv (менеджер Python-окружений, ставится в домашнюю папку без sudo)."
    tty_ok || die "uv не установлен. Запустите $(in_terminal telegram)"
    ask_yes "Установить uv официальным установщиком astral.sh?" || die "Установите uv (https://docs.astral.sh/uv/) и повторите setup.sh telegram"
    if is_windows; then
      powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "irm https://astral.sh/uv/install.ps1 | iex" || die "установка uv завершилась ошибкой"
    else
      local tmp; tmp="$(mktemp -d)"
      curl -LsSf https://astral.sh/uv/install.sh -o "$tmp/uv-install.sh" && sh "$tmp/uv-install.sh" || die "установка uv завершилась ошибкой"
      rm -rf "$tmp"
    fi
    uv="$(find_uv)" || die "uv установлен, но не найден — откройте новый терминал и повторите setup.sh telegram"
  fi
  ok "uv: $uv"

  mkdir -p "$STATE" || die "не удалось создать $STATE"
  if [[ ! -d "$dir/.git" ]]; then
    git clone -q --depth 1 --branch "$TELEGRAM_MCP_TAG" "$TELEGRAM_MCP_REPO" "$dir" || die "не удалось скачать telegram-mcp"
  elif [[ "$(git -C "$dir" describe --tags 2>/dev/null)" != "$TELEGRAM_MCP_TAG" ]]; then
    git -C "$dir" fetch -q --depth 1 origin tag "$TELEGRAM_MCP_TAG" && git -C "$dir" checkout -q "$TELEGRAM_MCP_TAG" \
      || die "не удалось обновить telegram-mcp до $TELEGRAM_MCP_TAG"
  fi
  (cd "$dir" && "$uv" sync --frozen -q) || die "uv sync завершился ошибкой"
  ok "telegram-mcp $TELEGRAM_MCP_TAG: $dir"

  local envf="$dir/.env"
  if ! grep -q '^TELEGRAM_API_ID=[0-9]' "$envf" 2>/dev/null || ! grep -q '^TELEGRAM_API_HASH=.' "$envf" 2>/dev/null; then
    tty_ok || die "Дальше нужен вход в Telegram. Запустите $(in_terminal telegram)"
    say ""
    say "Нужны api_id и api_hash вашего Telegram-приложения: https://my.telegram.org/apps"
    say "(войдите номером телефона → API development tools → создайте приложение с любым названием)."
    local id hash
    read -r -p "api_id: " id
    [[ "$id" =~ ^[0-9]+$ ]] || die "api_id — это число"
    read -r -s -p "api_hash (ввод скрыт): " hash; echo
    [[ "$hash" =~ ^[0-9a-f]{32}$ ]] || die "api_hash — 32 шестнадцатеричных символа"
    (umask 077; printf 'TELEGRAM_API_ID=%s\nTELEGRAM_API_HASH=%s\n' "$id" "$hash" > "$envf")
  fi
  chmod 600 "$envf" 2>/dev/null || true
  ensure_shared_lock "$envf"
  promote_labelled_session "$envf"
  if ! grep -q '^TELEGRAM_SESSION_STRING=.' "$envf"; then
    tty_ok || die "Дальше нужен вход в Telegram. Запустите $(in_terminal telegram)"
    say ""
    say "Вход в Telegram. Удобнее по QR-коду: Telegram на телефоне → Настройки → Устройства → Подключить устройство."
    say "На вопрос «Account label» просто нажмите Enter, а в конце на «update your .env file?» ответьте y."
    (cd "$dir" && "$uv" run -q session_string_generator.py --qr) || die "вход в Telegram не удался; повторите setup.sh telegram"
    promote_labelled_session "$envf"
    grep -q '^TELEGRAM_SESSION_STRING=.' "$envf" \
      || die "сессия не сохранена в $envf (на последний вопрос генератора нужно ответить y). Повторите setup.sh telegram"
    chmod 600 "$envf" 2>/dev/null || true
  fi
  ok "вход в Telegram выполнен (ключи — в $envf, доступ только у вас)"

  have_claude || die "команда claude не найдена; подключите вручную: claude mcp add --scope user telegram -e TELEGRAM_EXPOSED_TOOLS=read-only+download_media -e TELEGRAM_TRANSCRIBE=off -- \"$(native "$uv")\" --directory \"$(native "$dir")\" run telegram-mcp"
  # Read-only: the plugin never writes to chats. download_media saves attachments locally and is not
  # annotated read-only, so it is allowed by name. Voice transcription would upload audio to a
  # third-party service by default, so it is off.
  # download_media writes only into allowed roots: the folder Claude Code runs in, plus the workspace
  # (agents save chat attachments into work folders there).
  local ws roots=()
  ws="$(workspace_dir)"
  [[ -n "$ws" ]] && roots=(-e "TELEGRAM_ALLOWED_ROOTS=$ws")
  claude mcp add --scope user telegram \
    -e TELEGRAM_EXPOSED_TOOLS=read-only+download_media -e TELEGRAM_TRANSCRIBE=off ${roots[@]+"${roots[@]}"} \
    -- "$(native "$uv")" --directory "$(native "$dir")" run telegram-mcp >/dev/null \
    || die "claude mcp add завершился ошибкой"
  mark_option connect_telegram
  ok "Telegram подключён (только чтение). Перезапустите сессию Claude Code."
  say "Список учебных чатов — в telegram.yaml рабочей папки; Claude поможет его заполнить."
}

lms() {
  if is_windows; then
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(native "$ROOT/scripts/login.ps1")" "$@"
  else
    bash "$ROOT/scripts/login.sh" "$@"
  fi
}

menu() {
  status
  tty_ok || return 0
  say ""
  say "Что сделать?  1) токен LMS   2) Telegram   3) личный кабинет   Enter) ничего"
  local c; read -r -p "> " c
  case "$c" in
    1) lms ;;
    2) telegram ;;
    3) lk ;;
    *) ;;
  esac
}

case "${1:-}" in
  "")        menu ;;
  status)    status ;;
  lms|login) shift; lms "$@" ;;
  telegram|tg) telegram ;;
  lk)        shift; lk "${1:-}" ;;
  -h|--help|help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *) die "неизвестная команда: $1 (см. setup.sh --help)" ;;
esac
