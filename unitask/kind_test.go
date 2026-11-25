package main

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

func TestTaskEventFilter(t *testing.T) {
	m := newModel(defaultConfig(), filepath.Join(t.TempDir(), "c.json"), false, samplePath(t))
	m.Update(tea.WindowSizeMsg{Width: 120, Height: 36})
	ev := m.tasks[0].Node
	m.mutate(func() { ev.Set("kind", NewString("event")) })
	total, events := len(m.tasks), 0
	for _, tk := range m.tasks {
		if m.isEvent(tk.Node) {
			events++
		}
	}

	count := func() int {
		n := 0
		for ci := range m.columns {
			n += len(m.colTasks(ci))
		}
		return n
	}
	if count() != total {
		t.Fatal("по умолчанию должны быть видны все записи")
	}
	press(m, "t")
	if m.cfg.RecordFilter != "tasks" || count() != total-events {
		t.Fatalf("фильтр «задачи»: %s %d", m.cfg.RecordFilter, count())
	}
	press(m, "t")
	if m.cfg.RecordFilter != "events" || count() != events {
		t.Fatalf("фильтр «события»: %s %d", m.cfg.RecordFilter, count())
	}
	v := ansi.Strip(m.View())
	if !strings.Contains(v, "◆ событие") || !strings.Contains(v, "только события") || !strings.Contains(v, fmt.Sprintf(" из %d)", events)) {
		t.Fatal("\n" + v)
	}
	// новая запись при фильтре «события» – сразу событие
	press(m, "n")
	if m.picker != nil {
		press(m, "enter")
	}
	if !m.isEvent(m.detail) {
		t.Fatal("новая запись при фильтре «события» должна быть событием")
	}
	press(m, "esc", "esc", "t")
	if m.cfg.RecordFilter != "all" {
		t.Fatal("фильтр не вернулся к «все»")
	}
}
