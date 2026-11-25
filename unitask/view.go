package main

import (
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

func (m *model) View() string {
	if m.w == 0 {
		return ""
	}
	if m.w < 40 || m.h < 10 {
		return "Окно слишком маленькое"
	}
	switch m.scr {
	case scrTheme:
		return m.viewTheme()
	case scrPath:
		return m.viewPath()
	case scrDetail:
		return m.frame(m.viewDetail)
	case scrSettings:
		return m.frame(m.viewSettings)
	}
	return m.frame(m.viewBoard)
}

// frame собирает экран: заголовок, тело заданной высоты и подвал с
// сообщением и подсказками.
func (m *model) frame(body func(w, h int) string) string {
	footer := m.footer()
	bh := m.h - 1 - lipgloss.Height(footer)
	var b string
	if m.picker != nil {
		b = lipgloss.Place(m.w, bh, lipgloss.Center, lipgloss.Center, m.viewPicker())
	} else {
		b = body(m.w, bh)
	}
	b = lipgloss.NewStyle().Height(bh).MaxHeight(bh).Render(b)
	return m.header() + "\n" + b + "\n" + footer
}

func (m *model) header() string {
	h := lipgloss.NewStyle().Foreground(m.theme.Accent).Bold(true).Render("unitask")
	if m.filePath != "" {
		h += m.st.dim.Render(" · " + m.filePath)
	}
	if m.root != nil {
		if m.viewSem != "" {
			h += m.st.err.Render(" · архив: " + semLabel(m.viewSem))
		} else if cur := m.curSemester(); cur != "" {
			h += m.st.info.Render(" · " + semLabel(cur))
		}
		h += m.st.dim.Render(fmt.Sprintf(" · задач: %d", len(m.tasks)))
	}
	if m.groupFilter != "" {
		h += m.st.info.Render(" · предмет: " + m.groupFilter)
	}
	if m.cfg.RecordFilter != "all" {
		h += m.st.accent.Render(" · " + recordFilterLabel(m.cfg.RecordFilter))
	}
	if m.conflict {
		h += m.st.err.Render(" · не сохранено")
	}
	return ansi.Truncate(h, m.w, "…")
}

func (m *model) footer() string {
	var line string
	switch {
	case m.confirm != nil:
		line = m.st.err.Render(m.confirm.text) + m.st.dim.Render("  y – да, любая другая клавиша – нет")
	case m.prompt != nil:
		line = m.st.bold.Render(m.prompt.title) + " " + m.prompt.input.View()
	case m.filtering:
		line = m.filterInput.View()
	case m.msg != "":
		if m.msgErr {
			line = m.st.err.Render(m.msg)
		} else {
			line = m.st.ok.Render(m.msg)
		}
	case m.scr == scrBoard && m.filterInput.Value() != "":
		line = m.st.info.Render("поиск: " + m.filterInput.Value())
	}
	help := m.helpText()
	return ansi.Truncate(line, m.w, "…") + "\n" + m.st.dim.Width(m.w).Render(help)
}

func (m *model) helpText() string {
	switch {
	case m.picker != nil && m.picker.help != "":
		return m.picker.help
	case m.picker != nil:
		return "↑↓ выбор · enter выбрать · esc отмена"
	case m.scr == scrDetail && m.editing:
		return "enter сохранить · alt+enter / ctrl+j новая строка · esc отмена"
	case m.panel && m.editing:
		return "enter сохранить · alt+enter / ctrl+j новая строка · esc отмена"
	case m.panel:
		return "карточка предмета: ↑↓ поле · enter изменить · a добавить поле · d удалить поле · F2 переименовать · u отменить · e / esc закрыть"
	case m.scr == scrDetail:
		return "↑↓ поле · enter изменить · p другой предмет · a добавить поле · d удалить поле · ⇧←/⇧→ статус · F2 переименовать предмет · D удалить задачу · u отменить · esc назад"
	case m.scr == scrSettings && m.setEditing:
		return "enter сохранить · esc отмена"
	case m.scr == scrSettings:
		return "↑↓ выбор · enter изменить · esc назад"
	case m.root == nil:
		return "r перечитать · s настройки · q выход"
	}
	return "n новая задача · v предмет · c семестр ([ ] соседний) · e карточка предмета · t задачи/события/все · F2 переименовать предмет · ←↑↓→ выбор · ⇧←/⇧→ или </> перенести · 1-9 в колонку · enter открыть · D удалить · / поиск · o сортировка · u отменить · r перечитать · s настройки · q выход"
}

// ---------- первый запуск ----------

func (m *model) palettePreview(t Theme) string {
	var parts []string
	for _, s := range []string{"to-do", "in-progress", "done", "cancelled"} {
		parts = append(parts, lipgloss.NewStyle().Foreground(t.statusColor(s)).Render("● "+s))
	}
	return strings.Join(parts, "  ")
}

func (m *model) viewTheme() string {
	var b strings.Builder
	b.WriteString("\n  " + m.st.bold.Render("Добро пожаловать в unitask") + "\n\n")
	b.WriteString("  Выберите тему (потом её можно поменять в настройках):\n\n")
	for i, t := range []Theme{darkTheme, lightTheme} {
		label := []string{"Тёмная ", "Светлая"}[i]
		mark := "  "
		if i == m.themeSel {
			mark = lipgloss.NewStyle().Foreground(t.Accent).Render("▸ ")
			label = m.st.bold.Render(label)
		}
		b.WriteString("  " + mark + label + "   " + m.palettePreview(t) + "\n")
	}
	b.WriteString("\n  " + m.st.dim.Render("↑↓ выбор · enter подтвердить · q выход"))
	return b.String()
}

func (m *model) viewPath() string {
	var b strings.Builder
	b.WriteString("\n  " + m.st.bold.Render("Укажите путь к JSON-файлу с задачами") + "\n\n")
	b.WriteString("  " + m.pathInput.View() + "\n")
	if m.pathErr != "" {
		b.WriteString("  " + m.st.err.Render(m.pathErr) + "\n")
	}
	b.WriteString("\n  " + m.st.dim.Render("enter подтвердить · esc выход · путь можно поменять в настройках"))
	return b.String()
}

// ---------- доска ----------

func (m *model) viewBoard(w, h int) string {
	if m.root == nil {
		msg := "Файл не задан"
		if m.loadErr != "" {
			msg = "Не удалось открыть файл: " + m.loadErr
		}
		return "\n  " + m.st.err.Render(msg)
	}
	top := ""
	if m.panel {
		if p := m.viewPanel(w, h*45/100); p != "" {
			top = p + "\n"
		}
	}
	if top != "" {
		h -= lipgloss.Height(top) - 1 // top заканчивается переводом строки
	}
	bar := m.progressBar(w)
	from, vis, colW := m.visibleCols(w, 26)
	var cols []string
	for ci := from; ci < from+vis; ci++ {
		if len(cols) > 0 {
			cols = append(cols, " ")
		}
		cols = append(cols, m.renderColumn(ci, colW, h-2))
	}
	return top + bar + "\n\n" + lipgloss.JoinHorizontal(lipgloss.Top, cols...)
}

func colLabel(name string) string {
	if name == "" {
		return "(без статуса)"
	}
	return strings.ToUpper(name)
}

func (m *model) renderColumn(ci, w, h int) string {
	name := m.columns[ci]
	color := m.theme.statusColor(name)
	active := ci == m.col
	tasks := m.colTasks(ci)

	hs := lipgloss.NewStyle().Foreground(color).Bold(true)
	hdr := hs.Render(colLabel(name)) + m.st.dim.Render(fmt.Sprintf(" %d", len(tasks)))
	if ci < 9 {
		hdr = m.st.dim.Render(fmt.Sprintf("%d ", ci+1)) + hdr
	}
	rule := m.st.dim.Render(strings.Repeat("─", w))
	if active {
		rule = lipgloss.NewStyle().Foreground(color).Render(strings.Repeat("━", w))
	}
	lines := []string{ansi.Truncate(hdr, w, "…"), rule}
	avail := h - 2

	if len(tasks) == 0 {
		lines = append(lines, m.st.dim.Render(" пусто"))
		return strings.Join(lines, "\n")
	}

	sel := m.sel[name]
	cards := make([]string, len(tasks))
	heights := make([]int, len(tasks))
	for i, t := range tasks {
		cards[i] = m.renderCard(t, w, active && i == sel)
		heights[i] = lipgloss.Height(cards[i])
	}

	top := min(m.top[name], sel)
	fits := func(top int) bool {
		room := avail
		if top > 0 {
			room--
		}
		if sel < len(tasks)-1 {
			room--
		}
		sum := 0
		for i := top; i <= sel; i++ {
			sum += heights[i]
		}
		return sum <= room
	}
	for top < sel && !fits(top) {
		top++
	}
	m.top[name] = top

	if top > 0 {
		lines = append(lines, m.st.dim.Render(fmt.Sprintf(" ↑ ещё %d", top)))
		avail--
	}
	used, i := 0, top
	for ; i < len(tasks); i++ {
		limit := avail
		if i < len(tasks)-1 {
			limit--
		}
		if used+heights[i] > limit && i > top {
			break
		}
		lines = append(lines, cards[i])
		used += heights[i]
	}
	if i < len(tasks) {
		lines = append(lines, m.st.dim.Render(fmt.Sprintf(" ↓ ещё %d", len(tasks)-i)))
	}
	return lipgloss.NewStyle().MaxHeight(h).Render(strings.Join(lines, "\n"))
}

func (m *model) isClosed(status string) bool {
	r := statusRole(status)
	return r == roleDone || r == roleCancel || status == m.cfg.DoneStatus
}

func (m *model) renderCard(t Task, w int, selected bool) string {
	inner := w - 4
	status := m.statusOf(t.Node)
	color := m.theme.statusColor(status)

	ts := lipgloss.NewStyle()
	if selected {
		ts = ts.Bold(true)
	}
	if statusRole(status) == roleCancel {
		ts = ts.Strikethrough(true).Foreground(m.theme.Dim)
	}
	wrapped := strings.Split(lipgloss.NewStyle().Width(inner).Render(m.titleOf(t.Node)), "\n")
	if len(wrapped) > 3 {
		wrapped = wrapped[:3]
		wrapped[2] = ansi.Truncate(strings.TrimRight(wrapped[2], " "), inner-1, "") + "…"
	}
	for i := range wrapped {
		wrapped[i] = ts.Render(strings.TrimRight(wrapped[i], " "))
	}
	lines := wrapped
	lines = append(lines, ansi.Truncate(m.st.dim.Render(t.Group), inner, "…"))

	var meta []string
	if m.isEvent(t.Node) {
		meta = append(meta, m.st.accent.Render("◆ событие"))
	}
	if k, v := firstField(t.Node, deadlineKeys); v != nil {
		_ = k
		meta = append(meta, m.fmtDeadline(v.Text(), status, true))
	}
	if k, v := firstField(t.Node, []string{m.cfg.TypeField, "category"}); v != nil && v.Text() != "" {
		label := v.Text()
		if k == m.cfg.TypeField {
			label = typeLabel(label)
		}
		meta = append(meta, m.st.info.Render(label))
	}
	if len(meta) > 0 {
		lines = append(lines, ansi.Truncate(strings.Join(meta, m.st.dim.Render(" · ")), inner, "…"))
	}

	border, bc := lipgloss.RoundedBorder(), lipgloss.TerminalColor(m.theme.Dim)
	if selected {
		border, bc = lipgloss.ThickBorder(), color
		if _, ok := color.(lipgloss.NoColor); ok {
			bc = m.theme.Accent
		}
	}
	return lipgloss.NewStyle().Border(border).BorderForeground(bc).Padding(0, 1).Width(w - 2).
		Render(strings.Join(lines, "\n"))
}

func (m *model) fmtDeadline(v, status string, short bool) string {
	d, err := time.ParseInLocation("2006-01-02", v, time.Local)
	if err != nil {
		return v
	}
	if m.isClosed(status) {
		return m.st.dim.Render("⏱ " + v)
	}
	t0, _ := time.ParseInLocation("2006-01-02", today(), time.Local)
	days := int(d.Sub(t0).Hours() / 24)
	switch {
	case days < 0:
		s := "⚠ " + v
		if !short {
			s += fmt.Sprintf(" (просрочено на %d дн.)", -days)
		}
		return m.st.err.Render(s)
	case days == 0:
		return lipgloss.NewStyle().Foreground(m.theme.Progress).Bold(true).Render("⏱ " + v + " сегодня")
	case days <= 3:
		return lipgloss.NewStyle().Foreground(m.theme.Progress).Render(fmt.Sprintf("⏱ %s (через %d дн.)", v, days))
	}
	if short {
		return "⏱ " + v
	}
	return fmt.Sprintf("⏱ %s (через %d дн.)", v, days)
}

// ---------- карточка задачи ----------

var dateRe = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}`)

func inKeys(k string, keys []string) bool {
	k = strings.ToLower(k)
	for _, x := range keys {
		if k == x {
			return true
		}
	}
	return false
}

// fmtField форматирует известные поля; неизвестные выводятся как есть.
func (m *model) fmtField(k string, v *Node, status string, width int) string {
	plain := lipgloss.NewStyle().Width(width)
	lk := strings.ToLower(k)
	isDateKey := strings.HasSuffix(lk, "_at") || strings.HasSuffix(lk, "date") || lk == "created" ||
		lk == "updated" || k == m.cfg.DoneDateField
	if k == m.cfg.KindField && v.Kind == KString {
		if v.Str == m.cfg.EventValue {
			return m.st.accent.Bold(true).Render("◆ событие")
		}
		if v.Str == "task" {
			return "задача"
		}
	}
	known := k == m.cfg.StatusField || k == m.cfg.TitleField || inKeys(k, titleKeys) || inKeys(k, deadlineKeys) ||
		inKeys(k, typeKeys) || inKeys(k, idKeys) || inKeys(k, noteKeys) || isDateKey

	if !known {
		if v.Kind == KArray || v.Kind == KObject {
			return plain.Render(v.Pretty())
		}
		if v.Kind == KNull {
			return "null"
		}
		return plain.Render(v.Text())
	}
	if v.Kind == KNull || v.Text() == "" {
		return m.st.dim.Render("—")
	}
	raw := v.Text()
	switch {
	case k == m.cfg.StatusField:
		return lipgloss.NewStyle().Foreground(m.theme.statusColor(raw)).Bold(true).Render("● " + raw)
	case k == m.cfg.TitleField || inKeys(k, titleKeys):
		return plain.Bold(true).Render(raw)
	case inKeys(k, deadlineKeys):
		return m.fmtDeadline(raw, status, false)
	case isDateKey && dateRe.MatchString(raw):
		return m.st.accent.Render(raw)
	case k == m.cfg.TypeField:
		return plain.Foreground(m.theme.Info).Render(typeLabel(raw))
	case inKeys(k, typeKeys):
		return plain.Foreground(m.theme.Info).Render(raw)
	case inKeys(k, idKeys):
		return plain.Foreground(m.theme.Dim).Render(raw)
	}
	return plain.Render(raw)
}

func (m *model) viewDetail(w, h int) string {
	n := m.detail
	if n == nil {
		return ""
	}
	status := m.statusOf(n)
	color := m.theme.statusColor(status)
	group := ""
	if t := m.taskOf(n); t != nil {
		group = t.Group
	}

	var head []string
	if g := m.groupNow(); g != nil {
		status, color = "", m.theme.Accent
		var counts []string
		total := 0
		for ci, name := range m.columns {
			c := len(m.cellTasks(g.List, ci))
			total += c
			counts = append(counts, lipgloss.NewStyle().Foreground(m.theme.statusColor(name)).
				Render(fmt.Sprintf("● %s %d", name, c)))
		}
		head = append(head, lipgloss.NewStyle().Bold(true).Width(w-2).Render(" "+g.Name))
		head = append(head, " "+m.st.accent.Render(fmt.Sprintf("предмет · задач: %d", total))+"   "+
			strings.Join(counts, "  "))
	} else {
		head = append(head, lipgloss.NewStyle().Bold(true).Width(w-2).Render(" "+m.titleOf(n)))
		head = append(head, " "+lipgloss.NewStyle().Foreground(color).Bold(true).Render("● "+colLabel(status))+
			m.st.dim.Render("  "+group))
	}
	head = append(head, lipgloss.NewStyle().Foreground(color).Render(strings.Repeat("━", w)))

	editBox := m.editBoxView(w)
	avail := h - len(head)
	if editBox != "" {
		avail -= lipgloss.Height(editBox)
	}
	out := strings.Join(head, "\n") + "\n" + lipgloss.NewStyle().Height(avail).
		Render(strings.Join(m.fieldLines(w, avail, status, group), "\n"))
	if editBox != "" {
		out += "\n" + editBox
	}
	return out
}

// fieldLines – строки полей открытой карточки (задачи или предмета),
// прокрученные так, чтобы выбранное поле было видно в avail строках.
func (m *model) fieldLines(w, avail int, status, group string) []string {
	n := m.detail
	vis := m.detailFields()
	keyW := 6
	for _, fi := range vis {
		keyW = max(keyW, lipgloss.Width(n.Fields[fi].Key))
	}
	keyW = min(keyW, 20)
	valW := max(10, w-keyW-5)

	var blocks [][]string
	// в карточке задачи первая строка – предмет (dField == -1)
	off := 0
	if m.detailGroup == nil {
		off = 1
		keyW = max(keyW, lipgloss.Width("предмет"))
		ks, mark := m.st.dim, "  "
		if m.dField == -1 {
			ks = lipgloss.NewStyle().Foreground(m.theme.Accent).Bold(true)
			mark = m.st.accent.Render("▸ ")
		}
		line := mark + ks.Render("предмет") + strings.Repeat(" ", keyW-lipgloss.Width("предмет")) + "  " +
			m.st.info.Bold(true).Render(group) + m.st.dim.Render("  (enter – выбрать другой)")
		blocks = append(blocks, []string{line, ""})
	}
	for i, fi := range vis {
		f := n.Fields[fi]
		val := m.fmtField(f.Key, f.Val, status, valW)
		ks := m.st.dim
		mark := "  "
		if i == m.dField {
			ks = lipgloss.NewStyle().Foreground(m.theme.Accent).Bold(true)
			mark = lipgloss.NewStyle().Foreground(m.theme.Accent).Render("▸ ")
		}
		keyCell := ks.Render(ansi.Truncate(f.Key, keyW, "…"))
		keyCell += strings.Repeat(" ", keyW-lipgloss.Width(keyCell))
		var bl []string
		for j, l := range strings.Split(val, "\n") {
			if j == 0 {
				bl = append(bl, mark+keyCell+"  "+l)
			} else {
				bl = append(bl, strings.Repeat(" ", keyW+4)+l)
			}
		}
		blocks = append(blocks, bl)
	}

	// прокрутка: начинаем с поля, при котором выбранное помещается
	sel := m.dField + off
	start := 0
	for {
		sum := 0
		for i := start; i <= sel && i < len(blocks); i++ {
			sum += len(blocks[i])
		}
		if sum <= avail || start >= sel {
			break
		}
		start++
	}
	var body []string
	for i := start; i < len(blocks) && len(body) < avail; i++ {
		body = append(body, blocks[i]...)
	}
	if len(body) > avail {
		body = body[:max(0, avail)]
	}
	return body
}

func (m *model) editBoxView(w int) string {
	if !m.editing {
		return ""
	}
	title := m.st.bold.Render("Изменить «"+m.editKey+"»") + m.st.dim.Render(" ("+kindName(m.editKind)+")")
	return lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(m.theme.Accent).
		Padding(0, 1).Width(w - 2).Render(title + "\n" + m.editor.View())
}

func kindName(k Kind) string {
	switch k {
	case KString:
		return "строка"
	case KNumber:
		return "число, JSON"
	case KBool:
		return "true/false"
	case KArray:
		return "массив, JSON"
	case KObject:
		return "объект, JSON"
	}
	return "пусто – текст станет строкой, JSON-значение – значением"
}

// ---------- настройки и выбор ----------

func (m *model) viewSettings(w, h int) string {
	var b strings.Builder
	b.WriteString("\n " + m.st.bold.Render("Настройки") + "\n\n")
	labelW := 0
	for _, s := range settingsList {
		labelW = max(labelW, lipgloss.Width(s.label))
	}
	for i, s := range settingsList {
		mark, ls := "  ", m.st.dim
		if i == m.setSel {
			mark = m.st.accent.Render("▸ ")
			ls = lipgloss.NewStyle().Foreground(m.theme.Accent).Bold(true)
		}
		val := s.get(&m.cfg)
		if i == m.setSel && m.setEditing {
			val = m.setInput.View()
		} else if s.label == "Тема" {
			val += "   " + m.palettePreview(m.theme)
		} else if val == "" {
			val = m.st.dim.Render("—")
		}
		label := ls.Render(s.label) + strings.Repeat(" ", labelW-lipgloss.Width(s.label))
		b.WriteString(" " + mark + label + "   " + val + "\n")
	}
	b.WriteString("\n " + m.st.dim.Render("Файл настроек: "+m.cfgPath) + "\n")
	b.WriteString(" " + m.st.dim.Render("Колонки, которых нет в списке, но встречаются в файле, добавляются справа автоматически.") + "\n")
	return b.String()
}

func (m *model) viewPicker() string {
	p := m.picker
	items := append([]string{}, p.items...)
	if p.addLabel != "" {
		items = append(items, p.addLabel)
	}
	nameW := 0
	for _, it := range items {
		nameW = max(nameW, lipgloss.Width(it))
	}
	nameW = min(nameW, m.w-24)
	// окно прокрутки вокруг выбранного пункта
	rows := max(3, m.h-10)
	from := 0
	if p.sel >= rows {
		from = p.sel - rows + 1
	}
	to := min(len(items), from+rows)

	lines := []string{m.st.bold.Render(p.title), ""}
	if from > 0 {
		lines = append(lines, m.st.dim.Render(fmt.Sprintf("  ↑ ещё %d", from)))
	}
	for i := from; i < to; i++ {
		st := lipgloss.NewStyle()
		if p.color != nil && i < len(p.items) {
			st = st.Foreground(p.color(i))
		}
		if i == len(p.items) {
			st = m.st.accent
			if len(p.items) > 0 {
				lines = append(lines, m.st.dim.Render(strings.Repeat("─", nameW+2)))
			}
		}
		mark := "  "
		if i == p.sel {
			mark = m.st.accent.Render("▸ ")
			st = st.Bold(true)
		}
		line := mark + st.Render(padRight(items[i], nameW))
		if i < len(p.hints) && p.hints[i] != "" {
			line += "  " + m.st.dim.Render(p.hints[i])
		}
		lines = append(lines, line)
	}
	if to < len(items) {
		lines = append(lines, m.st.dim.Render(fmt.Sprintf("  ↓ ещё %d", len(items)-to)))
	}
	return lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(m.theme.Accent).
		Padding(0, 2).Render(strings.Join(lines, "\n"))
}

func padRight(s string, w int) string {
	s = ansi.Truncate(s, w, "…")
	return s + strings.Repeat(" ", max(0, w-lipgloss.Width(s)))
}
