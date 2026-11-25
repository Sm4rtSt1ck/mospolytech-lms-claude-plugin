package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

func typeText(m *model, s string) {
	for _, r := range s {
		m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}
}

func TestSubjects(t *testing.T) {
	sample := samplePath(t)
	m := newModel(defaultConfig(), filepath.Join(t.TempDir(), "c.json"), false, sample)
	m.Update(tea.WindowSizeMsg{Width: 120, Height: 36})
	t.Log("\n" + ansi.Strip(m.View()))
	if os.Getenv("UNITASK_SAMPLE") == "" && !strings.Contains(ansi.Strip(m.View()), "выполнено 25% (1 из 4)") {
		t.Fatal("общая полоса прогресса неверна")
	}

	// v → выбор предмета, F2 – переименование прямо в списке
	press(m, "v")
	if m.picker == nil {
		t.Fatal("выбор предмета не открылся")
	}
	press(m, "down", "f2")
	if m.prompt == nil {
		t.Fatal("F2 не открыл переименование")
	}
	m.prompt.input.SetValue("Веб-сайт")
	press(m, "enter")
	if m.picker == nil || m.picker.items[1] != "Веб-сайт" {
		t.Fatal("после переименования должен вернуться список с новым именем")
	}
	press(m, "enter")
	if m.groupFilter != "Веб-сайт" {
		t.Fatalf("предмет не выбран: %q", m.groupFilter)
	}
	t.Log("\n" + ansi.Strip(m.View()))

	// переназначение задачи на новый предмет
	task := m.current().Node
	press(m, "enter", "p")
	if m.picker == nil || m.picker.addLabel == "" {
		t.Fatal("нет списка предметов с пунктом «новый предмет»")
	}
	t.Log("\n" + ansi.Strip(m.View()))
	press(m, "end", "enter")
	typeText(m, "Новый предмет")
	press(m, "enter")
	if tk := m.taskOf(task); tk == nil || tk.Group != "Новый предмет" {
		t.Fatal("задача не перенесена в новый предмет")
	}

	// статус – выбор из списка
	m.focusField("status")
	press(m, "enter")
	if m.picker == nil || len(m.picker.items) < 4 {
		t.Fatal("статус должен выбираться из списка")
	}
	press(m, "end", "enter")
	if m.statusOf(task) == "to-do" {
		t.Fatal("статус не изменился")
	}

	// тип – список с базовыми типами и добавлением нового
	press(m, "a")
	typeText(m, "type")
	press(m, "enter")
	if m.picker == nil || m.picker.items[0] != "лабораторная" {
		t.Fatalf("список типов: %+v", m.picker)
	}
	press(m, "end", "enter")
	typeText(m, "seminar")
	press(m, "enter")
	if task.Get("type").Text() != "seminar" {
		t.Fatal("новый тип не записан")
	}
	t.Log("\n" + ansi.Strip(m.View()))

	data, _ := os.ReadFile(sample)
	for _, want := range []string{`"Новый предмет"`, `"Веб-сайт"`, `"type": "seminar"`} {
		if !strings.Contains(string(data), want) {
			t.Fatalf("в файле нет %s", want)
		}
	}

	// новая задача в открытом предмете
	press(m, "esc", "n")
	if m.scr != scrDetail || !m.editing {
		t.Fatal("новая задача не открылась на редактирование заголовка")
	}
	typeText(m, "Свежая задача")
	press(m, "enter", "esc")
	if !strings.Contains(ansi.Strip(m.View()), "Свежая задача") {
		t.Fatal("новая задача не видна на доске")
	}
	t.Log("\n" + ansi.Strip(m.View()))
}
