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
for f in "$SCRIPTS"/*.sh "$PLUGIN/bin/typst-gost" "$REPO/tests/run.sh"; do
  if bash -n "$f"; then pass "bash -n ${f#"$REPO"/}"; else fail "bash -n ${f#"$REPO"/}"; fi
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

echo
if ((failures)); then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
