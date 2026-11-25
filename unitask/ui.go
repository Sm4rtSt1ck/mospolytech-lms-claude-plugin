package main

import (
	"fmt"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/cursor"
	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/textarea"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type screen int

const (
	scrTheme screen = iota
	scrPath
	scrBoard
	scrDetail
	scrSettings
)

type picker struct {
	title    string
	items    []string
	hints    []string // приглушённая подпись справа от пункта
	color    func(int) lipgloss.TerminalColor
	sel      int
	onPick   func(int)
	addLabel string // пункт внизу списка («+ новый …»)
	onAdd    func()
	onF2     func(int)
	onDelete func(int)
	help     string
}

type confirmBox struct {
	text  string
	onYes func()
}

type promptBox struct {
	title string
	input textinput.Model
	onOK  func(string)
}

type tickMsg time.Time

// tickInterval – как часто проверять, не изменили ли файл снаружи.
const tickInterval = 5 * time.Second

func tick() tea.Cmd {
	return tea.Tick(tickInterval, func(t time.Time) tea.Msg { return tickMsg(t) })
}

type model struct {
	cfg     Config
	cfgPath string
	theme   Theme
	st      styles
	scr     screen
	w, h    int

	filePath string
	root     *Node
	modTime  time.Time
	loadErr  string
	tasks    []Task
	groups   []Group
	undo     [][]byte
	conflict bool

	columns []string
	col     int
	sel     map[string]int
	top     map[string]int
	colOff  int

	filtering   bool
	filterInput textinput.Model
	groupFilter string

	picker  *picker
	confirm *confirmBox
	prompt  *promptBox

	viewSem string // архивный семестр, который сейчас открыт; пусто – текущий

	// карточка предмета – блок над полосой прогресса
	panel        bool
	panelClosing bool
	panelH       int
	panelTarget  int

	detail      *Node
	detailGroup *Group // не nil – открыта карточка группы, а не задачи
	dField      int
	editor      textarea.Model
	editing     bool
	editKey     string
	editKind    Kind

	setSel     int
	setEditing bool
	setInput   textinput.Model

	themeSel  int
	pathInput textinput.Model
	pathErr   string

	msg    string
	msgErr bool
}

func newInput(prompt string) textinput.Model {
	ti := textinput.New()
	ti.Prompt = prompt
	ti.Cursor.SetMode(cursor.CursorStatic)
	return ti
}

func newModel(cfg Config, cfgPath string, firstRun bool, argPath string) *model {
	m := &model{cfg: cfg, cfgPath: cfgPath, sel: map[string]int{}, top: map[string]int{}}
	m.applyTheme()

	m.filePath = expandPath(cfg.FilePath)
	if argPath != "" {
		m.filePath = expandPath(argPath)
		if m.cfg.FilePath == "" {
			m.cfg.FilePath = m.filePath
		}
	}

	m.filterInput = newInput("/ ")
	m.setInput = newInput("")
	m.pathInput = newInput("> ")

	ta := textarea.New()
	ta.ShowLineNumbers = false
	ta.Prompt = ""
	ta.CharLimit = 0
	ta.SetHeight(6)
	plain := lipgloss.NewStyle()
	st := textarea.Style{Base: plain, CursorLine: plain, CursorLineNumber: plain, EndOfBuffer: plain,
		LineNumber: plain, Placeholder: plain, Prompt: plain, Text: plain}
	ta.FocusedStyle, ta.BlurredStyle = st, st
	ta.Cursor.SetMode(cursor.CursorStatic)
	ta.KeyMap.InsertNewline = key.NewBinding(key.WithKeys("alt+enter", "ctrl+j"))
	m.editor = ta

	switch {
	case firstRun:
		m.scr = scrTheme
		if cfg.Theme == "light" {
			m.themeSel = 1
		}
	case m.filePath == "":
		m.toPathScreen()
	default:
		m.scr = scrBoard
		m.load()
	}
	return m
}

func (m *model) Init() tea.Cmd { return tick() }

func (m *model) applyTheme() {
	m.theme = themeByName(m.cfg.Theme)
	m.st = makeStyles(m.theme)
}

func (m *model) saveCfg() {
	if err := saveConfig(m.cfgPath, m.cfg); err != nil {
		m.setMsg("не удалось сохранить настройки: "+err.Error(), true)
	}
}

func (m *model) setMsg(s string, isErr bool) { m.msg, m.msgErr = s, isErr }

func (m *model) toPathScreen() {
	m.scr = scrPath
	m.pathInput.SetValue(m.cfg.FilePath)
	m.pathInput.CursorEnd()
	m.pathInput.Focus()
}

func today() string { return time.Now().Format("2006-01-02") }

// ---------- файл ----------

func (m *model) load() {
	m.root, m.tasks, m.groups, m.loadErr, m.undo, m.conflict = nil, nil, nil, "", nil, false
	data, err := os.ReadFile(m.filePath)
	if err == nil {
		var root *Node
		if root, err = Parse(data); err == nil {
			m.root = root
			if st, e := os.Stat(m.filePath); e == nil {
				m.modTime = st.ModTime()
			}
		}
	}
	if err != nil {
		m.loadErr = err.Error()
	}
	m.rebuild()
}

func (m *model) rebuild() {
	scope, skip := m.semRoot(), ""
	if scope == m.root {
		skip = archiveKey
	}
	m.tasks, m.groups = discover(m.root, scope, m.cfg.StatusField, skip)
	cols := append([]string{}, m.cfg.Statuses...)
	for _, t := range m.tasks {
		if s := m.statusOf(t.Node); !contains(cols, s) {
			cols = append(cols, s)
		}
	}
	m.columns = cols
	if m.col >= len(cols) {
		m.col = len(cols) - 1
	}
	m.clampSel()
}

func (m *model) save(force bool) {
	st, err := os.Stat(m.filePath)
	if err == nil && !force && !st.ModTime().Equal(m.modTime) {
		m.conflict = true
		m.setMsg("файл изменён снаружи – r: перечитать (ваши правки пропадут), W: перезаписать", true)
		return
	}
	perm := os.FileMode(0o644)
	if err == nil {
		perm = st.Mode().Perm()
	}
	tmp := m.filePath + ".tmp"
	if err := os.WriteFile(tmp, m.root.Marshal(), perm); err != nil {
		m.setMsg("не удалось сохранить: "+err.Error(), true)
		return
	}
	if err := os.Rename(tmp, m.filePath); err != nil {
		m.setMsg("не удалось сохранить: "+err.Error(), true)
		return
	}
	if st, err := os.Stat(m.filePath); err == nil {
		m.modTime = st.ModTime()
	}
	m.conflict = false
	m.setMsg("сохранено "+time.Now().Format("15:04:05"), false)
}

// mutate применяет правку, запоминает снимок для отмены и сохраняет файл.
func (m *model) mutate(f func()) {
	snap := m.root.Marshal()
	f()
	m.undo = append(m.undo, snap)
	if len(m.undo) > 100 {
		m.undo = m.undo[1:]
	}
	if uf := m.cfg.UpdatedField; uf != "" {
		if v := m.root.Get(uf); v != nil && (v.Kind == KString || v.Kind == KNull) {
			m.root.Set(uf, NewString(today()))
		}
	}
	m.save(false)
	m.rebuild()
}

func (m *model) undoLast() {
	if len(m.undo) == 0 {
		m.setMsg("отменять нечего", false)
		return
	}
	snap := m.undo[len(m.undo)-1]
	m.undo = m.undo[:len(m.undo)-1]
	root, err := Parse(snap)
	if err != nil {
		m.setMsg("ошибка отмены: "+err.Error(), true)
		return
	}
	ident := m.focusIdent()
	m.root = root
	m.save(false)
	m.rebuild()
	m.restoreFocus(ident)
	m.setMsg("последнее изменение отменено", false)
}

// identity и restoreDetail нужны, чтобы после перечитывания файла остаться
// на той же задаче: узлы дерева при этом создаются заново.
type taskIdent struct{ group, id, title string }

func (m *model) identity(n *Node) *taskIdent {
	if n == nil {
		return nil
	}
	t := m.taskOf(n)
	g := ""
	if t != nil {
		g = t.Group
	}
	return &taskIdent{g, n.Get("id").Text(), m.titleOf(n)}
}

// focusIdent – задача, открытая в карточке, или выделенная на доске.
func (m *model) focusIdent() *taskIdent {
	if m.detailGroup != nil {
		return nil
	}
	if m.detail != nil {
		return m.identity(m.detail)
	}
	if t := m.current(); t != nil {
		return m.identity(t.Node)
	}
	return nil
}

func (m *model) findIdent(id *taskIdent) *Node {
	if id == nil {
		return nil
	}
	for _, t := range m.tasks {
		if t.Group == id.group && t.Node.Get("id").Text() == id.id && (id.id != "" || m.titleOf(t.Node) == id.title) {
			return t.Node
		}
	}
	return nil
}

func (m *model) restoreFocus(id *taskIdent) {
	n := m.findIdent(id)
	if n != nil {
		m.selectNode(n)
	}
	if m.panel {
		// узлы пересозданы – карточка предмета больше не актуальна
		m.closePanel(false)
	}
	if m.scr != scrDetail {
		return
	}
	if m.detailGroup != nil {
		// узлы пересозданы – карточка группы больше не актуальна
		m.detailGroup, m.detail, m.scr = nil, nil, scrBoard
		return
	}
	m.detail = n
	if n == nil {
		m.scr = scrBoard
		return
	}
	m.clampField()
}

// checkExternal перечитывает файл, если его изменили снаружи, – но только
// когда в программе нет несохранённого ввода: открытого редактора поля,
// окна ввода или выбора, конфликта сохранения.
func (m *model) checkExternal() {
	if m.filePath == "" || m.editing || m.conflict || m.prompt != nil || m.confirm != nil || m.picker != nil {
		return
	}
	if m.scr != scrBoard && m.scr != scrDetail {
		return
	}
	st, err := os.Stat(m.filePath)
	if err != nil || (m.root != nil && st.ModTime().Equal(m.modTime)) {
		return
	}
	ident := m.focusIdent()
	panelGroup := ""
	if m.panel && !m.panelClosing {
		if g := m.groupNow(); g != nil {
			panelGroup = g.Name
		}
	}
	m.load()
	m.restoreFocus(ident)
	if panelGroup != "" { // карточка предмета остаётся открытой
		for i := range m.groups {
			if m.groups[i].Name == panelGroup {
				m.openPanel(&m.groups[i])
				m.panelH = panelOpen
				break
			}
		}
	}
	if m.root != nil {
		m.setMsg("файл изменён снаружи – перечитан", false)
	}
}

// ---------- задачи ----------

func contains(xs []string, s string) bool {
	for _, x := range xs {
		if x == s {
			return true
		}
	}
	return false
}

func (m *model) statusOf(n *Node) string { return n.Get(m.cfg.StatusField).Text() }

var (
	titleKeys    = []string{"title", "name", "summary", "subject"}
	deadlineKeys = []string{"deadline", "due", "due_date", "duedate", "дедлайн", "срок"}
	typeKeys     = []string{"type", "category", "priority", "tags", "label", "labels"}
	idKeys       = []string{"id", "uuid", "key"}
	noteKeys     = []string{"notes", "note", "description", "desc", "comment", "comments", "details"}
)

func (m *model) titleOf(n *Node) string {
	for _, k := range append([]string{m.cfg.TitleField}, titleKeys...) {
		if v := n.Get(k); v != nil && v.Text() != "" {
			return v.Text()
		}
	}
	if v := n.Get("id"); v != nil && v.Text() != "" {
		return v.Text()
	}
	return "(без названия)"
}

func firstField(n *Node, keys []string) (string, *Node) {
	for _, k := range keys {
		if v := n.Get(k); v != nil && v.Kind != KNull {
			return k, v
		}
	}
	return "", nil
}

func (m *model) taskOf(n *Node) *Task {
	for i := range m.tasks {
		if m.tasks[i].Node == n {
			return &m.tasks[i]
		}
	}
	return nil
}

// Записи бывают задачами и событиями (контрольные, мероприятия): поле
// kind_field со значением event_value; без поля – задача.
func (m *model) isEvent(n *Node) bool { return n.Get(m.cfg.KindField).Text() == m.cfg.EventValue }

// kindOK – проходит ли запись фильтр «задачи / события / все».
func (m *model) kindOK(n *Node) bool {
	switch m.cfg.RecordFilter {
	case "tasks":
		return !m.isEvent(n)
	case "events":
		return m.isEvent(n)
	}
	return true
}

func (m *model) matches(t Task) bool {
	if m.groupFilter != "" && t.Group != m.groupFilter {
		return false
	}
	if !m.kindOK(t.Node) {
		return false
	}
	f := strings.ToLower(strings.TrimSpace(m.filterInput.Value()))
	if f == "" {
		return true
	}
	var b strings.Builder
	t.Node.AllText(&b)
	b.WriteString(t.Group)
	return strings.Contains(strings.ToLower(b.String()), f)
}

func (m *model) colTasks(ci int) []Task { return m.cellTasks(nil, ci) }

// cellTasks – задачи колонки ci; list != nil – только из этого списка.
func (m *model) cellTasks(list *Node, ci int) []Task {
	if ci < 0 || ci >= len(m.columns) {
		return nil
	}
	name := m.columns[ci]
	var out []Task
	for _, t := range m.tasks {
		if (list == nil || t.List == list) && m.statusOf(t.Node) == name && m.matches(t) {
			out = append(out, t)
		}
	}
	if m.cfg.SortByDeadline {
		dl := func(t Task) string {
			if _, v := firstField(t.Node, deadlineKeys); v != nil && v.Text() != "" {
				return v.Text()
			}
			return "￿"
		}
		sort.SliceStable(out, func(i, j int) bool { return dl(out[i]) < dl(out[j]) })
	}
	return out
}

func (m *model) colName() string {
	if m.col < 0 || m.col >= len(m.columns) {
		return ""
	}
	return m.columns[m.col]
}

func (m *model) clampSel() {
	for ci, name := range m.columns {
		n := len(m.colTasks(ci))
		if m.sel[name] >= n {
			m.sel[name] = n - 1
		}
		if m.sel[name] < 0 {
			m.sel[name] = 0
		}
	}
}

func (m *model) current() *Task {
	ts := m.colTasks(m.col)
	i := m.sel[m.colName()]
	if i < 0 || i >= len(ts) {
		return nil
	}
	return &ts[i]
}

func (m *model) selectNode(n *Node) {
	for ci := range m.columns {
		for i, t := range m.colTasks(ci) {
			if t.Node == n {
				m.col = ci
				m.sel[m.columns[ci]] = i
			}
		}
	}
}

func (m *model) moveTask(n *Node, status string) {
	old := m.statusOf(n)
	if old == status {
		return
	}
	m.mutate(func() {
		n.Set(m.cfg.StatusField, NewString(status))
		if df := m.cfg.DoneDateField; df != "" && n.Get(df) != nil {
			if status == m.cfg.DoneStatus {
				n.Set(df, NewString(today()))
			} else if old == m.cfg.DoneStatus {
				n.Set(df, NewNull())
			}
		}
	})
	m.selectNode(n)
}

func (m *model) shiftStatus(n *Node, d int) {
	ci := -1
	for i, c := range m.columns {
		if c == m.statusOf(n) {
			ci = i
		}
	}
	for ni := ci + d; ni >= 0 && ni < len(m.columns); ni += d {
		if m.columns[ni] != "" {
			m.moveTask(n, m.columns[ni])
			return
		}
	}
}

func emptyLike(v *Node) *Node {
	if v.Kind == KString {
		return NewString("")
	}
	return NewNull()
}

func (m *model) startNewTask() {
	if len(m.groups) == 0 && m.groupTemplate(nil) == nil {
		m.setMsg("в файле не найдено ни одного списка задач (массива объектов с полем «"+m.cfg.StatusField+"»)", true)
		return
	}
	create := func(list *Node) {
		// поля – по образцу задачи из того же предмета, а если он пуст – любой
		var tmpl *Node
		for _, it := range list.Items {
			if it.Kind == KObject {
				tmpl = it
				break
			}
		}
		if tmpl == nil && len(m.tasks) > 0 {
			tmpl = m.tasks[0].Node
		}
		n := &Node{Kind: KObject}
		if tmpl != nil {
			for _, f := range tmpl.Fields {
				n.Fields = append(n.Fields, Field{f.Key, emptyLike(f.Val)})
			}
		}
		if n.Get("id") != nil {
			ids := map[string]bool{}
			for _, it := range list.Items {
				ids[it.Get("id").Text()] = true
			}
			i := 1
			for ids[fmt.Sprintf("new-%d", i)] {
				i++
			}
			n.Set("id", NewString(fmt.Sprintf("new-%d", i)))
		}
		title := m.cfg.TitleField
		if title == "" {
			title = "title"
		}
		if n.Get(title) == nil {
			n.Fields = append([]Field{{title, NewString("")}}, n.Fields...)
		}
		status := m.colName()
		if status == "" && len(m.cfg.Statuses) > 0 {
			status = m.cfg.Statuses[0]
		}
		n.Set(m.cfg.StatusField, NewString(status))
		if m.cfg.RecordFilter == "events" {
			n.Set(m.cfg.KindField, NewString(m.cfg.EventValue))
		} else if n.Get(m.cfg.KindField) != nil {
			n.Set(m.cfg.KindField, NewString("task"))
		}
		m.mutate(func() { list.Items = append(list.Items, n) })
		m.selectNode(n)
		m.openDetail(n)
		m.focusField(title)
		m.startEdit(title)
	}
	if g := m.filteredGroup(); g != nil {
		create(g.List)
		return
	}
	var cur *Node
	if t := m.current(); t != nil {
		cur = t.List
	}
	m.pickGroup("В какой предмет добавить задачу?", cur, func(list *Node, isNew bool, name string) {
		if isNew {
			tmpl := m.groupTemplate(cur)
			if tmpl == nil {
				m.setMsg("не удалось понять, куда в файле добавить предмет", true)
				return
			}
			m.mutate(func() { list = m.newGroupNode(tmpl, name) })
		}
		create(list)
	})
}

func (m *model) deleteTask(n *Node) {
	t := m.taskOf(n)
	if t == nil {
		return
	}
	list := t.List
	m.confirm = &confirmBox{
		text: fmt.Sprintf("Удалить задачу «%s»?", m.titleOf(n)),
		onYes: func() {
			m.mutate(func() {
				out := list.Items[:0]
				for _, it := range list.Items {
					if it != n {
						out = append(out, it)
					}
				}
				list.Items = out
			})
			if m.scr == scrDetail {
				m.scr, m.detail = scrBoard, nil
			}
		},
	}
}

func (m *model) openDetail(n *Node) {
	m.detail, m.detailGroup, m.dField, m.scr = n, nil, 0, scrDetail
}

// detailFields – индексы полей, которые показываются в карточке.
func (m *model) detailFields() []int {
	var out []int
	if m.detail == nil {
		return out
	}
	for i, f := range m.detail.Fields {
		if m.detailGroup != nil && m.isTaskList(f.Val) {
			continue
		}
		out = append(out, i)
	}
	return out
}

func (m *model) isTaskList(n *Node) bool {
	for _, g := range m.groups {
		if g.List == n {
			return true
		}
	}
	return false
}

func (m *model) fieldKey() string {
	vis := m.detailFields()
	if m.dField < 0 || m.dField >= len(vis) {
		return ""
	}
	return m.detail.Fields[vis[m.dField]].Key
}

func (m *model) focusField(k string) {
	for i, fi := range m.detailFields() {
		if m.detail.Fields[fi].Key == k {
			m.dField = i
		}
	}
}

// groupNow – актуальная версия открытой группы (имя могло поменяться).
func (m *model) groupNow() *Group {
	if m.detailGroup == nil {
		return nil
	}
	for i := range m.groups {
		if m.groups[i].List == m.detailGroup.List {
			return &m.groups[i]
		}
	}
	return m.detailGroup
}

// minField: в карточке задачи есть строка «предмет» с индексом -1.
func (m *model) minField() int {
	if m.detailGroup == nil {
		return -1
	}
	return 0
}

func (m *model) clampField() {
	if m.detail == nil {
		return
	}
	if n := len(m.detailFields()); m.dField >= n {
		m.dField = n - 1
	}
	if m.dField < m.minField() {
		m.dField = m.minField()
	}
}

// editField – правка поля: статус и тип выбираются из списка, остальное –
// в текстовом редакторе.
func (m *model) editField(k string) {
	if m.detailGroup == nil {
		switch k {
		case m.cfg.StatusField:
			m.pickStatus(m.detail)
			return
		case m.cfg.TypeField:
			m.pickType(m.detail, k)
			return
		case m.cfg.KindField:
			m.pickKind(m.detail)
			return
		}
	}
	m.startEdit(k)
}

func (m *model) startEdit(k string) {
	v := m.detail.Get(k)
	m.editKey, m.editKind = k, KNull
	text := ""
	if v != nil {
		m.editKind = v.Kind
		switch v.Kind {
		case KArray, KObject:
			text = v.Pretty()
		default:
			text = v.Text()
		}
	}
	m.editor.SetWidth(max(10, m.w-6))
	m.editor.SetValue(text)
	m.editor.Focus()
	m.editing = true
}

// convertValue: строка остаётся строкой, null превращается в JSON-значение,
// если текст похож на JSON, иначе в строку; числа, массивы и т.п. требуют
// корректного JSON. Пустой ввод – null.
func convertValue(kind Kind, txt string) (*Node, error) {
	if kind == KString {
		return NewString(txt), nil
	}
	t := strings.TrimSpace(txt)
	if t == "" {
		return NewNull(), nil
	}
	n, err := Parse([]byte(t))
	if kind == KNull && err != nil {
		return NewString(txt), nil
	}
	return n, err
}

func (m *model) finishEdit() {
	nv, err := convertValue(m.editKind, m.editor.Value())
	if err != nil {
		m.setMsg("некорректный JSON: "+err.Error(), true)
		return
	}
	m.editing = false
	m.editor.Blur()
	n, k := m.detail, m.editKey
	if old := n.Get(k); old != nil && old.Compact() == nv.Compact() {
		return
	}
	if m.detailGroup == nil && k == m.cfg.StatusField && nv.Kind == KString {
		m.moveTask(n, nv.Str)
		return
	}
	oldName := ""
	if g := m.groupNow(); g != nil {
		oldName = g.Name
	}
	m.mutate(func() { n.Set(k, nv) })
	// группа переименована – фильтр по ней не должен потеряться
	if g := m.groupNow(); g != nil && m.groupFilter != "" && m.groupFilter == oldName {
		m.groupFilter = g.Name
	}
}

// ---------- клавиши ----------

// Горячие клавиши работают и в русской раскладке.
var ruToEn = func() map[rune]rune {
	ru := []rune("йцукенгшщзхъфывапролджэячсмитьбюЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ")
	en := []rune("qwertyuiop[]asdfghjkl;'zxcvbnm,.QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>")
	mp := map[rune]rune{}
	for i := range ru {
		mp[ru[i]] = en[i]
	}
	return mp
}()

func normKey(s string) string {
	r := []rune(s)
	if len(r) == 1 {
		if e, ok := ruToEn[r[0]]; ok {
			return string(e)
		}
	}
	return s
}

func (m *model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
		m.editor.SetWidth(max(10, m.w-6))
		return m, nil
	case tickMsg:
		m.checkExternal()
		return m, tick()
	case animMsg:
		return m, m.stepPanel()
	case tea.KeyMsg:
		if msg.String() == "ctrl+c" {
			return m, tea.Quit
		}
		return m, m.handleKey(msg)
	}
	return m, nil
}

func (m *model) handleKey(k tea.KeyMsg) tea.Cmd {
	if m.confirm != nil {
		c := m.confirm
		m.confirm = nil
		switch normKey(k.String()) {
		case "y", "Y", "enter":
			c.onYes()
		default:
			m.setMsg("отменено", false)
		}
		return nil
	}
	if m.prompt != nil {
		switch k.String() {
		case "esc":
			m.prompt = nil
		case "enter":
			p := m.prompt
			m.prompt = nil
			p.onOK(strings.TrimSpace(p.input.Value()))
		default:
			var cmd tea.Cmd
			m.prompt.input, cmd = m.prompt.input.Update(k)
			return cmd
		}
		return nil
	}
	if m.picker != nil {
		p := m.picker
		n := len(p.items)
		if p.addLabel != "" {
			n++
		}
		switch normKey(k.String()) {
		case "up", "k":
			if p.sel > 0 {
				p.sel--
			}
		case "down", "j":
			if p.sel < n-1 {
				p.sel++
			}
		case "home":
			p.sel = 0
		case "end":
			p.sel = n - 1
		case "enter":
			m.picker = nil
			if p.sel == len(p.items) {
				p.onAdd()
			} else if p.sel < len(p.items) {
				p.onPick(p.sel)
			}
		case "f2":
			if p.onF2 != nil && p.sel < len(p.items) {
				m.picker = nil
				p.onF2(p.sel)
			}
		case "d", "delete":
			if p.onDelete != nil && p.sel < len(p.items) {
				m.picker = nil
				p.onDelete(p.sel)
			}
		case "esc", "q":
			m.picker = nil
		}
		return nil
	}
	m.msg = ""
	switch m.scr {
	case scrTheme:
		return m.keyTheme(k)
	case scrPath:
		return m.keyPath(k)
	case scrBoard:
		if m.panel && !m.panelClosing {
			return m.keyDetail(k)
		}
		return m.keyBoard(k)
	case scrDetail:
		return m.keyDetail(k)
	case scrSettings:
		return m.keySettings(k)
	}
	return nil
}

func (m *model) keyTheme(k tea.KeyMsg) tea.Cmd {
	switch normKey(k.String()) {
	case "up", "k", "left", "h":
		m.themeSel = 0
	case "down", "j", "right", "l":
		m.themeSel = 1
	case "enter":
		m.cfg.Theme = []string{"dark", "light"}[m.themeSel]
		m.applyTheme()
		m.saveCfg()
		if m.filePath == "" {
			m.toPathScreen()
		} else {
			m.scr = scrBoard
			m.load()
		}
	case "q", "esc":
		return tea.Quit
	}
	return nil
}

func (m *model) keyPath(k tea.KeyMsg) tea.Cmd {
	switch k.String() {
	case "esc":
		return tea.Quit
	case "enter":
		p := expandPath(m.pathInput.Value())
		if st, err := os.Stat(p); err != nil || st.IsDir() {
			m.pathErr = "файл не найден: " + p
			return nil
		}
		m.cfg.FilePath, m.filePath, m.pathErr = p, p, ""
		m.saveCfg()
		m.pathInput.Blur()
		m.scr = scrBoard
		m.load()
		return nil
	}
	var cmd tea.Cmd
	m.pathInput, cmd = m.pathInput.Update(k)
	return cmd
}

func (m *model) keyBoard(k tea.KeyMsg) tea.Cmd {
	if m.filtering {
		switch k.String() {
		case "esc":
			m.filtering = false
			m.filterInput.SetValue("")
			m.filterInput.Blur()
		case "enter":
			m.filtering = false
			m.filterInput.Blur()
		default:
			m.filterInput, _ = m.filterInput.Update(k)
		}
		m.clampSel()
		return nil
	}
	ks := normKey(k.String())
	if m.root == nil {
		switch ks {
		case "q":
			return tea.Quit
		case "r":
			m.load()
		case "s", ",":
			m.scr = scrSettings
		}
		return nil
	}
	name := m.colName()
	switch ks {
	case "v", "g":
		m.openSubjectPicker()
	case "f2":
		if g := m.filteredGroup(); g != nil {
			m.renameGroupPrompt(*g, nil)
		} else if t := m.current(); t != nil {
			if g := m.groupOfList(t.List); g != nil {
				m.renameGroupPrompt(*g, nil)
			}
		}
	case "e":
		if g := m.filteredGroup(); g != nil {
			return m.openPanel(g)
		} else if t := m.current(); t != nil {
			return m.openPanel(m.groupOfList(t.List))
		}
	case "c":
		m.openSemesterPicker()
	case "[":
		m.stepSemester(1)
	case "]":
		m.stepSemester(-1)
	case "q":
		return tea.Quit
	case "left", "h":
		if m.col > 0 {
			m.col--
		}
	case "right", "l":
		if m.col < len(m.columns)-1 {
			m.col++
		}
	case "up", "k":
		if m.sel[name] > 0 {
			m.sel[name]--
		}
	case "down", "j":
		m.sel[name]++
	case "home":
		m.sel[name] = 0
	case "end":
		m.sel[name] = len(m.colTasks(m.col)) - 1
	case "shift+left", "H", "<":
		if t := m.current(); t != nil {
			m.shiftStatus(t.Node, -1)
		}
	case "shift+right", "L", ">":
		if t := m.current(); t != nil {
			m.shiftStatus(t.Node, 1)
		}
	case "enter":
		if t := m.current(); t != nil {
			m.openDetail(t.Node)
		}
	case "n":
		m.startNewTask()
	case "D", "delete":
		if t := m.current(); t != nil {
			m.deleteTask(t.Node)
		}
	case "/":
		m.filtering = true
		m.filterInput.Focus()
	case "esc":
		m.filterInput.SetValue("")
		m.groupFilter = ""
	case "t":
		m.cfg.RecordFilter = map[string]string{"all": "tasks", "tasks": "events", "events": "all"}[m.cfg.RecordFilter]
		if m.cfg.RecordFilter == "" {
			m.cfg.RecordFilter = "all"
		}
		m.saveCfg()
		m.clampSel()
		m.setMsg("показываются: "+recordFilterLabel(m.cfg.RecordFilter), false)
	case "o":
		m.cfg.SortByDeadline = !m.cfg.SortByDeadline
		m.saveCfg()
		if m.cfg.SortByDeadline {
			m.setMsg("сортировка: по дедлайну", false)
		} else {
			m.setMsg("сортировка: как в файле", false)
		}
	case "u":
		m.undoLast()
	case "r":
		m.load()
		m.setMsg("перечитано", false)
	case "W":
		m.save(true)
	case "s", ",":
		m.scr = scrSettings
	default:
		if len(ks) == 1 && ks[0] >= '1' && ks[0] <= '9' {
			if ci := int(ks[0] - '1'); ci < len(m.columns) && m.columns[ci] != "" {
				if t := m.current(); t != nil {
					m.moveTask(t.Node, m.columns[ci])
				}
			}
		}
	}
	m.clampSel()
	return nil
}

func (m *model) keyDetail(k tea.KeyMsg) tea.Cmd {
	if m.editing {
		switch k.String() {
		case "esc":
			m.editing = false
			m.editor.Blur()
		case "enter":
			m.finishEdit()
		default:
			var cmd tea.Cmd
			m.editor, cmd = m.editor.Update(k)
			return cmd
		}
		return nil
	}
	n := m.detail
	if n == nil {
		m.scr = scrBoard
		return nil
	}
	isGroup := m.detailGroup != nil
	ks := normKey(k.String())
	if m.panel && (ks == "e" || ks == "esc" || ks == "q" || ks == "backspace") {
		return m.closePanel(true)
	}
	switch ks {
	case "esc", "q", "backspace":
		m.scr = scrBoard
		if !isGroup {
			m.selectNode(n)
		}
		m.detail, m.detailGroup = nil, nil
	case "up", "k":
		if m.dField > m.minField() {
			m.dField--
		}
	case "down", "j":
		if m.dField < len(m.detailFields())-1 {
			m.dField++
		}
	case "enter", "e":
		if m.dField == -1 {
			m.reassignTask(n)
		} else if k := m.fieldKey(); k != "" {
			m.editField(k)
		}
	case "p":
		if !isGroup {
			m.reassignTask(n)
		}
	case "f2":
		if isGroup {
			m.renameGroupPrompt(*m.groupNow(), nil)
		} else if t := m.taskOf(n); t != nil {
			if g := m.groupOfList(t.List); g != nil {
				m.renameGroupPrompt(*g, nil)
			}
		}
	case "a":
		in := newInput("")
		in.Focus()
		m.prompt = &promptBox{title: "Имя нового поля:", input: in, onOK: func(name string) {
			if name == "" {
				return
			}
			if v := n.Get(name); v != nil && m.isTaskList(v) {
				m.setMsg("это поле – список задач, его не редактируют здесь", true)
				return
			}
			if n.Get(name) == nil {
				m.mutate(func() { n.Set(name, NewNull()) })
			}
			m.focusField(name)
			m.editField(name)
		}}
	case "d", "x", "delete":
		if k := m.fieldKey(); k != "" {
			m.confirm = &confirmBox{text: fmt.Sprintf("Удалить поле «%s»?", k), onYes: func() {
				m.mutate(func() { n.Delete(k) })
				m.clampField()
			}}
		}
	case "D":
		if !isGroup {
			m.deleteTask(n)
		}
	case "shift+left", "H", "<":
		if !isGroup {
			m.shiftStatus(n, -1)
		}
	case "shift+right", "L", ">":
		if !isGroup {
			m.shiftStatus(n, 1)
		}
	case "u":
		m.undoLast()
	}
	return nil
}

type setting struct {
	label  string
	get    func(*Config) string
	set    func(*Config, string)
	toggle func(*Config)
}

func yesNo(b bool) string {
	if b {
		return "да"
	}
	return "нет"
}

var settingsList = []setting{
	{label: "Путь к JSON-файлу", get: func(c *Config) string { return c.FilePath },
		set: func(c *Config, v string) { c.FilePath = expandPath(v) }},
	{label: "Тема", get: func(c *Config) string {
		if c.Theme == "light" {
			return "светлая"
		}
		return "тёмная"
	}, toggle: func(c *Config) {
		if c.Theme == "light" {
			c.Theme = "dark"
		} else {
			c.Theme = "light"
		}
	}},
	{label: "Колонки (статусы через запятую)", get: func(c *Config) string { return strings.Join(c.Statuses, ", ") },
		set: func(c *Config, v string) {
			var out []string
			for _, s := range strings.Split(v, ",") {
				if s = strings.TrimSpace(s); s != "" {
					out = append(out, s)
				}
			}
			if len(out) > 0 {
				c.Statuses = out
			}
		}},
	{label: "Поле статуса", get: func(c *Config) string { return c.StatusField },
		set: func(c *Config, v string) {
			if v != "" {
				c.StatusField = v
			}
		}},
	{label: "Поле заголовка", get: func(c *Config) string { return c.TitleField },
		set: func(c *Config, v string) { c.TitleField = v }},
	{label: "Поле типа", get: func(c *Config) string { return c.TypeField },
		set: func(c *Config, v string) {
			if v != "" {
				c.TypeField = v
			}
		}},
	{label: "Типы в списке выбора (через запятую)", get: func(c *Config) string { return strings.Join(c.Types, ", ") },
		set: func(c *Config, v string) {
			c.Types = nil
			for _, s := range strings.Split(v, ",") {
				if s = strings.TrimSpace(s); s != "" {
					c.Types = append(c.Types, s)
				}
			}
		}},
	{label: "Показывать", get: func(c *Config) string { return recordFilterLabel(c.RecordFilter) },
		toggle: func(c *Config) {
			c.RecordFilter = map[string]string{"all": "tasks", "tasks": "events", "events": "all"}[c.RecordFilter]
			if c.RecordFilter == "" {
				c.RecordFilter = "all"
			}
		}},
	{label: "Поле «задача / событие»", get: func(c *Config) string { return c.KindField },
		set: func(c *Config, v string) {
			if v != "" {
				c.KindField = v
			}
		}},
	{label: "Значение для событий", get: func(c *Config) string { return c.EventValue },
		set: func(c *Config, v string) {
			if v != "" {
				c.EventValue = v
			}
		}},
	{label: "Статус «выполнено»", get: func(c *Config) string { return c.DoneStatus },
		set: func(c *Config, v string) { c.DoneStatus = v }},
	{label: "Поле даты выполнения", get: func(c *Config) string { return c.DoneDateField },
		set: func(c *Config, v string) { c.DoneDateField = v }},
	{label: "Поле «обновлено» в корне файла", get: func(c *Config) string { return c.UpdatedField },
		set: func(c *Config, v string) { c.UpdatedField = v }},
	{label: "Сортировать по дедлайну", get: func(c *Config) string { return yesNo(c.SortByDeadline) },
		toggle: func(c *Config) { c.SortByDeadline = !c.SortByDeadline }},
}

func (m *model) keySettings(k tea.KeyMsg) tea.Cmd {
	s := settingsList[m.setSel]
	if m.setEditing {
		switch k.String() {
		case "esc":
			m.setEditing = false
			m.setInput.Blur()
		case "enter":
			m.setEditing = false
			m.setInput.Blur()
			oldPath := m.cfg.FilePath
			s.set(&m.cfg, strings.TrimSpace(m.setInput.Value()))
			m.saveCfg()
			if m.cfg.FilePath != oldPath {
				m.filePath = m.cfg.FilePath
				m.load()
			} else {
				m.rebuild()
			}
		default:
			var cmd tea.Cmd
			m.setInput, cmd = m.setInput.Update(k)
			return cmd
		}
		return nil
	}
	switch normKey(k.String()) {
	case "up", "k":
		if m.setSel > 0 {
			m.setSel--
		}
	case "down", "j":
		if m.setSel < len(settingsList)-1 {
			m.setSel++
		}
	case "enter", " ", "e":
		if s.toggle != nil {
			s.toggle(&m.cfg)
			m.applyTheme()
			m.saveCfg()
			m.rebuild()
		} else {
			m.setInput.SetValue(s.get(&m.cfg))
			m.setInput.CursorEnd()
			m.setInput.Focus()
			m.setEditing = true
		}
	case "esc", "q", "s", ",":
		if m.filePath == "" {
			m.toPathScreen()
		} else {
			m.scr = scrBoard
		}
	}
	return nil
}
