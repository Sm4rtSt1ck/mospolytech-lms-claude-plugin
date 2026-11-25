package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// снимок записей: группа|id|статус|notes – чтобы сравнить «до» и «после»
func snapshot(m *model) map[string]string {
	out := map[string]string{}
	for _, t := range m.tasks {
		k := t.Group + "|" + t.Node.Get("id").Text() + "|" + m.titleOf(t.Node)
		out[k] = m.statusOf(t.Node) + "|" + t.Node.Get("notes").Text()
	}
	return out
}

func newTestModel(t *testing.T) (*model, string) {
	path := samplePath(t)
	m := newModel(defaultConfig(), filepath.Join(t.TempDir(), "c.json"), false, path)
	m.Update(tea.WindowSizeMsg{Width: 120, Height: 36})
	return m, path
}

func curOrGuess(m *model) string {
	if c := m.curSemester(); c != "" {
		return c
	}
	return guessSemester(time.Now())
}

func TestDeleteCurrentSemesterRestoresDebts(t *testing.T) {
	m, _ := newTestModel(t)
	before := snapshot(m)
	cur := curOrGuess(m)
	next := nextSemester(cur)
	m.newSemester(cur, next, true)

	// в новом семестре: один долг закрыли, добавили новую запись
	debt := m.tasks[0].Node
	m.moveTask(debt, "done")
	press(m, "n")
	if m.picker != nil {
		press(m, "enter")
	}
	typeText(m, "Новая запись")
	press(m, "enter", "esc")

	// удаление текущего через список семестров
	press(m, "c")
	press(m, "d")
	if m.picker == nil || len(m.picker.items) != 2 {
		t.Fatal("не спросили, что делать с новыми записями")
	}
	press(m, "enter") // перенести в восстановленный семестр
	if m.curSemester() != cur || len(m.archivedSemesters()) != 0 {
		t.Fatalf("семестр не восстановлен: %q, архив %v", m.curSemester(), m.archivedSemesters())
	}
	after := snapshot(m)
	found := false
	for k, v := range after {
		if strings.Contains(k, "Новая запись") {
			found = true
			continue
		}
		b, ok := before[k]
		if !ok {
			t.Fatalf("лишняя запись %s", k)
		}
		if strings.Contains(v, "Перенесено") || strings.Contains(v, "Долг") {
			t.Fatalf("остались пометки о переносе: %s → %s", k, v)
		}
		if k == m.tasks[0].Group+"|"+debt.Get("id").Text()+"|"+m.titleOf(debt) {
			continue
		}
		if v != b && !strings.HasPrefix(v, "done|") {
			t.Fatalf("запись %s: было %q, стало %q", k, b, v)
		}
	}
	if !found || len(after) != len(before)+1 {
		t.Fatalf("записей было %d, стало %d (новая найдена: %v)", len(before), len(after), found)
	}
	if m.statusOf(debt) != "done" {
		t.Fatal("закрытый в новом семестре долг должен вернуться со статусом done")
	}
}

func TestDeleteCurrentDropExtra(t *testing.T) {
	m, _ := newTestModel(t)
	before := len(m.tasks)
	cur := curOrGuess(m)
	m.newSemester(cur, nextSemester(cur), false)
	press(m, "n")
	if m.picker != nil {
		press(m, "end", "enter")
		typeText(m, "Временный")
		press(m, "enter")
	}
	typeText(m, "Удалить меня")
	press(m, "enter", "esc")
	m.deleteSemesterPrompt("")
	press(m, "down", "enter") // удалить вместе с семестром
	if len(m.tasks) != before {
		t.Fatalf("записей %d, ожидалось %d", len(m.tasks), before)
	}
}

func TestDeleteArchivedAndOnlySemester(t *testing.T) {
	m, path := newTestModel(t)
	cur := curOrGuess(m)
	m.newSemester(cur, nextSemester(cur), false)
	press(m, "c", "down", "d") // архивный – второй в списке
	if m.confirm == nil {
		t.Fatal("нет подтверждения удаления")
	}
	press(m, "y")
	if len(m.archivedSemesters()) != 0 || m.root.Get(archiveKey) != nil {
		t.Fatal("архивный семестр не удалён")
	}
	data, _ := os.ReadFile(path)
	if strings.Contains(string(data), `"archive"`) {
		t.Fatal("в файле остался пустой archive")
	}
	m.deleteSemesterPrompt("")
	if m.confirm != nil || m.picker != nil || !m.msgErr {
		t.Fatal("единственный семестр удалять нельзя")
	}
	press(m, "u")
	if len(m.archivedSemesters()) != 1 {
		t.Fatal("u не вернул удалённый семестр")
	}
}

func TestAutoReload(t *testing.T) {
	m, path := newTestModel(t)
	n := len(m.tasks)
	rewrite := func() {
		data, _ := os.ReadFile(path)
		s := strings.Replace(string(data), `"status": "to-do"`, `"status": "done"`, 1)
		future := time.Now().Add(time.Duration(n+1) * time.Second)
		os.WriteFile(path, []byte(s), 0o644)
		os.Chtimes(path, future, future)
		n++
	}
	todo := func() int { return len(m.colTasks(0)) }
	start := todo()

	// пока открыт редактор – не перечитываем
	press(m, "enter", "e")
	rewrite()
	m.Update(tickMsg(time.Now()))
	if todo() != start {
		t.Fatal("перечитал файл при открытом редакторе")
	}
	press(m, "esc", "esc")
	m.Update(tickMsg(time.Now()))
	if todo() != start-1 {
		t.Fatalf("не перечитал файл после закрытия редактора: to-do %d", todo())
	}
	if tickInterval != 5*time.Second {
		t.Fatal("интервал проверки должен быть 5 секунд")
	}
}

func TestNoteRoundTrip(t *testing.T) {
	for _, orig := range []string{"", "текст", "текст.", "текст!", "текст;", "текст; ", "  ", "(скобки)", "многоточие…",
		"текст. Долг 2026-autumn. внутри"} {
		n := &Node{Kind: KObject}
		n.Set("notes", NewString(orig))
		appendNote(n, debtNote("2026-autumn"))
		appendNote(n, movedNote("2027-spring"))
		removeNote(n, movedNote("2027-spring"))
		removeNote(n, debtNote("2026-autumn"))
		if got := n.Get("notes").Str; got != orig {
			t.Errorf("%q → %q", orig, got)
		}
	}
}
