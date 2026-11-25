package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

func openCount(m *model) int {
	n := 0
	for _, t := range m.tasks {
		if !m.isClosed(m.statusOf(t.Node)) {
			n++
		}
	}
	return n
}

func TestNewSemesterWithDebts(t *testing.T) {
	sample := samplePath(t)
	m := newModel(defaultConfig(), filepath.Join(t.TempDir(), "c.json"), false, sample)
	m.Update(tea.WindowSizeMsg{Width: 120, Height: 36})
	total, open := len(m.tasks), openCount(m)
	cur := m.curSemester()
	if cur == "" {
		cur = guessSemester(time.Now())
	}
	next := nextSemester(cur)

	press(m, "c")
	if m.picker == nil || m.picker.addLabel == "" {
		t.Fatal("нет списка семестров с пунктом «новый семестр»")
	}
	press(m, "end", "enter")
	if m.curSemester() == "" { // сначала спрашивается имя текущего
		if m.prompt == nil || m.prompt.input.Value() != cur {
			t.Fatal("не спросили имя текущего семестра")
		}
		press(m, "enter")
	}
	if m.prompt == nil || m.prompt.input.Value() != next {
		t.Fatalf("ожидалось предложение %s", next)
	}
	press(m, "enter")
	if open > 0 {
		if m.picker == nil {
			t.Fatal("не спросили про незакрытые записи")
		}
		press(m, "enter") // перенести как долги
	}
	if m.curSemester() != next {
		t.Fatalf("текущий семестр %q", m.curSemester())
	}
	if len(m.tasks) != open {
		t.Fatalf("в новом семестре %d записей, долгов было %d", len(m.tasks), open)
	}
	for _, tk := range m.tasks {
		if !strings.Contains(tk.Node.Get("notes").Text(), "Долг "+cur) {
			t.Fatal("у долга нет пометки")
		}
	}
	t.Log("\n" + ansi.Strip(m.View()))

	// архив: те же записи, незакрытые стали cancelled
	press(m, "[")
	if m.viewSem != cur || len(m.tasks) != total || openCount(m) != 0 {
		t.Fatalf("архив: %q, записей %d, открытых %d", m.viewSem, len(m.tasks), openCount(m))
	}
	m.msg = ""
	if !strings.Contains(strings.SplitN(ansi.Strip(m.View()), "\n", 2)[0], "архив: "+semLabel(cur)) {
		t.Fatal("в шапке не видно, что открыт архив")
	}
	press(m, "]")
	if m.viewSem != "" {
		t.Fatal("не вернулись в текущий семестр")
	}

	data, _ := os.ReadFile(sample)
	root, err := Parse(data)
	if err != nil {
		t.Fatal(err)
	}
	if root.Get("semester").Text() != next || root.Get("archive").Get(cur) == nil {
		t.Fatal("в файле нет semester/archive")
	}

	// отмена возвращает всё как было
	press(m, "u")
	if len(m.tasks) != total || m.root.Get("archive") != nil && m.root.Get("archive").Get(cur) != nil {
		t.Fatal("отмена не вернула семестр")
	}
}

func TestEmptySemesterNewSubject(t *testing.T) {
	m := newModel(defaultConfig(), filepath.Join(t.TempDir(), "c.json"), false, samplePath(t))
	m.Update(tea.WindowSizeMsg{Width: 120, Height: 36})
	cur := m.curSemester()
	if cur == "" {
		cur = guessSemester(time.Now())
	}
	m.newSemester(cur, nextSemester(cur), false)
	if len(m.tasks) != 0 {
		t.Fatalf("новый семестр без долгов должен быть пустым, записей %d", len(m.tasks))
	}
	press(m, "n")
	if m.picker == nil || m.picker.addLabel == "" {
		t.Fatal("в пустом семестре нельзя создать предмет")
	}
	press(m, "end", "enter")
	typeText(m, "Новый курс")
	press(m, "enter")
	typeText(m, "Первая задача")
	press(m, "enter", "esc")
	if len(m.tasks) != 1 || m.tasks[0].Group != "Новый курс" {
		t.Fatalf("задача в новом предмете не создана: %+v", m.tasks)
	}
	// предмет создан в текущем семестре, а не в архиве
	press(m, "[")
	for _, tk := range m.tasks {
		if tk.Group == "Новый курс" {
			t.Fatal("новый предмет попал в архив")
		}
	}
}

func TestSubjectPanel(t *testing.T) {
	m := newModel(defaultConfig(), filepath.Join(t.TempDir(), "c.json"), false, samplePath(t))
	m.Update(tea.WindowSizeMsg{Width: 120, Height: 40})
	anim := func() {
		for i := 0; i < 30 && m.panel; i++ {
			m.View()
			m.Update(animMsg{})
		}
	}
	press(m, "e")
	if !m.panel || m.scr != scrBoard {
		t.Fatal("карточка предмета должна открываться блоком на доске")
	}
	anim()
	v := ansi.Strip(m.View())
	if !strings.Contains(v, "предмет · записей") || !strings.Contains(v, "выполнено") {
		t.Fatal("блок предмета и полоса прогресса должны быть видны вместе:\n" + v)
	}
	if strings.Index(v, "предмет · записей") > strings.Index(v, "выполнено") {
		t.Fatal("блок должен быть над полосой прогресса")
	}
	t.Log("\n" + v)
	// правка поля в блоке
	m.focusField(nameKey(m.detail))
	press(m, "enter")
	m.editor.SetValue("Переименованный")
	press(m, "enter")
	if !strings.Contains(ansi.Strip(m.View()), "Переименованный") {
		t.Fatal("название не изменилось")
	}
	press(m, "e")
	anim()
	if m.panel || m.detail != nil {
		t.Fatal("блок не закрылся")
	}
}
