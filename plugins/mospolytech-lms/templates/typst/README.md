# Шаблон отчётов `@local/mospolytech-gost`

Typst-пакет с оформлением по ГОСТ 7.32-2017 и методичке кафедры ИКТ Московского Политеха.

```
local/mospolytech-gost/0.1.0/
├── typst.toml
├── lib.typ          — точка входа: стиль + титульник
├── styles.typ       — стиль gost и функции (img, tbl, head, references, …)
└── titlepage.typ    — make_title(...)
```

Подключение в отчёте:

```typst
#import "@local/mospolytech-gost:0.1.0": *
#show: gost
```

Компиляция — командой `typst-gost` из `bin/` плагина (`typst-gost.ps1` в PowerShell): обёртка указывает Typst эту папку как
`--package-path`, поэтому отчёт может лежать где угодно. Пути к файлам отчёта передаются как `path("assets/x.png")`.

Правила оформления и примеры — в скилле `skills/gost-typst/SKILL.md`.

Меняете шаблон несовместимо — поднимите версию (новая папка `0.2.0`, версия в `typst.toml`, в `lms.config.yaml` и в примерах скилла `gost-typst`),
чтобы старые отчёты продолжали собираться.
