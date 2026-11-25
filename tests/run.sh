#!/usr/bin/env bash
# Offline checks for the plugin scripts: hook guards, SessionStart, the checksum-verified install
# and a Typst build with the bundled template. No LMS token is used and nothing is sent anywhere.
# Runs on Linux, macOS (bash 3.2) and Git Bash on Windows; CI runs it on all three.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$REPO/plugins/mospolytech-lms"
SCRIPTS="$PLUGIN/scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# install.sh would add unitask to the real user's PATH (rc files, Windows registry); user-path.sh is
# tested separately with a fake HOME.
export LMS_NO_USER_PATH=1

failures=0
pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '      %s\n' "$2"; failures=$((failures + 1)); }

# expect <name> <decision|allow> <guard> <json>: "allow" means the guard printed nothing.
expect() {
  local name=$1 want=$2 guard=$3 json=$4 out got
  out="$(printf '%s' "$json" | bash "$SCRIPTS/$guard")"
  if [[ -z "$out" ]]; then got=allow
  else got="$(printf '%s' "$out" | sed -n 's/.*"permissionDecision":"\([a-z]*\)".*/\1/p')"; fi
  if [[ "$got" == "$want" ]]; then pass "$name"; else fail "$name" "expected $want, got ${got:-?}: $out"; fi
}

echo "== syntax"
for f in "$SCRIPTS"/*.sh "$REPO"/.github/scripts/*.sh "$PLUGIN/bin/typst-gost" "$PLUGIN/bin/pdf-pages" "$PLUGIN/bin/unitask" "$REPO/tests/run.sh"; do
  if bash -n "$f"; then pass "bash -n ${f#"$REPO"/}"; else fail "bash -n ${f#"$REPO"/}"; fi
done

# bash 3.2 (macOS) takes the bytes of a non-ASCII letter right after $name as part of the name.
unbraced="$(LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*'$'[\x80-\xff]' "$SCRIPTS"/*.sh "$PLUGIN/bin/typst-gost" "$PLUGIN/bin/pdf-pages" "$PLUGIN/bin/unitask" || true)"
[[ -z "$unbraced" ]] && pass "no \$var right before non-ASCII text" || fail "no \$var right before non-ASCII text" "use \${var}: $unbraced"

# Windows PowerShell 5.1 reads a .ps1 without BOM as ANSI and mangles the Russian text into a parse error.
for f in "$PLUGIN"/bin/*.ps1 "$PLUGIN"/scripts/*.ps1; do
  if [[ "$(head -c3 "$f" | od -An -tx1 | tr -d ' \n')" == efbbbf ]]; then pass "UTF-8 BOM ${f#"$REPO"/}"
  else fail "UTF-8 BOM ${f#"$REPO"/}" "save as UTF-8 with BOM"; fi
done

echo "== guard-upload"
WS="$TMP/ws"
mkdir -p "$WS/documents/c1/lab-1" "$WS/works"
echo report > "$WS/documents/c1/lab-1/report.pdf"
: > "$WS/documents/c1/lab-1/empty.pdf"
echo x > "$TMP/outside.pdf"
export CLAUDE_PLUGIN_OPTION_WORKSPACE_DIR="$WS"
expect "file in documents"        allow guard-upload.sh "{\"transcript_path\":\"/x/t.jsonl\",\"tool_input\":{\"path\":\"$WS/documents/c1/lab-1/report.pdf\",\"filename\":null}}"
expect "relative path from cwd"   allow guard-upload.sh "{\"cwd\":\"$WS\",\"tool_input\":{\"path\":\"documents/c1/lab-1/report.pdf\"}}"
expect "file outside documents"   deny  guard-upload.sh "{\"tool_input\":{\"path\":\"$TMP/outside.pdf\"}}"
expect "escape with ../"          deny  guard-upload.sh "{\"tool_input\":{\"path\":\"$WS/documents/../../outside.pdf\"}}"
expect "empty file"               deny  guard-upload.sh "{\"tool_input\":{\"path\":\"$WS/documents/c1/lab-1/empty.pdf\"}}"
expect "missing file"             deny  guard-upload.sh "{\"tool_input\":{\"path\":\"$WS/documents/nope.pdf\"}}"
expect "no path"                  deny  guard-upload.sh '{"tool_input":{}}'
printf 'paths:\n  documents_dir: "works" # custom\n' > "$WS/profile.yaml"
expect "custom documents_dir"     deny  guard-upload.sh "{\"tool_input\":{\"path\":\"$WS/documents/c1/lab-1/report.pdf\"}}"
rm "$WS/profile.yaml"
CLAUDE_PLUGIN_OPTION_WORKSPACE_DIR="" expect "no workspace" deny guard-upload.sh "{\"tool_input\":{\"path\":\"$WS/documents/c1/lab-1/report.pdf\"}}"

echo "== guard-submit"
expect "file submission asks"     ask   guard-submit.sh '{"tool_input":{"assignment_id":1,"item_id":123,"finalize":true}}'
expect "text submission asks"     ask   guard-submit.sh '{"tool_input":{"assignment_id":1,"text":"<p>Ответ, \"в кавычках\"</p>"}}'
expect "finalize only asks"       ask   guard-submit.sh '{"tool_input":{"assignment_id":1,"finalize":true}}'
expect "empty text denied"        deny  guard-submit.sh '{"tool_input":{"assignment_id":1,"text":""}}'
expect "nothing denied"           deny  guard-submit.sh '{"tool_input":{"assignment_id":1}}'
CLAUDE_PLUGIN_OPTION_SUBMIT_CONFIRMATION="не спрашивать" expect "confirmation off" allow guard-submit.sh '{"tool_input":{"assignment_id":1,"text":"x"}}'
CLAUDE_PLUGIN_OPTION_SUBMIT_CONFIRMATION=off expect "confirmation off (old value)" allow guard-submit.sh '{"tool_input":{"assignment_id":1,"text":"x"}}'

echo "== confirmation dialog text"
DLG="$TMP/dlg"
mkdir -p "$DLG/data" "$WS/documents/42-kurs/pr-1"
printf '{"assignment_id":4242,"attachments":[{"filename":"zadanie.pdf"}],"course":"Бухгалтерский учет ","draft_required":false,"name":"Задание практика 1","submission":{"files":[]}}' \
  > "$WS/documents/42-kurs/pr-1/assignment.json"
# upload_file result as a structured object, then as escaped JSON text inside an MCP content block
printf '{"tool_input":{"path":"%s","filename":null},"tool_response":{"uploaded":true,"item_id":777,"filename":"report.pdf"}}' "$WS/documents/c1/lab-1/report.pdf" \
  | CLAUDE_PLUGIN_DATA="$DLG/data" bash "$SCRIPTS/record-upload.sh"
printf '{"tool_input":{"path":"%s"},"tool_response":[{"type":"text","text":"{\\"uploaded\\":true,\\"item_id\\":888,\\"filename\\":\\"other.pdf\\"}"}]}' "$TMP/outside.pdf" \
  | CLAUDE_PLUGIN_DATA="$DLG/data" bash "$SCRIPTS/record-upload.sh"
grep -q $'^777\treport.pdf$' "$DLG/data/uploads.tsv" && pass "upload recorded (object result)" || fail "upload recorded (object result)" "$(cat "$DLG/data/uploads.tsv" 2>&1)"
grep -q $'^888\toutside.pdf$' "$DLG/data/uploads.tsv" && pass "upload recorded (text result)" || fail "upload recorded (text result)" "$(cat "$DLG/data/uploads.tsv" 2>&1)"
out="$(printf '{"tool_input":{"assignment_id":4242,"item_id":777}}' | CLAUDE_PLUGIN_DATA="$DLG/data" bash "$SCRIPTS/guard-submit.sh")"
for want in "«Задание практика 1» — Бухгалтерский учет\\n" "Файл: report.pdf" "сразу уйдёт преподавателю"; do
  [[ "$out" == *"$want"* ]] && pass "dialog shows: $want" || fail "dialog shows: $want" "$out"
done
out="$(printf '{"tool_input":{"assignment_id":9,"text":"<p>one two three</p>"}}' | CLAUDE_PLUGIN_DATA="$DLG/data" bash "$SCRIPTS/guard-submit.sh")"
[[ "$out" == *"задание 9 в LMS"* && "$out" == *"Ответ текстом, слов: 3"* ]] && pass "dialog without snapshot" || fail "dialog without snapshot" "$out"

echo "== session-start (downloads moodle-mcp and Typst, verifies checksums)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$TMP/data"
WS2="$TMP/ws2"
out="$(echo '{}' | CLAUDE_PLUGIN_OPTION_WORKSPACE_DIR="$WS2" CLAUDE_PLUGIN_OPTION_MOODLE_TOKEN= bash "$SCRIPTS/session-start.sh")"
case "$out" in
  '{'*'"hookEventName":"SessionStart"'*'}') pass "valid hook output" ;;
  *) fail "valid hook output" "$out" ;;
esac
[[ "$out" == *"нет токена LMS"* ]] && pass "missing token reported" || fail "missing token reported" "$out"
[[ "$out" == *"не удалось установить moodle-mcp"* || "$out" == *"не удалось установить typst"* ]] && fail "binaries installed" "$out" || pass "binaries installed"
for tool in moodle-mcp typst; do
  if [[ -x "$TMP/data/bin/$tool" || -x "$TMP/data/bin/$tool.exe" ]]; then pass "$tool present"; else fail "$tool present"; fi
done
[[ -f "$WS2/profile.yaml" && -f "$WS2/cache/index.md" && -d "$WS2/documents" ]] && pass "workspace created" || fail "workspace created"
[[ -s "$TMP/data/ca-bundle.pem" ]] && pass "ca bundle" || fail "ca bundle"
if command -v pandoc >/dev/null || [[ -x "$TMP/data/bin/pandoc" || -x "$TMP/data/bin/pandoc.exe" ]]; then pass "pandoc available"
else fail "pandoc available" "$out"; fi
[[ "$out" == *"не удалось установить pandoc"* ]] && fail "pandoc installed without errors" "$out" || pass "pandoc installed without errors"
if grep -Eq '"semester": "20[0-9]{2}-(autumn|spring)"' "$WS2/progress.json" 2>/dev/null && grep -q '"subjects": {}' "$WS2/progress.json"; then
  pass "progress.json skeleton in the workspace root"
else fail "progress.json skeleton in the workspace root" "$(cat "$WS2/progress.json" 2>/dev/null)"; fi
grep -qx "LMS_PROGRESS_FILE=$WS2/progress.json" "$TMP/data/env" && pass "progress path in env" || fail "progress path in env" "$(cat "$TMP/data/env")"
[[ "$out" == *"учёт задач — $WS2/progress.json"* ]] && pass "progress path in context" || fail "progress path in context" "$out"
echo '{"updated":"2026-01-01","subjects":{"x":{"name":"X","tasks":[]}}}' > "$WS2/progress.json"
echo '{}' | CLAUDE_PLUGIN_OPTION_WORKSPACE_DIR="$WS2" bash "$SCRIPTS/session-start.sh" >/dev/null
grep -q '"name":"X"' "$WS2/progress.json" && pass "existing progress.json kept" || fail "existing progress.json kept"
out="$(echo '{}' | CLAUDE_PLUGIN_OPTION_WORKSPACE_DIR= bash "$SCRIPTS/session-start.sh")"
[[ "$out" == *"не задана рабочая папка"* ]] && pass "missing workspace reported" || fail "missing workspace reported" "$out"

echo "== session-start: progress_file, unitask settings, optional MCP reminders"
WS3="$TMP/ws3"
mkdir -p "$WS3"
sed 's|^  progress_file: progress.json|  progress_file: study/tasks.json|' "$PLUGIN/profile.example.yaml" > "$WS3/profile.yaml"
# Fake unitask: -get-file prints $FAKE_UNITASK_FILE, -set-file records its argument.
UT_DATA="$TMP/utdata"
mkdir -p "$UT_DATA/bin" "$UT_DATA/unitask"
cp -p "$TMP/data/bin/"* "$UT_DATA/bin/"; cp "$TMP/data/bin/".*-version "$UT_DATA/bin/" 2>/dev/null
cp "$TMP/data/ca-bundle.pem" "$UT_DATA/"
for exe in unitask unitask.exe; do
  {
    echo '#!/usr/bin/env bash'
    echo 'case "$1" in'
    echo '  -get-file) printf "%s\n" "${FAKE_UNITASK_FILE:-}" ;;'
    echo "  -set-file) printf '%s\n' \"\$2\" > \"$UT_DATA/set-file\" ;;"
    echo 'esac'
  } > "$UT_DATA/unitask/$exe"
  chmod +x "$UT_DATA/unitask/$exe"
done
echo 0.1.0 > "$UT_DATA/unitask/.unitask-version"
run_ss() { echo '{}' | CLAUDE_PLUGIN_DATA="$UT_DATA" CLAUDE_PLUGIN_OPTION_WORKSPACE_DIR="$WS3" "$@" bash "$SCRIPTS/session-start.sh"; }
out="$(run_ss env FAKE_UNITASK_FILE=)"
[[ -f "$WS3/study/tasks.json" ]] && pass "paths.progress_file honoured" || fail "paths.progress_file honoured" "$out"
got="$(tr -d '\r' < "$UT_DATA/set-file" 2>/dev/null)"
want="$WS3/study/tasks.json"; command -v cygpath >/dev/null && want="$(cygpath -w "$want")"
[[ "$got" == "$want" ]] && pass "unitask pointed at progress.json" || fail "unitask pointed at progress.json" "got: $got"
rm -f "$UT_DATA/set-file"
run_ss env FAKE_UNITASK_FILE="$TMP/gone.json" >/dev/null
[[ -f "$UT_DATA/set-file" ]] && pass "unitask re-pointed when its file is gone" || fail "unitask re-pointed when its file is gone"
rm -f "$UT_DATA/set-file"
echo '{}' > "$TMP/mine.json"
mine="$TMP/mine.json"; command -v cygpath >/dev/null && mine="$(cygpath -w "$mine")"
out="$(run_ss env FAKE_UNITASK_FILE="$mine")"
[[ ! -f "$UT_DATA/set-file" ]] && pass "user's own unitask file kept" || fail "user's own unitask file kept"
[[ "$out" == *"unitask открывает другой файл"* ]] && pass "different unitask file noted" || fail "different unitask file noted" "$out"

FAKEHOME="$TMP/home"
mkdir -p "$FAKEHOME"
out="$(run_ss env HOME="$FAKEHOME" CLAUDE_PLUGIN_OPTION_CONNECT_TELEGRAM=true CLAUDE_PLUGIN_OPTION_CONNECT_LK=true)"
[[ "$out" == *"setup."*" telegram"* && "$out" == *"setup."*" lk"* ]] && pass "ticked but missing MCP servers reported" || fail "ticked but missing MCP servers reported" "$out"
printf '{"mcpServers": {"telegram": {"type": "stdio"}, "mospolytech": {"type": "http"}}}' > "$FAKEHOME/.claude.json"
out="$(run_ss env HOME="$FAKEHOME" CLAUDE_PLUGIN_OPTION_CONNECT_TELEGRAM=true CLAUDE_PLUGIN_OPTION_CONNECT_LK=true)"
[[ "$out" == *"не подключён"* ]] && fail "registered MCP servers not reported" "$out" || pass "registered MCP servers not reported"
out="$(run_ss env HOME="$TMP/nohome" CLAUDE_PLUGIN_OPTION_CONNECT_TELEGRAM=false)"
[[ "$out" == *"не подключён"* ]] && fail "unticked components not reported" "$out" || pass "unticked components not reported"

echo "== install.sh: tools fail independently"
IN_DATA="$TMP/indata"
mkdir -p "$IN_DATA/bin" "$TMP/nocurl"
cp -p "$TMP/data/bin/"* "$IN_DATA/bin/"; cp "$TMP/data/bin/".*-version "$IN_DATA/bin/" 2>/dev/null
printf '#!/bin/sh\nexit 22\n' > "$TMP/nocurl/curl"; chmod +x "$TMP/nocurl/curl"
out="$(PATH="$TMP/nocurl:$PATH" CLAUDE_PLUGIN_DATA="$IN_DATA" bash "$SCRIPTS/install.sh" 2>&1)"; code=$?
[[ $code == 0 && "$out" == *"failed: unitask:"* ]] && pass "optional tool failure is not fatal" || fail "optional tool failure is not fatal" "exit $code: $out"
rm -f "$IN_DATA/bin/.typst-version"
out="$(PATH="$TMP/nocurl:$PATH" CLAUDE_PLUGIN_DATA="$IN_DATA" bash "$SCRIPTS/install.sh" 2>&1)"; code=$?
[[ $code != 0 && "$out" == *"failed: typst:"* && "$out" != *"failed: moodle-mcp"* ]] && pass "required tool failure reported alone" || fail "required tool failure reported alone" "exit $code: $out"

echo "== pin-unitask.sh (release checksums into install.sh, on a copy)"
PIN="$TMP/pin"
mkdir -p "$PIN/.github/scripts" "$PIN/plugins/mospolytech-lms/scripts" "$PIN/plugins/mospolytech-lms/.claude-plugin"
cp "$REPO/.github/scripts/pin-unitask.sh" "$PIN/.github/scripts/"
cp "$SCRIPTS/install.sh" "$PIN/plugins/mospolytech-lms/scripts/"
cp "$PLUGIN/.claude-plugin/plugin.json" "$PIN/plugins/mospolytech-lms/.claude-plugin/"
for t in x86_64-unknown-linux-gnu.tar.gz aarch64-unknown-linux-gnu.tar.gz x86_64-apple-darwin.tar.gz aarch64-apple-darwin.tar.gz x86_64-pc-windows-msvc.zip; do
  printf '%s  unitask-9.8.7-%s\n' "$(printf 'a%.0s' $(seq 64))" "$t"
done > "$PIN/SUMS"
before="$(sed -n 's/^  "version": "\(.*\)".*/\1/p' "$PIN/plugins/mospolytech-lms/.claude-plugin/plugin.json")"
out="$(bash "$PIN/.github/scripts/pin-unitask.sh" 9.8.7 "$PIN/SUMS" 2>&1)"; code=$?
after="$(sed -n 's/^  "version": "\(.*\)".*/\1/p' "$PIN/plugins/mospolytech-lms/.claude-plugin/plugin.json")"
pinned="$PIN/plugins/mospolytech-lms/scripts/install.sh"
if [[ $code == 0 ]] && grep -q '^UNITASK_VERSION=9.8.7 ' "$pinned" \
   && [[ "$(grep -c 'unitask-9.8.7-.*echo a\{64\} ;;' "$pinned")" == 5 ]] && [[ "$after" != "$before" ]]; then
  pass "version, 5 checksums and plugin version bump written"
else fail "version, 5 checksums and plugin version bump written" "exit $code: $out"; fi
bash "$PIN/.github/scripts/pin-unitask.sh" 9.8.7 "$PIN/SUMS" >/dev/null 2>&1
[[ "$(grep -c 'unitask-9.8.7-' "$pinned")" == 5 ]] && pass "re-pinning replaces, not appends" || fail "re-pinning replaces, not appends"
head -2 "$PIN/SUMS" > "$PIN/SUMS2"
bash "$PIN/.github/scripts/pin-unitask.sh" 9.8.8 "$PIN/SUMS2" >/dev/null 2>&1 && fail "incomplete release refused" || pass "incomplete release refused"

echo "== user-path.sh (fake HOME)"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) pass "skipped on Windows (writes the user PATH in the registry)" ;;
  *)
    UH="$TMP/uhome"; mkdir -p "$UH/prog"; touch "$UH/.zshrc"
    printf '#!/bin/sh\n' > "$UH/prog/unitask"; chmod +x "$UH/prog/unitask"
    out="$(HOME="$UH" PATH=/usr/bin:/bin bash "$SCRIPTS/user-path.sh" "$UH/prog")"
    [[ "$(readlink "$UH/.local/bin/unitask")" == "$UH/prog/unitask" ]] && pass "symlink in ~/.local/bin" || fail "symlink in ~/.local/bin" "$out"
    grep -q 'mospolytech-lms: unitask' "$UH/.zshrc" && grep -q 'mospolytech-lms: unitask' "$UH/.profile" && pass "PATH block in rc files" || fail "PATH block in rc files" "$out"
    [[ "$out" == *path-added* ]] && pass "change reported" || fail "change reported" "$out"
    out="$(HOME="$UH" PATH=/usr/bin:/bin bash "$SCRIPTS/user-path.sh" "$UH/prog")"
    [[ -z "$out" && "$(grep -c 'mospolytech-lms: unitask' "$UH/.zshrc")" == 1 ]] && pass "idempotent" || fail "idempotent" "$out"
    rm "$UH/.local/bin/unitask"; printf 'mine\n' > "$UH/.local/bin/unitask"
    out="$(HOME="$UH" PATH="$UH/.local/bin:/usr/bin:/bin" bash "$SCRIPTS/user-path.sh" "$UH/prog")"
    [[ "$(cat "$UH/.local/bin/unitask")" == mine && "$out" == *path-skipped* ]] && pass "foreign file not replaced" || fail "foreign file not replaced" "$out"
    ;;
esac

echo "== setup.sh (no claude, no docker calls)"
out="$(HOME="$TMP/shome" PATH=/usr/bin:/bin CLAUDE_PLUGIN_DATA="$TMP/data" bash "$SCRIPTS/setup.sh" status 2>&1 </dev/null)"; code=$?
[[ $code == 0 && "$out" == *"moodle-mcp"* && "$out" == *"Telegram не подключён"* ]] && pass "status" || fail "status" "exit $code: $out"
out="$(HOME="$TMP/shome" PATH=/usr/bin:/bin bash "$SCRIPTS/setup.sh" bogus 2>&1 </dev/null)"; code=$?
[[ $code != 0 && "$out" == *"неизвестная команда"* ]] && pass "unknown command rejected" || fail "unknown command rejected" "$out"

echo "== typst-gost"
DOC="$TMP/doc"
mkdir -p "$DOC/assets"
printf '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"><rect width="20" height="10"/></svg>' > "$DOC/assets/s.svg"
cat > "$DOC/report.typ" <<'EOF'
#import "@local/mospolytech-gost:0.1.0": *
#show: gost
#make_title(course: "Курс", topic: "Тема", lab_number: 2, teachers: "Доцент - Иванов И.И.", student_group: "000-000", student_name: "Иванов И. И.")
#make_title(work_type: "Практическая работа", course: "Курс", topic: "Тема", student_group: "000-000", student_name: "Иванов И. И.", teachers: none)
= Раздел
Ссылка на @t[таблицу] и @f[рисунок].
#tbl([Таблица], table(columns: 2, table.header([A], [B]), [1], [2])) <t>
#img(path("assets/s.svg"), [Рисунок], width: 30%) <f>
$ x = y^2 $
EOF
if bash "$PLUGIN/bin/typst-gost" "$DOC/report.typ" "$DOC/report.pdf" 2>"$TMP/typst.err" && [[ -s "$DOC/report.pdf" ]]; then
  pass "report compiles"
else
  fail "report compiles" "$(cat "$TMP/typst.err")"
fi
printf '#import "@local/mospolytech-gost:0.1.0": *\n#img("assets/s.svg", [x])\n' > "$DOC/bad.typ"
if bash "$PLUGIN/bin/typst-gost" "$DOC/bad.typ" "$DOC/bad.pdf" 2>"$TMP/bad.err"; then
  fail "string path rejected"
else
  grep -q 'path(' "$TMP/bad.err" && pass "string path rejected" || fail "string path rejected" "$(cat "$TMP/bad.err")"
fi

echo "== pdf-pages"
PNG="$TMP/png"
if bash "$PLUGIN/bin/pdf-pages" "$DOC/report.pdf" "$PNG/all" >/dev/null 2>"$TMP/pp.err"; then
  n=$(ls "$PNG/all" | grep -c '^page-[0-9]*\.png$')
  ((n >= 3)) && pass "all pages rendered ($n)" || fail "all pages rendered" "only $n pages"
else
  fail "all pages rendered" "$(cat "$TMP/pp.err")"
fi
bash "$PLUGIN/bin/pdf-pages" "$DOC/report.pdf" "$PNG/one" 2 >/dev/null 2>&1 && [[ "$(ls "$PNG/one")" == page-2.png ]] \
  && pass "single page" || fail "single page" "$(ls "$PNG/one" 2>&1)"
bash "$PLUGIN/bin/pdf-pages" "$DOC/report.pdf" "$PNG/x" 999 >/dev/null 2>&1 && fail "missing page is an error" || pass "missing page is an error"
bash "$PLUGIN/bin/pdf-pages" "$TMP/nope.pdf" "$PNG/x" >/dev/null 2>&1 && fail "missing file is an error" || pass "missing file is an error"

# The PowerShell twins are what Claude's PowerShell tool runs on Windows.
if command -v powershell.exe >/dev/null && command -v cygpath >/dev/null; then
  echo "== PowerShell scripts"
  ps() { powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$1")" "${@:2}"; }
  if ps "$PLUGIN/bin/pdf-pages.ps1" "$(cygpath -w "$DOC/report.pdf")" "$(cygpath -w "$PNG/ps")" 1-2 >/dev/null 2>"$TMP/ps.err" \
     && [[ -f "$PNG/ps/page-1.png" && -f "$PNG/ps/page-2.png" ]]; then pass "pdf-pages.ps1"; else fail "pdf-pages.ps1" "$(cat "$TMP/ps.err")"; fi
  if ps "$PLUGIN/bin/typst-gost.ps1" "$(cygpath -w "$DOC/report.typ")" "$(cygpath -w "$DOC/report-ps.pdf")" >/dev/null 2>"$TMP/tg.err" \
     && [[ -s "$DOC/report-ps.pdf" ]]; then pass "typst-gost.ps1"; else fail "typst-gost.ps1" "$(cat "$TMP/tg.err")"; fi
fi

echo "== login (fake moodle-mcp and claude, no network)"
FAKE="$TMP/fake"
mkdir -p "$FAKE/data/bin" "$FAKE/path"
# Same stdout as `moodle-mcp auth --output json`: Moodle's token.php response.
cat > "$FAKE/data/bin/moodle-mcp" <<'EOF'
#!/usr/bin/env bash
[[ " $* " == *" --output json "* ]] || { echo "expected --output json, got: $*" >&2; exit 2; }
printf '{"token":"0123456789abcdef0123456789abcdef","privatetoken":"should-not-be-used"}\n'
EOF
# Records what login.sh tries to save; FAKE_CLAUDE_FAIL makes the save fail.
cat > "$FAKE/path/claude" <<EOF
#!/usr/bin/env bash
[[ -n "\${FAKE_CLAUDE_FAIL:-}" ]] && exit 1
cat > "$FAKE/saved.json"
EOF
chmod +x "$FAKE/data/bin/moodle-mcp" "$FAKE/path/claude"
out="$(PATH="$FAKE/path:$PATH" CLAUDE_PLUGIN_DATA="$FAKE/data" bash "$SCRIPTS/login.sh" https://lms.example 2>&1 </dev/null)"
if grep -q '"moodle_token":"0123456789abcdef0123456789abcdef"' "$FAKE/saved.json" 2>/dev/null \
   && grep -q '"moodle_url":"https://lms.example"' "$FAKE/saved.json"; then
  pass "token parsed and saved"
else
  fail "token parsed and saved" "$out | saved: $(cat "$FAKE/saved.json" 2>/dev/null)"
fi
out="$(PATH="$FAKE/path:$PATH" FAKE_CLAUDE_FAIL=1 CLAUDE_PLUGIN_DATA="$FAKE/data" bash "$SCRIPTS/login.sh" 2>&1 </dev/null)"
[[ "$out" == *0123456789abcdef0123456789abcdef* ]] && pass "token shown when saving fails" || fail "token shown when saving fails" "$out"

echo
if ((failures)); then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
