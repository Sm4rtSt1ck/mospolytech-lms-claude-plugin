package main

// Семестры: текущий записан в корневом поле semester, прошлые лежат в
// archive.<семестр> в том же виде, в каком были в корне. Показывается
// только один семестр – текущий или выбранный архивный.

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

const (
	semesterKey = "semester"
	archiveKey  = "archive"
)

// semRoot – узел, в котором ищутся записи открытого семестра.
func (m *model) semRoot() *Node {
	if m.root == nil {
		return nil
	}
	if m.viewSem != "" {
		if s := m.root.Get(archiveKey).Get(m.viewSem); s != nil && s.Kind == KObject {
			return s
		}
		m.viewSem = ""
	}
	return m.root
}

func (m *model) curSemester() string { return m.root.Get(semesterKey).Text() }

// archivedSemesters – семестры из архива в порядке файла.
func (m *model) archivedSemesters() []string {
	var out []string
	if a := m.root.Get(archiveKey); a != nil && a.Kind == KObject {
		for _, f := range a.Fields {
			if f.Val.Kind == KObject {
				out = append(out, f.Key)
			}
		}
	}
	return out
}

// semLabel: 2026-autumn → «осень 2026», 2027-spring → «весна 2027».
func semLabel(s string) string {
	y, season, ok := splitSemester(s)
	if !ok {
		if s == "" {
			return "текущий семестр"
		}
		return s
	}
	if season == "autumn" {
		return fmt.Sprintf("осень %d", y)
	}
	return fmt.Sprintf("весна %d", y)
}

func splitSemester(s string) (int, string, bool) {
	i := strings.LastIndex(s, "-")
	if i < 0 {
		return 0, "", false
	}
	y, err := strconv.Atoi(s[:i])
	season := s[i+1:]
	if err != nil || (season != "autumn" && season != "spring") {
		return 0, "", false
	}
	return y, season, true
}

// guessSemester – семестр по дате: с августа по январь осенний, иначе весенний.
func guessSemester(t time.Time) string {
	switch y, mo := t.Year(), t.Month(); {
	case mo >= time.August:
		return fmt.Sprintf("%d-autumn", y)
	case mo == time.January:
		return fmt.Sprintf("%d-autumn", y-1)
	default:
		return fmt.Sprintf("%d-spring", y)
	}
}

func nextSemester(s string) string {
	y, season, ok := splitSemester(s)
	if !ok {
		return ""
	}
	if season == "autumn" {
		return fmt.Sprintf("%d-spring", y+1)
	}
	return fmt.Sprintf("%d-autumn", y)
}

// semesterList – все семестры: текущий (пусто) и архивные, от новых к старым.
func (m *model) semesterList() []string {
	arch := m.archivedSemesters()
	out := []string{""}
	for i := len(arch) - 1; i >= 0; i-- {
		out = append(out, arch[i])
	}
	return out
}

func (m *model) switchSemester(s string) {
	if s == m.viewSem {
		return
	}
	m.viewSem, m.groupFilter = s, ""
	m.closePanel(false)
	m.rebuild()
	m.col = 0
	m.clampSel()
	if s == "" {
		m.setMsg("текущий семестр: "+semLabel(m.curSemester()), false)
	} else {
		m.setMsg("архив: "+semLabel(s), false)
	}
}

// stepSemester: d = +1 – более старый семестр, -1 – более новый.
func (m *model) stepSemester(d int) {
	list := m.semesterList()
	for i, s := range list {
		if s == m.viewSem {
			if j := i + d; j >= 0 && j < len(list) {
				m.switchSemester(list[j])
			}
			return
		}
	}
}

func (m *model) openSemesterPicker() {
	list := m.semesterList()
	p := &picker{title: "Семестр", addLabel: "+ новый семестр…",
		help: "↑↓ выбор · enter открыть · d удалить · esc отмена · [ ] – соседний семестр прямо с доски"}
	for i, s := range list {
		if s == "" {
			p.items = append(p.items, semLabel(m.curSemester()))
			p.hints = append(p.hints, "текущий")
		} else {
			p.items = append(p.items, semLabel(s))
			p.hints = append(p.hints, "архив, перенесён "+m.root.Get(archiveKey).Get(s).Get("archived_at").Text())
		}
		if s == m.viewSem {
			p.sel = i
		}
	}
	p.onPick = func(i int) { m.switchSemester(list[i]) }
	p.onAdd = m.startNewSemester
	p.onDelete = func(i int) { m.deleteSemesterPrompt(list[i]) }
	m.picker = p
}

func semPrompt(title, value string, onOK func(string)) *promptBox {
	in := newInput("")
	in.SetValue(value)
	in.CursorEnd()
	in.Focus()
	return &promptBox{title: title, input: in, onOK: onOK}
}

// startNewSemester спрашивает названия семестров и что делать с
// незакрытыми записями, потом переносит текущий семестр в архив.
func (m *model) startNewSemester() {
	if m.root == nil || m.root.Kind != KObject {
		m.setMsg("новый семестр можно создать только в файле с объектом в корне", true)
		return
	}
	m.switchSemester("")
	askNew := func(cur string) {
		m.prompt = semPrompt("Новый семестр (например, 2027-spring):", nextSemester(cur), func(next string) {
			switch {
			case next == "":
				return
			case next == cur || contains(m.archivedSemesters(), next):
				m.setMsg("семестр «"+next+"» уже есть", true)
				return
			}
			open := 0
			for _, t := range m.tasks {
				if !m.isClosed(m.statusOf(t.Node)) {
					open++
				}
			}
			if open == 0 {
				m.newSemester(cur, next, false)
				return
			}
			p := &picker{title: fmt.Sprintf("Незакрытых записей: %d. Что с ними сделать?", open),
				items: []string{"Перенести в новый семестр как долги", "Оставить в архиве"},
				hints: []string{"в архиве станут cancelled", "останутся как есть"}}
			p.onPick = func(i int) { m.newSemester(cur, next, i == 0) }
			m.picker = p
		})
	}
	if cur := m.curSemester(); cur != "" {
		askNew(cur)
		return
	}
	m.prompt = semPrompt("Как назвать текущий семестр (уйдёт в архив)?", guessSemester(time.Now()), func(cur string) {
		if cur != "" {
			askNew(cur)
		}
	})
}

// appendNote дописывает пометку в конец notes, не трогая исходный текст:
// после знака препинания – через пробел, иначе через «; ». Разделитель
// однозначен, поэтому removeNote возвращает заметку символ в символ.
func appendNote(n *Node, note string) {
	v := n.Get("notes")
	if v == nil || v.Kind != KString || v.Str == "" {
		n.Set("notes", NewString(note))
		return
	}
	sep := "; "
	if strings.ContainsAny(v.Str[len(v.Str)-1:], ".!?)") || strings.HasSuffix(v.Str, "…") {
		sep = " "
	}
	n.Set("notes", NewString(v.Str+sep+note))
}

// setAfter вставляет поле после ключа after (или в начало), если его нет.
func setAfter(n *Node, after, key string, v *Node) {
	if n.Get(key) != nil {
		n.Set(key, v)
		return
	}
	at := 0
	for i, f := range n.Fields {
		if f.Key == after {
			at = i + 1
		}
	}
	n.Fields = append(n.Fields[:at], append([]Field{{key, v}}, n.Fields[at:]...)...)
}

// newSemester переносит всё, что относится к текущему семестру, в
// archive.<cur> и открывает пустой семестр next. carry – скопировать
// незакрытые записи в новый семестр как долги (в архиве они становятся
// cancelled с пометкой о переносе).
func (m *model) newSemester(cur, next string, carry bool) {
	groups := append([]Group{}, m.groups...)
	var tops []string
	for _, g := range groups {
		if len(g.Path) > 0 && !contains(tops, g.Path[0]) {
			tops = append(tops, g.Path[0])
		}
	}
	carried := 0
	m.mutate(func() {
		root := m.root
		entry := &Node{Kind: KObject}
		entry.Set("archived_at", NewString(today()))
		for _, k := range tops {
			v := root.Get(k)
			entry.Set(k, v)
			root.Set(k, &Node{Kind: v.Kind})
		}
		arch := root.Get(archiveKey)
		if arch == nil || arch.Kind != KObject {
			arch = &Node{Kind: KObject}
			root.Set(archiveKey, arch)
		}
		arch.Set(cur, entry)
		setAfter(root, m.cfg.UpdatedField, semesterKey, NewString(next))

		if !carry {
			return
		}
		for gi := range groups {
			g := &groups[gi]
			for _, it := range g.List.Items {
				if it.Kind != KObject || m.isClosed(m.statusOf(it)) {
					continue
				}
				key := ""
				if len(g.Path) >= 2 {
					key = g.Path[len(g.Path)-2]
				}
				var list *Node
				if g.Owner != nil && len(g.Path) >= 2 {
					list = placeGroup(g, root, g.Name, key, true)
				} else {
					list = ensureContainer(root, g.Path)
					if list.Kind != KArray {
						continue
					}
				}
				debt := cloneNode(it)
				if df := m.cfg.DoneDateField; df != "" && debt.Get(df) != nil {
					debt.Set(df, NewNull())
				}
				appendNote(debt, debtNote(cur))
				list.Items = append(list.Items, debt)
				it.Set(m.cfg.StatusField, NewString("cancelled"))
				appendNote(it, movedNote(next))
				carried++
			}
		}
	})
	m.viewSem, m.groupFilter = "", ""
	m.rebuild()
	m.col = 0
	m.clampSel()
	msg := "открыт семестр " + semLabel(next) + ", " + semLabel(cur) + " – в архиве"
	if carried > 0 {
		msg += fmt.Sprintf("; долгов перенесено: %d", carried)
	}
	m.setMsg(msg+" (u – отменить)", false)
}

// ---------- удаление семестра ----------

func (m *model) deleteSemesterPrompt(s string) {
	if s != "" {
		m.confirm = &confirmBox{
			text:  fmt.Sprintf("Удалить архивный семестр «%s» со всеми записями?", semLabel(s)),
			onYes: func() { m.deleteArchived(s) },
		}
		return
	}
	arch := m.archivedSemesters()
	if len(arch) == 0 {
		m.setMsg("это единственный семестр – удалять нечего", true)
		return
	}
	m.switchSemester("")
	prev, cur := arch[len(arch)-1], m.curSemester()
	extra := 0
	for _, t := range m.tasks {
		if !strings.Contains(t.Node.Get("notes").Text(), debtNote(prev)) {
			extra++
		}
	}
	if extra == 0 {
		m.confirm = &confirmBox{
			text: fmt.Sprintf("Удалить семестр «%s» и вернуться к «%s»? Долги вернутся на место.",
				semLabel(cur), semLabel(prev)),
			onYes: func() { m.deleteCurrent(prev, false) },
		}
		return
	}
	p := &picker{title: fmt.Sprintf("Удалить «%s» и вернуться к «%s». Новых записей: %d – что с ними?",
		semLabel(cur), semLabel(prev), extra),
		items: []string{"Перенести в «" + semLabel(prev) + "»", "Удалить вместе с семестром"},
		help:  "долги в любом случае вернутся на место · esc – не удалять"}
	p.onPick = func(i int) { m.deleteCurrent(prev, i == 0) }
	m.picker = p
}

func debtNote(sem string) string  { return "Долг " + sem + "." }
func movedNote(sem string) string { return "Перенесено в " + sem + " как долг." }

// removeNote убирает пометку, добавленную appendNote.
func removeNote(n *Node, note string) {
	v := n.Get("notes")
	if v == nil || v.Kind != KString {
		return
	}
	str := v.Str
	switch {
	case str == note:
		str = ""
	case strings.HasSuffix(str, "; "+note):
		str = strings.TrimSuffix(str, "; "+note)
	case strings.HasSuffix(str, " "+note):
		str = strings.TrimSuffix(str, " "+note)
	case strings.Contains(str, "; "+note): // после пометки дописали ещё текст
		str = strings.Replace(str, "; "+note, "", 1)
	case strings.Contains(str, " "+note):
		str = strings.Replace(str, " "+note, "", 1)
	default:
		return
	}
	n.Set("notes", NewString(str))
}

func (m *model) deleteArchived(s string) {
	m.mutate(func() {
		arch := m.root.Get(archiveKey)
		arch.Delete(s)
		if len(arch.Fields) == 0 {
			m.root.Delete(archiveKey)
		}
	})
	if m.viewSem == s {
		m.viewSem = ""
		m.rebuild()
	}
	m.setMsg("семестр «"+semLabel(s)+"» удалён (u – отменить)", false)
}

// deleteCurrent удаляет текущий семестр и возвращает prev из архива.
// Долги снова встают на место записей в prev (с тем статусом, который у
// них сейчас), остальные записи текущего семестра переносятся в prev при
// keep или пропадают.
func (m *model) deleteCurrent(prev string, keep bool) {
	cur := m.curSemester()
	groups := append([]Group{}, m.groups...)
	type key struct{ owner, id string }
	keyOf := func(g *Group, n *Node) key {
		k := key{id: n.Get("id").Text()}
		if len(g.Path) >= 2 {
			k.owner = g.Path[len(g.Path)-2]
		}
		if k.id == "" {
			k.id = m.titleOf(n)
		}
		return k
	}
	m.mutate(func() {
		root := m.root
		debts := map[key]*Node{}
		used := map[*Node]bool{}
		for gi := range groups {
			g := &groups[gi]
			for _, it := range g.List.Items {
				if strings.Contains(it.Get("notes").Text(), debtNote(prev)) {
					debts[keyOf(g, it)] = it
				}
			}
		}

		arch := root.Get(archiveKey)
		entry := arch.Get(prev)
		for _, g := range groups {
			if len(g.Path) > 0 && entry.Get(g.Path[0]) == nil {
				root.Delete(g.Path[0]) // в прошлом семестре такого раздела не было
			}
		}
		for _, f := range entry.Fields {
			if f.Key != "archived_at" {
				root.Set(f.Key, f.Val)
			}
		}
		arch.Delete(prev)
		if len(arch.Fields) == 0 {
			root.Delete(archiveKey)
		}
		root.Set(semesterKey, NewString(prev))

		// долги – обратно на место cancelled-записей
		_, restored := discover(root, root, m.cfg.StatusField, archiveKey)
		for gi := range restored {
			g := &restored[gi]
			for i, it := range g.List.Items {
				if !strings.Contains(it.Get("notes").Text(), movedNote(cur)) {
					continue
				}
				if d := debts[keyOf(g, it)]; d != nil && !used[d] {
					used[d] = true
					removeNote(d, debtNote(prev))
					g.List.Items[i] = d
				} else {
					removeNote(it, movedNote(cur))
				}
			}
		}
		if !keep {
			return
		}
		for gi := range groups {
			g := &groups[gi]
			for _, it := range g.List.Items {
				if used[it] || it.Kind != KObject {
					continue
				}
				var list *Node
				if g.Owner != nil && len(g.Path) >= 2 {
					list = placeGroup(g, root, g.Name, g.Path[len(g.Path)-2], true)
				} else if l := ensureContainer(root, g.Path); l.Kind == KArray {
					list = l
				}
				if list != nil {
					list.Items = append(list.Items, it)
				}
			}
		}
	})
	m.viewSem, m.groupFilter = "", ""
	m.rebuild()
	m.col = 0
	m.clampSel()
	m.setMsg("семестр «"+semLabel(cur)+"» удалён, открыт «"+semLabel(prev)+"» (u – отменить)", false)
}
