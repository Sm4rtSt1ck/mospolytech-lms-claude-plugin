package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRoundTripAndDiscover(t *testing.T) {
	data, _ := os.ReadFile(samplePath(t))
	root, err := Parse(data)
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimRight(string(root.Marshal()), "\n") != strings.TrimRight(string(data), "\n") {
		t.Fatal("после чтения и записи файл изменился")
	}
	tasks, groups := discover(root, root, "status", "archive")
	t.Logf("задач: %d, групп: %d", len(tasks), len(groups))
	for _, g := range groups {
		t.Logf("группа %q: %d", g.Name, len(g.List.Items))
	}
	if os.Getenv("UNITASK_SAMPLE") == "" && (len(tasks) != 4 || len(groups) != 2 || groups[1].Name != "Пустой проект") {
		t.Fatalf("testdata: задач %d, групп %d", len(tasks), len(groups))
	}
}

// samplePath копирует тестовый файл во временную папку: тесты его меняют.
// UNITASK_SAMPLE позволяет прогнать их на своём файле.
func samplePath(t *testing.T) string {
	src := os.Getenv("UNITASK_SAMPLE")
	if src == "" {
		src = "testdata/sample.json"
	}
	data, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(t.TempDir(), "tasks.json")
	if err := os.WriteFile(dst, data, 0o644); err != nil {
		t.Fatal(err)
	}
	return dst
}
