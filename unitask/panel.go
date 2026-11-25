package main

// Карточка предмета – блок, который выезжает сверху над полосой прогресса.
// Пока он открыт, клавиши идут в него (те же, что в карточке задачи).

import (
	"fmt"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type animMsg struct{}

func animTick() tea.Cmd {
	return tea.Tick(16*time.Millisecond, func(time.Time) tea.Msg { return animMsg{} })
}

const panelOpen = 1 << 30 // panelH, когда блок раскрыт полностью

func (m *model) openPanel(g *Group) tea.Cmd {
	if g == nil {
		return nil
	}
	if g.Owner == nil {
		m.setMsg("у этого списка нет своего объекта – редактировать нечего", true)
		return nil
	}
	cp := *g
	m.detail, m.detailGroup, m.dField = g.Owner, &cp, 0
	m.panel, m.panelClosing, m.panelH, m.panelTarget = true, false, 0, 0
	return animTick()
}

// closePanel закрывает блок; anim – плавно, иначе сразу.
func (m *model) closePanel(anim bool) tea.Cmd {
	if !m.panel {
		return nil
	}
	m.editing = false
	m.editor.Blur()
	if anim {
		m.panelClosing = true
		m.panelH = min(m.panelH, m.panelTarget)
		return animTick()
	}
	m.finishClose()
	return nil
}

func (m *model) finishClose() {
	m.panel, m.panelClosing, m.panelH = false, false, 0
	if m.detailGroup != nil && m.scr == scrBoard {
		m.detail, m.detailGroup = nil, nil
	}
}

func (m *model) stepPanel() tea.Cmd {
	if !m.panel {
		return nil
	}
	if m.panelTarget == 0 {
		return animTick() // высота станет известна после первой отрисовки
	}
	step := max(1, m.panelTarget/6)
	if m.panelClosing {
		m.panelH -= step
		if m.panelH <= 0 {
			m.finishClose()
			return nil
		}
		return animTick()
	}
	if m.panelH == panelOpen {
		return nil
	}
	m.panelH += step
	if m.panelH >= m.panelTarget {
		m.panelH = panelOpen
		return nil
	}
	return animTick()
}

// viewPanel рисует блок целиком и отдаёт столько нижних строк, сколько
// уже «выехало».
func (m *model) viewPanel(w, maxH int) string {
	g := m.groupNow()
	if g == nil || m.detail == nil {
		return ""
	}
	var counts []string
	total := 0
	for ci, name := range m.columns {
		c := len(m.cellTasks(g.List, ci))
		total += c
		counts = append(counts, lipgloss.NewStyle().Foreground(m.theme.statusColor(name)).Render(fmt.Sprintf("● %d", c)))
	}
	inner := w - 4
	head := m.st.bold.Render(g.Name) + m.st.dim.Render(fmt.Sprintf("  предмет · записей: %d  ", total)) +
		strings.Join(counts, " ")
	editBox := m.editBoxView(inner)
	avail := max(1, maxH-3-lipgloss.Height(editBox))
	if editBox == "" {
		avail = max(1, maxH-3)
	}
	body := []string{head}
	body = append(body, m.fieldLines(inner, avail, "", "")...)
	if editBox != "" {
		body = append(body, editBox)
	}
	full := lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(m.theme.Accent).
		Padding(0, 1).Width(w - 2).Render(strings.Join(body, "\n"))
	lines := strings.Split(full, "\n")
	m.panelTarget = len(lines)
	show := min(m.panelH, len(lines))
	if show <= 0 {
		return ""
	}
	return strings.Join(lines[len(lines)-show:], "\n")
}
