package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"

	tea "github.com/charmbracelet/bubbletea"
)

// version подставляется при сборке: -ldflags "-X main.version=1.2.3".
var version = "dev"

func main() {
	cfgFlag := flag.String("config", "", "путь к файлу настроек (по умолчанию – в папке настроек пользователя)")
	getFile := flag.Bool("get-file", false, "напечатать путь к файлу задач из настроек и выйти")
	setFile := flag.String("set-file", "", "записать в настройки путь к файлу задач и выйти")
	showVersion := flag.Bool("version", false, "напечатать версию и выйти")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "Использование: unitask [-config настройки.json] [задачи.json]\n")
		fmt.Fprintf(os.Stderr, "             unitask -get-file | -set-file задачи.json | -version\n\n")
		fmt.Fprintf(os.Stderr, "Без аргумента открывается файл из настроек.\n\n")
		flag.PrintDefaults()
	}
	flag.Parse()

	if *showVersion {
		fmt.Println("unitask", version)
		return
	}

	cfgPath := *cfgFlag
	if cfgPath == "" {
		cfgPath = defaultConfigPath()
		if os.Getenv("UNITASK_CONFIG") == "" {
			migrateLegacyConfig(cfgPath, legacyConfigPath())
		}
	}

	if *setFile != "" {
		abs, err := filepath.Abs(expandPath(*setFile))
		if err != nil {
			abs = *setFile
		}
		if err := setFilePath(cfgPath, abs); err != nil {
			fmt.Fprintf(os.Stderr, "не удалось записать настройки %s: %v\n", cfgPath, err)
			os.Exit(1)
		}
		return
	}
	cfg, exists, err := loadConfig(cfgPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "не удалось прочитать настройки %s: %v\n", cfgPath, err)
		os.Exit(1)
	}
	if *getFile {
		if cfg.FilePath != "" {
			fmt.Println(expandPath(cfg.FilePath))
		}
		return
	}

	m := newModel(cfg, cfgPath, !exists, flag.Arg(0))
	if _, err := tea.NewProgram(m, tea.WithAltScreen()).Run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
