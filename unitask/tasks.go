package main

import (
	"strconv"
	"strings"
)

// Задача – любой объект внутри массива, в котором хотя бы у одного объекта
// есть поле статуса. Структура вокруг (предметы, проекты, вложенность) может
// быть произвольной.
type Task struct {
	Node  *Node
	List  *Node
	Group string
}

// Group – список задач и объект, в котором он лежит (предмет, проект).
// Owner может быть nil, если список лежит прямо в корне или в массиве.
// Parent – контейнер, где лежит Owner, ListKey – ключ списка задач внутри
// Owner, Path – путь к списку от корня семестра (по нему новые предметы
// создаются в том же месте, в том числе в другом семестре).
type Group struct {
	Name    string
	List    *Node
	Owner   *Node
	Parent  *Node
	ListKey string
	Path    []string
}

// discover ищет записи внутри scope (корень семестра). Ключ skipKey в самом
// scope пропускается – так из текущего семестра исключается архив. Ключи
// списков собираются по всему файлу full, чтобы пустые списки нового
// семестра тоже распознавались.
func discover(full, scope *Node, statusField, skipKey string) ([]Task, []Group) {
	if full == nil || scope == nil {
		return nil, nil
	}
	// Первый проход – находим ключи, под которыми лежат списки задач.
	// Второй – считаем списками задач и пустые массивы с теми же ключами,
	// чтобы в «пустой» предмет тоже можно было добавить задачу.
	listKeys := map[string]bool{}
	var tasks []Task
	var groups []Group

	// parent – контейнер, где лежит n; ownerParent – контейнер, где лежит owner
	var walk func(n, parent, owner, ownerParent *Node, path []string, collect bool)
	walk = func(n, parent, owner, ownerParent *Node, path []string, collect bool) {
		switch n.Kind {
		case KObject:
			for _, f := range n.Fields {
				if n == scope && f.Key == skipKey && !collect {
					continue
				}
				walk(f.Val, n, n, parent, append(path[:len(path):len(path)], f.Key), collect)
			}
		case KArray:
			last := ""
			if len(path) > 0 {
				last = path[len(path)-1]
			}
			if isTaskList(n, statusField) || (len(n.Items) == 0 && listKeys[last]) {
				if collect {
					listKeys[last] = true
					return
				}
				name := groupName(owner, path)
				groups = append(groups, Group{Name: name, List: n, Owner: owner, Parent: ownerParent,
					ListKey: last, Path: append([]string{}, path...)})
				for _, it := range n.Items {
					if it.Kind == KObject {
						tasks = append(tasks, Task{Node: it, List: n, Group: name})
					}
				}
				return
			}
			for i, it := range n.Items {
				walk(it, n, owner, ownerParent, append(path[:len(path):len(path)], strconv.Itoa(i)), collect)
			}
		}
	}
	walk(full, nil, nil, nil, nil, true)
	walk(scope, nil, nil, nil, nil, false)
	return tasks, groups
}

func isTaskList(n *Node, statusField string) bool {
	for _, it := range n.Items {
		if it.Kind == KObject && it.Get(statusField) != nil {
			return true
		}
	}
	return false
}

func groupName(owner *Node, path []string) string {
	for _, k := range []string{"name", "title"} {
		if v := owner.Get(k); v != nil && v.Kind == KString && v.Str != "" {
			return v.Str
		}
	}
	switch len(path) {
	case 0:
		return "(корень)"
	case 1:
		return path[0]
	}
	return strings.Join(path[:len(path)-1], " › ")
}
