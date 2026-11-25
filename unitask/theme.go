package main

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// Цвета задаются только для текста и рамок – фон всегда остаётся
// терминальным.

type role int

const (
	roleNone role = iota
	roleTodo
	roleProgress
	roleDone
	roleCancel
)

func statusRole(s string) role {
	l := strings.ToLower(s)
	has := func(subs ...string) bool {
		for _, x := range subs {
			if strings.Contains(l, x) {
				return true
			}
		}
		return false
	}
	switch {
	case has("cancel", "отмен", "reject", "drop", "wontfix"):
		return roleCancel
	case has("done", "готов", "сдан", "выполн", "complete", "closed", "finish"):
		return roleDone
	case has("progress", "doing", "wip", "review", "работ", "процесс"):
		return roleProgress
	case has("todo", "to-do", "to do", "new", "open", "backlog", "план", "сделать"):
		return roleTodo
	}
	return roleNone
}

type Theme struct {
	Name                         string
	Todo, Progress, Done, Cancel lipgloss.Color
	Dim, Accent, Info            lipgloss.Color
	BarText                      lipgloss.Color // текст на цветных блоках полосы прогресса
}

var darkTheme = Theme{
	Name: "dark",
	Todo: "#5fafff", Progress: "#ffaf00", Done: "#5fd75f", Cancel: "#ff5f5f",
	Dim: "#7c7c7c", Accent: "#d787ff", Info: "#5fd7d7", BarText: "#000000",
}

var lightTheme = Theme{
	Name: "light",
	Todo: "#005fd7", Progress: "#d75f00", Done: "#008700", Cancel: "#d70000",
	Dim: "#8a8a8a", Accent: "#8700af", Info: "#00878f", BarText: "#ffffff",
}

func themeByName(name string) Theme {
	if name == "light" {
		return lightTheme
	}
	return darkTheme
}

func (t Theme) roleColor(r role) lipgloss.TerminalColor {
	switch r {
	case roleTodo:
		return t.Todo
	case roleProgress:
		return t.Progress
	case roleDone:
		return t.Done
	case roleCancel:
		return t.Cancel
	}
	return lipgloss.NoColor{}
}

func (t Theme) statusColor(s string) lipgloss.TerminalColor {
	return t.roleColor(statusRole(s))
}

type styles struct {
	dim, bold, accent, info, err, ok lipgloss.Style
}

func makeStyles(t Theme) styles {
	s := lipgloss.NewStyle()
	return styles{
		dim:    s.Foreground(t.Dim),
		bold:   s.Bold(true),
		accent: s.Foreground(t.Accent),
		info:   s.Foreground(t.Info),
		err:    s.Foreground(t.Cancel).Bold(true),
		ok:     s.Foreground(t.Done),
	}
}
