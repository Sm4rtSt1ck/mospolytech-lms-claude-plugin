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
for f in "$SCRIPTS"/*.sh "$PLUGIN/bin/typst-gost" "$PLUGIN/bin/pdf-pages" "$REPO/tests/run.sh"; do
  if bash -n "$f"; then pass "bash -n ${f#"$REPO"/}"; else fail "bash -n ${f#"$REPO"/}"; fi
done

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
CLAUDE_PLUGIN_OPTION_SUBMIT_CONFIRMATION=off expect "confirmation off" allow guard-submit.sh '{"tool_input":{"assignment_id":1,"text":"x"}}'

echo "== session-start (downloads moodle-mcp and Typst, verifies checksums)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$TMP/data"
WS2="$TMP/ws2"
out="$(echo '{}' | CLAUDE_PLUGIN_OPTION_WORKSPACE_DIR="$WS2" CLAUDE_PLUGIN_OPTION_MOODLE_TOKEN= bash "$SCRIPTS/session-start.sh")"
case "$out" in
  '{'*'"hookEventName":"SessionStart"'*'}') pass "valid hook output" ;;
  *) fail "valid hook output" "$out" ;;
esac
[[ "$out" == *"нет токена LMS"* ]] && pass "missing token reported" || fail "missing token reported" "$out"
[[ "$out" == *"не удалось скачать"* ]] && fail "binaries installed" "$out" || pass "binaries installed"
for tool in moodle-mcp typst; do
  if [[ -x "$TMP/data/bin/$tool" || -x "$TMP/data/bin/$tool.exe" ]]; then pass "$tool present"; else fail "$tool present"; fi
done
[[ -f "$WS2/profile.yaml" && -f "$WS2/cache/index.md" && -d "$WS2/documents" ]] && pass "workspace created" || fail "workspace created"
[[ -s "$TMP/data/ca-bundle.pem" ]] && pass "ca bundle" || fail "ca bundle"
out="$(echo '{}' | CLAUDE_PLUGIN_OPTION_WORKSPACE_DIR= bash "$SCRIPTS/session-start.sh")"
[[ "$out" == *"не задана рабочая папка"* ]] && pass "missing workspace reported" || fail "missing workspace reported" "$out"

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
