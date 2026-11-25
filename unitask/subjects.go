package main

// Предметы (группы задач): выбор, переименование, создание, перенос задач
// между ними; выбор статуса и типа из списка; полоса прогресса.

import (
	"fmt"
	"math"
	"sort"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

func (m *model) groupOfList(list *Node) *Group {
	for i := range m.groups {
		if m.groups[i].List == list {
			return &m.groups[i]
		}
	}
	return nil
}

// filteredGroup – предмет, открытый через выбор предмета (v), или nil.
func (m *model) filteredGroup() *Group {
	if m.groupFilter == "" {
		return nil
	}
	for i := range m.groups {
		if m.groups[i].Name == m.groupFilter {
			return &m.groups[i]
		}
	}
	return nil
}

func (m *model) openSubjectPicker() { m.openSubjectPickerAt(nil) }

// openSubjectPickerAt – список предметов с курсором на at (или на открытом).
func (m *model) openSubjectPickerAt(at *Node) {
	if len(m.groups) == 0 {
		m.setMsg("в файле нет предметов", true)
		return
	}
	p := &picker{title: "Предмет", items: []string{"Все предметы"}, hints: []string{fmt.Sprintf("%d", len(m.tasks))},
		help: "↑↓ выбор · enter открыть · F2 переименовать · esc отмена"}
	for i, g := range m.groups {
		p.items = append(p.items, g.Name)
		p.hints = append(p.hints, m.doneHint(g.List))
		if (at == nil && g.Name == m.groupFilter) || g.List == at {
			p.sel = i + 1
		}
	}
	p.onPick = func(i int) {
		m.groupFilter = ""
		if i > 0 {
			m.groupFilter = m.groups[i-1].Name
		}
		m.clampSel()
	}
	p.onF2 = func(i int) {
		if i == 0 {
			return
		}
		list := m.groups[i-1].List
		m.renameGroupPrompt(m.groups[i-1], func() { m.openSubjectPickerAt(list) })
	}
	m.picker = p
}

// doneHint – «выполнено/всего» для подсказки в списке предметов.
func (m *model) doneHint(list *Node) string {
	done, total := 0, 0
	for _, t := range m.tasks {
		if t.List == list && m.kindOK(t.Node) {
			total++
			if m.isClosed(m.statusOf(t.Node)) {
				done++
			}
		}
	}
	return fmt.Sprintf("%d/%d", done, total)
}

func nameKey(owner *Node) string {
	if owner.Get("name") == nil && owner.Get("title") != nil {
		return "title"
	}
	return "name"
}

// renameGroupPrompt спрашивает новое имя; after вызывается после
// переименования или отмены (например, чтобы вернуться в список предметов).
func (m *model) renameGroupPrompt(g Group, after func()) {
	if g.Owner == nil {
		m.setMsg("у этого списка нет своего объекта – переименовать нельзя", true)
		return
	}
	in := newInput("")
	in.SetValue(g.Name)
	in.CursorEnd()
	in.Focus()
	m.prompt = &promptBox{title: "Новое название предмета:", input: in, onOK: func(name string) {
		if name != "" && name != g.Name {
			m.mutate(func() { g.Owner.Set(nameKey(g.Owner), NewString(name)) })
			if m.groupFilter == g.Name {
				m.groupFilter = name
			}
			m.setMsg("предмет переименован: "+name, false)
		}
		if after != nil {
			after()
		}
	}}
}

var translit = map[rune]string{
	'а': "a", 'б': "b", 'в': "v", 'г': "g", 'д': "d", 'е': "e", 'ё': "e", 'ж': "zh", 'з': "z", 'и': "i",
	'й': "y", 'к': "k", 'л': "l", 'м': "m", 'н': "n", 'о': "o", 'п': "p", 'р': "r", 'с': "s", 'т': "t",
	'у': "u", 'ф': "f", 'х': "h", 'ц': "ts", 'ч': "ch", 'ш': "sh", 'щ': "sch", 'ы': "y", 'э': "e",
	'ю': "yu", 'я': "ya",
}

func slugify(s string) string {
	var b strings.Builder
	dash := false
	for _, r := range strings.ToLower(s) {
		switch {
		case r >= 'a' && r <= 'z' || r >= '0' && r <= '9':
			b.WriteRune(r)
			dash = false
		case translit[r] != "":
			b.WriteString(translit[r])
			dash = false
		case r == 'ъ' || r == 'ь':
		default:
			if !dash && b.Len() > 0 {
				b.WriteByte('-')
				dash = true
			}
		}
	}
	out := strings.Trim(b.String(), "-")
	if out == "" {
		out = "subject"
	}
	return out
}

func blankLike(v *Node, keepArrays bool) *Node {
	switch v.Kind {
	case KString:
		return NewString("")
	case KArray:
		if keepArrays {
			return &Node{Kind: KArray}
		}
	}
	return NewNull()
}

// groupTemplate – предмет, по образцу которого создаётся новый: из
// текущего семестра, а если в нём ещё нет предметов – из любого в файле.
func (m *model) groupTemplate(prefer *Node) *Group {
	ok := func(g *Group) bool { return g.Owner != nil && len(g.Path) >= 2 }
	var found *Group
	for i := range m.groups {
		g := &m.groups[i]
		if !ok(g) {
			continue
		}
		if g.List == prefer {
			return g
		}
		if found == nil {
			found = g
		}
	}
	if found != nil {
		return found
	}
	// пути считаются от корня семестра, поэтому шаблон из архива ищется
	// внутри архивного семестра, а не во всём файле
	scopes := []*Node{m.root}
	arch := m.archivedSemesters()
	for i := len(arch) - 1; i >= 0; i-- {
		scopes = append(scopes, m.root.Get(archiveKey).Get(arch[i]))
	}
	for _, sc := range scopes {
		_, all := discover(m.root, sc, m.cfg.StatusField, archiveKey)
		for i := range all {
			if ok(&all[i]) {
				return &all[i]
			}
		}
	}
	return nil
}

// ensureContainer проходит по пути segs от scope, создавая недостающие
// объекты; на массиве останавливается – в него добавляют новые элементы.
func ensureContainer(scope *Node, segs []string) *Node {
	n := scope
	for _, seg := range segs {
		if n.Kind != KObject {
			break
		}
		child := n.Get(seg)
		if child == nil {
			child = &Node{Kind: KObject}
			n.Set(seg, child)
		}
		n = child
	}
	return n
}

func cloneNode(n *Node) *Node {
	c, _ := Parse(n.Marshal())
	return c
}

// placeGroup находит или создаёт в scope предмет по образцу tmpl (на том
// же пути) и возвращает его список задач. key – желаемый ключ предмета
// (пусто – по названию); copyMeta – скопировать поля предмета (преподаватель,
// заметки), а не оставить их пустыми. Вызывать внутри mutate.
func placeGroup(tmpl *Group, scope *Node, name, key string, copyMeta bool) *Node {
	cont := ensureContainer(scope, tmpl.Path[:len(tmpl.Path)-2])
	// предмет с таким названием уже есть – используем его
	findIn := func(own *Node) *Node {
		if own != nil && own.Kind == KObject && own.Get(nameKey(own)).Text() == name {
			if l := own.Get(tmpl.ListKey); l != nil && l.Kind == KArray {
				return l
			}
		}
		return nil
	}
	switch cont.Kind {
	case KObject:
		for _, f := range cont.Fields {
			if l := findIn(f.Val); l != nil {
				return l
			}
		}
	case KArray:
		for _, it := range cont.Items {
			if l := findIn(it); l != nil {
				return l
			}
		}
	}

	own := &Node{Kind: KObject}
	for _, f := range tmpl.Owner.Fields {
		switch {
		case f.Val.Kind == KArray && f.Key == tmpl.ListKey:
			own.Fields = append(own.Fields, Field{f.Key, &Node{Kind: KArray}})
		case copyMeta:
			own.Fields = append(own.Fields, Field{f.Key, cloneNode(f.Val)})
		default:
			own.Fields = append(own.Fields, Field{f.Key, blankLike(f.Val, true)})
		}
	}
	own.Set(nameKey(tmpl.Owner), NewString(name))
	list := own.Get(tmpl.ListKey)
	if list == nil || list.Kind != KArray {
		list = &Node{Kind: KArray}
		own.Set(tmpl.ListKey, list)
	}
	switch cont.Kind {
	case KObject:
		if key == "" || cont.Get(key) != nil {
			base := slugify(name)
			if key != "" {
				base = key
			}
			key = base
			for i := 2; cont.Get(key) != nil; i++ {
				key = fmt.Sprintf("%s-%d", base, i)
			}
		}
		cont.Set(key, own)
	case KArray:
		cont.Items = append(cont.Items, own)
	}
	return list
}

// newGroupNode – новый пустой предмет в текущем семестре.
func (m *model) newGroupNode(tmpl *Group, name string) *Node {
	return placeGroup(tmpl, m.semRoot(), name, "", false)
}

// pickGroup открывает список предметов с пунктом «новый предмет» внизу.
func (m *model) pickGroup(title string, cur *Node, onList func(list *Node, isNew bool, name string)) {
	p := &picker{title: title, addLabel: "+ новый предмет…"}
	for i, g := range m.groups {
		p.items = append(p.items, g.Name)
		if g.List == cur {
			p.sel = i
		}
	}
	p.onPick = func(i int) { onList(m.groups[i].List, false, "") }
	p.onAdd = func() {
		tmpl := m.groupTemplate(cur)
		if tmpl == nil {
			m.setMsg("не удалось понять, куда в файле добавить предмет", true)
			return
		}
		in := newInput("")
		in.Focus()
		m.prompt = &promptBox{title: "Название нового предмета:", input: in, onOK: func(name string) {
			if name != "" {
				onList(nil, true, name)
			}
		}}
	}
	m.picker = p
}

func removeItem(list *Node, n *Node) {
	out := list.Items[:0]
	for _, it := range list.Items {
		if it != n {
			out = append(out, it)
		}
	}
	list.Items = out
}

// reassignTask – перенос задачи в другой предмет (в том числе новый).
func (m *model) reassignTask(n *Node) {
	t := m.taskOf(n)
	if t == nil {
		return
	}
	from := t.List
	m.pickGroup("Перенести в предмет", from, func(list *Node, isNew bool, name string) {
		if !isNew && list == from {
			return
		}
		tmpl := m.groupTemplate(from)
		m.mutate(func() {
			if isNew {
				list = m.newGroupNode(tmpl, name)
			}
			removeItem(from, n)
			list.Items = append(list.Items, n)
		})
		if g := m.groupOfList(list); g != nil {
			if m.groupFilter != "" {
				m.groupFilter = g.Name
			}
			m.setMsg("задача перенесена в «"+g.Name+"»", false)
		}
		m.selectNode(n)
	})
}

// ---------- статус и тип ----------

func (m *model) pickStatus(n *Node) {
	p := &picker{title: "Статус"}
	cur := m.statusOf(n)
	var opts []string
	for _, c := range m.columns {
		if c != "" {
			opts = append(opts, c)
			p.items = append(p.items, c)
			if c == cur {
				p.sel = len(p.items) - 1
			}
		}
	}
	p.color = func(i int) lipgloss.TerminalColor { return m.theme.statusColor(opts[i]) }
	p.onPick = func(i int) { m.moveTask(n, opts[i]) }
	m.picker = p
}

func recordFilterLabel(f string) string {
	switch f {
	case "tasks":
		return "только задачи"
	case "events":
		return "только события"
	}
	return "задачи и события"
}

func (m *model) pickKind(n *Node) {
	opts := []string{"task", m.cfg.EventValue}
	p := &picker{title: "Вид записи", items: []string{"задача", "событие"}, hints: opts}
	if m.isEvent(n) {
		p.sel = 1
	}
	p.onPick = func(i int) {
		if n.Get(m.cfg.KindField).Text() != opts[i] {
			m.mutate(func() { n.Set(m.cfg.KindField, NewString(opts[i])) })
		}
	}
	m.picker = p
}

var typeLabels = map[string]string{
	"lab":        "лабораторная",
	"essay":      "реферат",
	"diploma":    "диплом",
	"other":      "прочее",
	"homework":   "домашнее задание",
	"coursework": "курсовая",
	"test":       "контрольная / тест",
	"exam":       "экзамен",
	"practice":   "практика",
	"project":    "проект",
	"report":     "отчёт",
}

func typeLabel(code string) string {
	if l, ok := typeLabels[code]; ok {
		return l
	}
	return code
}

func (m *model) pickType(n *Node, key string) {
	cur := n.Get(key).Text()
	opts := append([]string{}, m.cfg.Types...)
	var extra []string
	for _, t := range m.tasks {
		if v := t.Node.Get(key); v != nil && v.Kind == KString && v.Str != "" && !contains(opts, v.Str) && !contains(extra, v.Str) {
			extra = append(extra, v.Str)
		}
	}
	sort.Strings(extra)
	opts = append(opts, extra...)
	p := &picker{title: "Тип", addLabel: "+ новый тип…"}
	for i, o := range opts {
		p.items = append(p.items, typeLabel(o))
		if typeLabel(o) != o {
			p.hints = append(p.hints, o)
		} else {
			p.hints = append(p.hints, "")
		}
		if o == cur {
			p.sel = i
		}
	}
	set := func(v string) {
		if v != cur {
			m.mutate(func() { n.Set(key, NewString(v)) })
		}
	}
	p.onPick = func(i int) { set(opts[i]) }
	p.onAdd = func() {
		in := newInput("")
		in.Focus()
		m.prompt = &promptBox{title: "Новый тип:", input: in, onOK: func(v string) {
			if v != "" {
				set(v)
			}
		}}
	}
	m.picker = p
}

// ---------- прогресс ----------

// progressBar – одна полоса из цветных блоков по статусам с процентами
// внутри и процентом выполненного (выполнено + отменено) справа. Только
// здесь используется заливка: без неё текст внутри цветного блока не
// показать.
func (m *model) progressBar(w int) string {
	var tasks []Task
	for _, t := range m.tasks {
		if (m.groupFilter == "" || t.Group == m.groupFilter) && m.kindOK(t.Node) {
			tasks = append(tasks, t)
		}
	}
	total := len(tasks)
	counts := make([]int, len(m.columns))
	closed := 0
	for _, t := range tasks {
		s := m.statusOf(t.Node)
		for ci, c := range m.columns {
			if c == s {
				counts[ci]++
			}
		}
		if m.isClosed(s) {
			closed++
		}
	}
	pct := 0
	if total > 0 {
		pct = int(math.Round(float64(closed) * 100 / float64(total)))
	}
	right := "  " + lipgloss.NewStyle().Foreground(m.theme.Done).Bold(true).Render(fmt.Sprintf("выполнено %d%%", pct)) +
		m.st.dim.Render(fmt.Sprintf(" (%d из %d)", closed, total))
	barW := w - lipgloss.Width(right)
	if barW < 10 {
		return ansi.Truncate(right, w, "")
	}
	if total == 0 {
		return m.st.dim.Render(strings.Repeat("░", barW)) + right
	}

	// ширины блоков методом наибольшего остатка, непустой блок – не уже 1
	widths := make([]int, len(counts))
	type rem struct {
		i int
		r float64
	}
	var rems []rem
	used := 0
	for i, c := range counts {
		exact := float64(c) * float64(barW) / float64(total)
		widths[i] = int(exact)
		used += widths[i]
		rems = append(rems, rem{i, exact - float64(widths[i])})
	}
	sort.SliceStable(rems, func(a, b int) bool { return rems[a].r > rems[b].r })
	for k := 0; used < barW; k = (k + 1) % len(rems) {
		widths[rems[k].i]++
		used++
	}
	for i, c := range counts {
		if c > 0 && widths[i] == 0 {
			big := 0
			for j := range widths {
				if widths[j] > widths[big] {
					big = j
				}
			}
			widths[big]--
			widths[i]++
		}
	}

	var b strings.Builder
	for i, c := range counts {
		if widths[i] == 0 {
			continue
		}
		label := fmt.Sprintf("%d%%", int(math.Round(float64(c)*100/float64(total))))
		if lipgloss.Width(label) > widths[i] {
			label = ""
		}
		var bg lipgloss.TerminalColor = m.theme.statusColor(m.columns[i])
		if _, ok := bg.(lipgloss.NoColor); ok {
			bg = m.theme.Dim
		}
		b.WriteString(lipgloss.NewStyle().Background(bg).Foreground(m.theme.BarText).Bold(true).
			Width(widths[i]).Align(lipgloss.Center).Render(label))
	}
	return b.String() + right
}

// ---------- раскладка колонок ----------

// visibleCols – какие колонки помещаются в ширину w (с прокруткой к m.col).
func (m *model) visibleCols(w, minW int) (from, vis, colW int) {
	n := len(m.columns)
	colW = (w - (n - 1)) / n
	vis = n
	if colW < minW {
		vis = max(1, (w+1)/(minW+1))
		colW = (w - (vis - 1)) / vis
	}
	if m.col < m.colOff {
		m.colOff = m.col
	}
	if m.col >= m.colOff+vis {
		m.colOff = m.col - vis + 1
	}
	m.colOff = max(0, min(m.colOff, n-vis))
	return m.colOff, vis, colW
}
