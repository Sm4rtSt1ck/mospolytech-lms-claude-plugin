package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

type Config struct {
	FilePath       string   `json:"file_path"`
	Theme          string   `json:"theme"` // dark | light
	Statuses       []string `json:"statuses"`
	StatusField    string   `json:"status_field"`
	TitleField     string   `json:"title_field"`
	DoneStatus     string   `json:"done_status"`
	DoneDateField  string   `json:"done_date_field"`
	UpdatedField   string   `json:"updated_field"`
	SortByDeadline bool     `json:"sort_by_deadline"`
	TypeField      string   `json:"type_field"`
	Types          []string `json:"types"`         // типы, которые всегда есть в списке выбора
	KindField      string   `json:"kind_field"`    // поле «задача / событие»
	EventValue     string   `json:"event_value"`   // значение этого поля у событий
	RecordFilter   string   `json:"record_filter"` // all | tasks | events
}

func defaultConfig() Config {
	return Config{
		Theme:          "dark",
		Statuses:       []string{"to-do", "in-progress", "done", "cancelled"},
		StatusField:    "status",
		TitleField:     "title",
		DoneStatus:     "done",
		DoneDateField:  "done_at",
		UpdatedField:   "updated",
		SortByDeadline: true,
		TypeField:      "type",
		Types:          []string{"lab", "essay", "diploma", "other"},
		KindField:      "kind",
		EventValue:     "event",
		RecordFilter:   "all",
	}
}

func defaultConfigPath() string {
	if p := os.Getenv("UNITASK_CONFIG"); p != "" {
		return p
	}
	dir, err := os.UserConfigDir()
	if err != nil {
		dir = "."
	}
	return filepath.Join(dir, "unitask", "config.json")
}

// legacyConfigPath — где лежали настройки, пока программа называлась task-viewer.
func legacyConfigPath() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "task-viewer", "config.json")
}

// migrateLegacyConfig копирует настройки task-viewer в новую папку, если своих настроек ещё нет.
func migrateLegacyConfig(path, legacy string) {
	if legacy == "" || path == legacy {
		return
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		return
	}
	data, err := os.ReadFile(legacy)
	if err != nil {
		return
	}
	if os.MkdirAll(filepath.Dir(path), 0o755) == nil {
		_ = os.WriteFile(path, data, 0o644)
	}
}

// setFilePath записывает в настройки путь к файлу задач, не трогая остальные поля.
func setFilePath(cfgPath, file string) error {
	cfg, _, err := loadConfig(cfgPath)
	if err != nil {
		return err
	}
	cfg.FilePath = file
	return saveConfig(cfgPath, cfg)
}

// loadConfig возвращает настройки и признак того, что файл настроек уже был.
func loadConfig(path string) (Config, bool, error) {
	cfg := defaultConfig()
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return cfg, false, nil
	}
	if err != nil {
		return cfg, false, err
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return cfg, true, err
	}
	def := defaultConfig()
	if len(cfg.Statuses) == 0 {
		cfg.Statuses = def.Statuses
	}
	if cfg.TypeField == "" {
		cfg.TypeField = def.TypeField
	}
	if cfg.KindField == "" {
		cfg.KindField = def.KindField
	}
	if cfg.EventValue == "" {
		cfg.EventValue = def.EventValue
	}
	if cfg.RecordFilter == "" {
		cfg.RecordFilter = def.RecordFilter
	}
	if cfg.Types == nil {
		cfg.Types = def.Types
	}
	if cfg.StatusField == "" {
		cfg.StatusField = def.StatusField
	}
	return cfg, true, nil
}

func saveConfig(path string, cfg Config) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(data, '\n'), 0o644)
}

func expandPath(p string) string {
	p = strings.TrimSpace(p)
	if p == "~" || strings.HasPrefix(p, "~/") || strings.HasPrefix(p, `~\`) {
		if home, err := os.UserHomeDir(); err == nil {
			p = filepath.Join(home, p[1:])
		}
	}
	return p
}
