---
name: settings
description: Настройки плагина mospolytech-lms — где лежат профиль, чаты Telegram, progress.json, свои настройки и серверы, и правка их со слов пользователя. Используй, когда пользователь спрашивает, где настройки или файлы плагина, просит поменять данные профиля (группа, вариант, преподаватель, ФИО), добавить или убрать чат Telegram, перенести progress.json или папку работ, сменить модель или формат отчёта, подключить или переподключить Telegram и личный кабинет, войти в ЛК заново, проверить, что установлено.
---

# Настройки плагина

**Язык общения — русский.**

Пути берутся из контекста mospolytech-lms в начале сессии: рабочая папка `<ws>` = `${user_config.workspace_dir}`, путь к `progress.json`, команда `setup.sh`. Если контекста нет — `<ws>` из `${user_config.workspace_dir}`, `setup.sh` — `${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh` (на Windows — `setup.ps1` рядом).

## Где что лежит

| Файл | Что в нём | Как менять |
|---|---|---|
| `<ws>/profile.yaml` | ФИО, группа, факультет, кафедра, направление; `paths.documents_dir` (папка работ), `paths.progress_file`; по курсам — вариант, преподаватели для титульника | правишь сам (Edit), не трогая остальное. Значение `none` — осознанное «не указывать» |
| `<ws>/telegram.yaml` | учебные чаты: название, id, где лежит, когда читать (`read`), предметы (`subjects`), курсы LMS (`course_ids`), темы форумов, описание `about`; `ignore` — чаты, которые не читать | правишь сам по образцу `${CLAUDE_PLUGIN_ROOT}/telegram.example.yaml`. Если `chats: []` — замени списком записей |
| `progress.json` (путь — `paths.progress_file`, по умолчанию `<ws>/progress.json`) | учёт задач и событий по предметам | по правилам `${CLAUDE_PLUGIN_ROOT}/skills/homework-info/references/README.md` |
| `<ws>/config.yaml` | свои значения поверх `${CLAUDE_PLUGIN_ROOT}/lms.config.yaml`: модели агентов (`models.solver`, `models.solver_effort`, `models.scout`, `models.telegram`), формат отчёта, имя файла, режим сдачи | создай, если нет; пиши только то, что меняется |
| настройки плагина в Claude Code | рабочая папка, адрес LMS, токен LMS, подтверждение отправки, галочки Telegram и ЛК | пользователь: `/plugin` → mospolytech-lms → Configure, или `claude plugin configure mospolytech-lms@mospolytech`. Токен — только `setup.sh lms` |
| `~/.local/share/mospolytech-lms/lk-mcp/` (Windows — `%LOCALAPPDATA%\mospolytech-lms\lk-mcp\`) | сервер личного кабинета: `.env` (пароль базы, ключ шифрования), `lk-login.env` (автовход) | только через `setup.sh lk …` |
| `~/.local/share/mospolytech-lms/telegram-mcp/.env` | telegram-mcp: api_id, api_hash, сессия | только через `setup.sh telegram` |

Пользователю удобнее всего: `setup.sh status` (всё установленное и пути к файлам настроек), `setup.sh edit <profile|telegram|progress|config|lk|tg>` (открыть файл в редакторе). Ты можешь запустить `setup.sh status` сам и показать результат.

## Правка со слов пользователя

- **Профиль**: «у меня вариант 7 по ML» → `courses.<course_id>.variant: 7` (course_id — из `<ws>/cache/index.md`; нет — найди курс, как в скилле `lms-lab`, шаг 1). «Не указывай преподавателя на титульнике» → `teachers: none`.
- **Чат Telegram**: «добавь чат группы 123-456» → запись в `chats` с `name`, и, что известно, `id`, `where`, `read` (по умолчанию `always`), `subjects` (ключи предметов из progress.json), `course_ids`, `about` (со слов пользователя: что там пишут и чему верить). Не знаешь id — не выдумывай: агент `tg-reader` найдёт чат по названию и вернёт id. Убрать чат — удали запись или перенеси в `ignore` с причиной.
- **Перенос progress.json**: перенеси файл, обнови `paths.progress_file` в `profile.yaml` и выполни `unitask -set-file "<новый путь>"`. Если пользователь перенёс сам — только последние два шага.
- **Папка работ**: `paths.documents_dir` в `profile.yaml`; существующие папки работ перенеси, только если пользователь попросил.
- **Рабочая папка целиком**: пользователь меняет её в настройках плагина и сам переносит папку; после перезапуска Claude Code хук пропишет новый путь к progress.json в unitask, если старого файла больше нет.

После правки YAML проверь, что он читается (`python3 -I -c "import yaml…"` может не быть — тогда хотя бы перечитай файл), и коротко скажи, что поменял.

## Подключения и вход

**Никогда не проси у пользователя пароль, код или токен в чате** (ЛК, LMS, Telegram) и не вызывай с ними `lk_login`: всё, что требует пароля или кода, пользователь делает сам в отдельном окне терминала — не через `!` в Claude Code (там нет TTY).

| Что | Команда для пользователя |
|---|---|
| токен LMS (нет или «недействителен») | `setup.sh lms` |
| Telegram не подключён / сервер `telegram` не запускается | `setup.sh telegram` |
| личный кабинет не подключён | `setup.sh lk` (нужен Docker) |
| ЛК отвечает «Invalid token», «сессия истекла», отдаёт только кеш | `setup.sh lk relogin` — откроет страницу входа на локальном сервере (`http://127.0.0.1:8770/login`) и, если ключ поменялся, обновит его в Claude Code. Чтобы это не повторялось — `setup.sh lk auto` (сервер сам входит заново; логин и пароль хранятся локально в `lk-login.env`) |
| остановить сервер ЛК | `setup.sh lk --down` |

Если сервер `mospolytech` пользователь подключал не через `setup.sh` (свой сервер), `setup.sh lk relogin` не подойдёт — подскажи страницу `/login` его сервера.

После подключения или нового ключа нужен перезапуск Claude Code (или `/mcp` → Reconnect).
