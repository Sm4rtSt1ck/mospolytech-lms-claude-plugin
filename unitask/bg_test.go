package main

import (
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"
)

// В выводе не должно быть ни одной SGR-последовательности фона.
func TestNoBackground(t *testing.T) {
	sample := samplePath(t)
	lipgloss.SetColorProfile(termenv.TrueColor)
	bg := regexp.MustCompile(`\x1b\[[0-9;]*(?:^|;)(?:4[0-9]|10[0-7])(?:;|m)|48;[25];`)
	for _, theme := range []string{"dark", "light"} {
		cfg := defaultConfig()
		cfg.Theme = theme
		m := newModel(cfg, filepath.Join(t.TempDir(), "c.json"), false, sample)
		m.Update(tea.WindowSizeMsg{Width: 120, Height: 40})
		screens := []string{m.View()}
		press(m, "enter")
		screens = append(screens, m.View())
		press(m, "e")
		screens = append(screens, m.View())
		press(m, "esc", "esc", "g")
		screens = append(screens, m.View())
		for i, scr := range screens {
			// заливка разрешена только в полосе прогресса
			var lines []string
			for _, l := range strings.Split(scr, "\n") {
				if !strings.Contains(l, "выполнено") {
					lines = append(lines, l)
				}
			}
			s := strings.Join(lines, "\n")
			if loc := bg.FindStringIndex(s); loc != nil {
				t.Fatalf("%s, экран %d: фон в %q", theme, i, s[loc[0]:min(len(s), loc[1]+10)])
			}
		}
	}
}
