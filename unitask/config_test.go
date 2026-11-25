package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSetFilePathKeepsOtherSettings(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "unitask", "config.json")
	cfg := defaultConfig()
	cfg.Theme = "light"
	cfg.FilePath = "/old/progress.json"
	if err := saveConfig(cfgPath, cfg); err != nil {
		t.Fatal(err)
	}
	if err := setFilePath(cfgPath, "/new/progress.json"); err != nil {
		t.Fatal(err)
	}
	got, exists, err := loadConfig(cfgPath)
	if err != nil || !exists {
		t.Fatalf("loadConfig: exists=%v err=%v", exists, err)
	}
	if got.FilePath != "/new/progress.json" || got.Theme != "light" {
		t.Fatalf("got file_path=%q theme=%q", got.FilePath, got.Theme)
	}
}

func TestSetFilePathCreatesConfig(t *testing.T) {
	cfgPath := filepath.Join(t.TempDir(), "a", "config.json")
	if err := setFilePath(cfgPath, "/x/progress.json"); err != nil {
		t.Fatal(err)
	}
	got, exists, _ := loadConfig(cfgPath)
	if !exists || got.FilePath != "/x/progress.json" || got.Theme != "dark" {
		t.Fatalf("exists=%v cfg=%+v", exists, got)
	}
}

func TestMigrateLegacyConfig(t *testing.T) {
	dir := t.TempDir()
	legacy := filepath.Join(dir, "task-viewer", "config.json")
	path := filepath.Join(dir, "unitask", "config.json")
	if err := saveConfig(legacy, Config{FilePath: "/legacy.json", Theme: "light"}); err != nil {
		t.Fatal(err)
	}
	migrateLegacyConfig(path, legacy)
	got, exists, _ := loadConfig(path)
	if !exists || got.FilePath != "/legacy.json" {
		t.Fatalf("migration failed: exists=%v cfg=%+v", exists, got)
	}
	// An existing config is never overwritten.
	_ = setFilePath(path, "/mine.json")
	migrateLegacyConfig(path, legacy)
	got, _, _ = loadConfig(path)
	if got.FilePath != "/mine.json" {
		t.Fatalf("existing config overwritten: %q", got.FilePath)
	}
	if _, err := os.Stat(legacy); err != nil {
		t.Fatalf("legacy config must stay: %v", err)
	}
}
