package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

func press(m *model, keys ...string) {
	for _, k := range keys {
		var msg tea.KeyMsg
		switch k {
		case "enter":
			msg = tea.KeyMsg{Type: tea.KeyEnter}
		case "esc":
			msg = tea.KeyMsg{Type: tea.KeyEsc}
		case "down":
			msg = tea.KeyMsg{Type: tea.KeyDown}
		case "up":
			msg = tea.KeyMsg{Type: tea.KeyUp}
		case "end":
			msg = tea.KeyMsg{Type: tea.KeyEnd}
		case "f2":
			msg = tea.KeyMsg{Type: tea.KeyF2}
		case "right":
			msg = tea.KeyMsg{Type: tea.KeyRight}
		case "shift+right":
			msg = tea.KeyMsg{Type: tea.KeyShiftRight}
		default:
			msg = tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(k)}
		}
		m.Update(msg)
	}
}

func TestUIFlow(t *testing.T) {
	sample := samplePath(t)
	cfgPath := filepath.Join(t.TempDir(), "cfg.json")
	m := newModel(defaultConfig(), cfgPath, true, sample)
	m.Update(tea.WindowSizeMsg{Width: 140, Height: 40})
	t.Log("\n" + ansi.Strip(m.View()))
	press(m, "down", "enter")
	if m.cfg.Theme != "light" || m.scr != scrBoard {
		t.Fatalf("тема/экран: %s %d", m.cfg.Theme, m.scr)
	}
	t.Log("\n" + ansi.Strip(m.View()))
	// перенос первой задачи to-do в in-progress
	first := m.current().Node
	press(m, "shift+right")
	if m.statusOf(first) != "in-progress" {
		t.Fatal("перенос не сработал")
	}
	title := m.titleOf(first)
	press(m, "u")
	if c := m.current(); c == nil || m.titleOf(c.Node) != title || m.col != 0 {
		t.Fatal("отмена не сработала")
	}
	first = m.current().Node
	press(m, "о") // русская «о» = j: вниз
	press(m, "л") // «л» = k: вверх
	press(m, "enter")
	t.Log("\n" + ansi.Strip(m.View()))
	press(m, "a")
	for _, r := range "priority" {
		press(m, string(r))
	}
	press(m, "enter")
	for _, r := range "5" {
		press(m, string(r))
	}
	press(m, "enter")
	if v := first.Get("priority"); v == nil || v.Kind != KNumber {
		t.Fatalf("новое поле: %+v", v)
	}
	t.Log("\n" + ansi.Strip(m.View()))
	data, _ := os.ReadFile(sample)
	if !strings.Contains(string(data), `"priority": 5`) {
		t.Fatal("не сохранилось в файл")
	}
	press(m, "esc", "s")
	t.Log("\n" + ansi.Strip(m.View()))
}
