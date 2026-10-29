// Оформление ВКР по методичке кафедры ИКТ Московского Политеха (2021),
// ГОСТ 7.32-2017, ГОСТ 2.105, ГОСТ 9327, ГОСТ Р 7.0.5-2008, ГОСТ 7.1-2003.
// Где методичка расходится с ГОСТ, приоритет у методички (помечено «Методичка»).
//
// Подключение:
//   #import "@local/mospolytech-gost:0.1.0": *
//   #show: gost
//
// Структурные элементы (ВВЕДЕНИЕ, ЗАКЛЮЧЕНИЕ, ...): #head[Введение] или
// `= Введение` — номер не ставится, заголовок по центру прописными.
// Разделы основной части: `= Раздел`, `== Подраздел`, `=== Пункт`.
// Содержание: #contents() — с его страницы начинают печататься номера.
// Приложения: #show: appendices, затем #appendix[Название] для каждого.


//======================= ПАРАМЕТРЫ =======================\\

#let FONT = "Times New Roman"
#let MONO = "Courier New"
#let MATH = "Cambria Math"
#let SIZE = 14pt         // кегль основного текста
#let SMALL = 12pt        // таблицы, сноски, листинги
#let INDENT = 1.25cm     // абзацный отступ

// Межстрочный интервал 1,5 как в Word: высота «одинарной» строки
// Times New Roman — 1,15 кегля, а между верхним (ascender) и нижним
// (descender) краями шрифта — 1,107 кегля
#let PITCH = 1.5 * 1.15 * SIZE                  // шаг строк
#let LEADING = PITCH - 1.107 * SIZE             // зазор между строками
#let BLANK = LEADING + PITCH                    // одна пустая строка
#let SMALL_LEADING = 1.15 * SMALL - 1.107 * SMALL  // одинарный интервал, 12 пт

// Буквы для приложений и перечислений: ГОСТ 7.32 запрещает
// Ё, З, Й, О, Ч, Ъ, Ы, Ь
#let _APP_LETTERS = "АБВГДЕЖИКЛМНПРСТУФХЦШЩЭЮЯ".clusters()
#let _ENUM_LETTERS = "абвгдежиклмнпрстуфхцшщэюя".clusters()

// Названия структурных элементов, которые не нумеруются
#let _STRUCTURAL = (
  "Реферат", "Аннотация", "Содержание", "Термины и определения",
  "Перечень сокращений и обозначений", "Перечень сокращений",
  "Введение", "Заключение", "Список источников", "Список использованных источников",
  "Список сокращений",
)

#let _appendix = state("gost-appendix", false)
#let _list-depth = state("gost-list-depth", 0)
#let _in-table = state("gost-in-table", false)


//======================= ВСПОМОГАТЕЛЬНОЕ =======================\\

#let _app-letter(n) = _APP_LETTERS.at(calc.rem(n - 1, _APP_LETTERS.len()))

// Номер рисунка, таблицы, листинга или формулы: «1» в основной части,
// «1.2» при нумерации в пределах раздела, «А.1» в приложениях
#let _by-section = state("gost-by-section", false)
#let _elem-number(n) = {
  let chapter = counter(heading).get().first()
  if _appendix.get() {
    _app-letter(chapter) + "." + str(n)
  } else if _by-section.get() and chapter > 0 {
    str(chapter) + "." + str(n)
  } else {
    str(n)
  }
}

// «Таблица N» / «Рисунок N» / «Продолжение таблицы N» ведут обратно к
// первому упоминанию в тексте (@label); без упоминания — обычный текст
#let _back-link(lbl, body) = {
  let mentions = if lbl == none { () } else { query(ref.where(target: lbl)) }
  if mentions.len() > 0 { link(mentions.first().location(), body) } else { body }
}

#let _reset-elements() = {
  counter(figure.where(kind: image)).update(0)
  counter(figure.where(kind: table)).update(0)
  counter(figure.where(kind: raw)).update(0)
  counter(math.equation).update(0)
}

// Нумерация заголовков в приложениях: А, А.1, А.1.1
#let _app-numbering(..nums) = {
  let n = nums.pos()
  (_app-letter(n.first()), ..n.slice(1).map(str)).join(".")
}

// Разделяет тело пункта списка на текст пункта и вложенные перечисления
#let _split-item(body) = {
  let kids = if body.func() == [].func() { body.children } else { (body,) }
  let nested = (list, enum, list.item, enum.item)
  let idx = kids.position(k => k.func() in nested)
  if idx == none { (body, none) } else { (kids.slice(0, idx).join(), kids.slice(idx).join()) }
}

// Перечисление: каждый пункт — абзац, маркер с абзацного отступа
// (ГОСТ 7.32 п. 6.4.6), переносы строк — от левого поля. Вложенные уровни
// сдвигаются ещё на один отступ, как в примере ГОСТ 2.105-95 п. 4.1.7 и
// ГОСТ Р 2.105-2019 п. 6.7. Расстояние от маркера до текста стандарты не
// задают — текст начинается через 1,25 см от начала маркера (в таблицах
// — через пробел, чтобы не занимать ширину ячейки)
#let _render-list(it, marker) = {
  _list-depth.update(d => d + 1)
  let n = if it.func() == enum and it.start != auto { it.start } else { 1 }
  for item in it.children {
    if it.func() == enum and type(item.number) == int { n = item.number }
    let (text-part, nested) = _split-item(item.body)
    let num = n
    context {
      let depth = _list-depth.get()
      let level = if _in-table.get() { depth - 1 } else { depth }
      par(first-line-indent: (amount: INDENT * level, all: true))[
        #if _in-table.get() [#marker(num, depth)#h(0.3em)] else { box(width: INDENT, marker(num, depth)) }#text-part
      ]
    }
    nested
    n += 1
  }
  _list-depth.update(d => d - 1)
}

// Методичка: список первого порядка — «1.», все остальные — второго
// порядка: вложенные а), б), ..., ещё глубже 1), 2), ...
#let _letter-marker(n) = {
  let l = _ENUM_LETTERS.len()
  let letter = _ENUM_LETTERS.at(calc.rem(n - 1, l))
  if n > l { letter = letter + letter }
  letter + ")"
}
#let _gost-enum-marker(n, depth) = {
  if depth <= 1 {
    str(n) + "."
  } else if depth == 2 {
    _letter-marker(n)
  } else {
    str(n) + ")"
  }
}

//======================= ОСНОВНОЙ СТИЛЬ =======================\\

// by-section: true — рисунки, таблицы и формулы нумеруются в пределах
// раздела (1.1, 1.2), иначе сквозная нумерация (1, 2, 3)
#let gost(by-section: false, body) = {

  _by-section.update(by-section)

  // ---------- Страница (ГОСТ 9327, ГОСТ 7.32 п. 6.1) ----------
  // А4, поля: левое 30 мм, правое 15 мм, верхнее и нижнее 20 мм.
  // Номер страницы — арабскими цифрами по центру нижней части листа без
  // точки. Методичка: нумерация с титульного листа, но на титульном листе,
  // задании и аннотации номер не ставится — печатается начиная со страницы
  // содержания (метка <gost-numbering-start> ставится в contents())
  set page(
    paper: "a4",
    margin: (left: 30mm, right: 15mm, top: 20mm, bottom: 20mm),
    header-ascent: 0pt,
    header: context {
      // «Продолжение таблицы N» над перенесённой частью таблицы
      let page = here().page()
      for fig in query(figure.where(kind: table)) {
        // Метка конца ставится внутри фигуры сразу после таблицы
        let end = query(selector(<gost-table-end>).after(fig.location())).first()
        if fig.location().page() < page and end.location().page() >= page and fig.numbering != none {
          let num = numbering(fig.numbering, ..counter(figure.where(kind: table)).at(fig.location()))
          let lbl = if fig.has("label") { fig.label }
          align(bottom + left, block(below: 0pt, text(size: SIZE, _back-link(lbl)[Продолжение таблицы #num])))
          break
        }
      }
    },
    footer: context {
      let start = query(<gost-numbering-start>)
      let first = if start.len() > 0 { start.first().location().page() } else { 2 }
      if here().page() >= first {
        align(center, text(size: SIZE, counter(page).display("1")))
      }
    },
  )

  // ---------- Шрифт и абзацы (ГОСТ 7.32 п. 6.1.1) ----------
  // Times New Roman, 14 пт, черный, интервал 1,5, выравнивание по
  // ширине, абзацный отступ 1,25 см
  set text(
    font: FONT,
    size: SIZE,
    fill: black,
    lang: "ru",
    region: "ru",
    hyphenate: false,
    top-edge: "ascender",
    bottom-edge: "descender",
  )
  set par(
    justify: true,
    leading: LEADING,
    spacing: LEADING,
    first-line-indent: (amount: INDENT, all: true),
  )
  set block(spacing: LEADING)
  show math.equation: set text(font: MATH)
  show raw: set text(font: MONO)
  set raw(theme: none)
  show link: set text(fill: black)

  // ---------- Заголовки (методичка п. 2.2.10, ГОСТ 7.32 п. 6.2) ----------
  // Основные разделы (и нумерованные, и структурные элементы) — по центру,
  // без абзацного отступа, прописными, с новой страницы.
  // Подразделы и пункты — с абзацного отступа, с прописной буквы.
  // Все заголовки полужирные, без точки в конце и без переносов, после
  // номера точка не ставится. Методичка: заголовок от текста не
  // отделяется, подразделы отделяются друг от друга дополнительным
  // интервалом; заголовок не остаётся один внизу страницы.
  // Дополнительный интервал (пустая строка) ставится только перед
  // подразделом (x.x), если перед ним текст. Перед пунктами (x.x.x) и
  // заголовками, идущими сразу после другого заголовка, его нет
  set heading(numbering: "1.1", hanging-indent: 0pt)
  let structural = _STRUCTURAL
    .map(t => (t, upper(t)))
    .flatten()
    .fold(selector(heading.where(body: [])), (acc, t) => acc.or(heading.where(level: 1, body: [#t])))
  show structural: set heading(numbering: none)

  show heading: set text(size: SIZE, weight: "bold", hyphenate: false)
  show heading: set par(justify: false)
  show heading: set block(above: BLANK, below: LEADING, sticky: true)
  show heading: it => context {
    let in-appendix = _appendix.get()
    let number = if it.numbering != none {
      numbering(it.numbering, ..counter(heading).at(it.location()))
    }
    // Номер заголовка ведёт обратно к первому упоминанию (@label)
    let lbl = if it.has("label") { it.label }
    let num-link = if number != none { _back-link(lbl, number) }
    // Метка в конце заголовка: по ней следующий заголовок определяет, есть
    // ли между ними текст (иначе расстояние меньше строки текста)
    let end-mark = [#metadata(none)<gost-heading-end>]
    let prev = query(selector(<gost-heading-end>).before(it.location()))
    let after-heading = if prev.len() > 0 {
      let p = prev.last().location().position()
      let c = it.location().position()
      p.page == c.page and c.y - p.y < BLANK + PITCH / 2
    } else { false }

    if it.level == 1 and in-appendix {
      // ПРИЛОЖЕНИЕ А / (обязательное) / Наименование
      _reset-elements()
      pagebreak(weak: true)
      let status = query(selector(<gost-appendix-status>).before(it.location()))
      let status = if status.len() > 0 { status.last().value }
      block(width: 100%, {
        set align(center)
        set par(first-line-indent: 0pt)
        _back-link(lbl)[ПРИЛОЖЕНИЕ #number]
        if status != none { linebreak(); text(weight: "regular")[(#status)] }
        linebreak()
        it.body + end-mark
      })
    } else if it.level == 1 {
      // Основной раздел или структурный элемент
      if it.numbering != none and _by-section.get() { _reset-elements() }
      pagebreak(weak: true)
      block(width: 100%, align(center, par(first-line-indent: 0pt)[
        #if number != none [#num-link ]#upper(it.body)#end-mark
      ]))
    } else if it.level >= 3 and it.numbering != none and not it.outlined and it.bookmarked == false {
      // Пункт без заголовка (#punkt): номер и текст одним абзацем
      set text(weight: "regular")
      set par(justify: true)
      block(width: 100%, above: LEADING, below: LEADING, sticky: false,
        par(first-line-indent: (amount: INDENT, all: true))[#num-link #it.body])
    } else {
      // Подраздел, пункт, подпункт
      block(width: 100%, above: if it.level == 2 and not after-heading { BLANK } else { LEADING },
        par(first-line-indent: (amount: INDENT, all: true))[
          #if number != none [#num-link ]#it.body#end-mark
        ])
    }
  }

  // ---------- Перечисления (методичка п. 2.2.10, ГОСТ 7.32 п. 6.3.6) ----------
  // Маркер — тире. Нумерованный список первого порядка — «1.» (пункт с
  // прописной, в конце точка), вложенные — а), б), затем 1), 2) (пункт
  // со строчной, в конце точка с запятой). Пунктуацию пишет автор
  show list: it => _render-list(it, (n, depth) => [–])
  show enum: it => {
    // Своя нумерация, заданная через #set enum(numbering: ...), сохраняется
    let marker = if it.numbering == "1." { _gost-enum-marker } else {
      (n, depth) => numbering(it.numbering, n)
    }
    _render-list(it, marker)
  }

  // ---------- Иллюстрации (ГОСТ 7.32 п. 6.5) ----------
  // По центру, подпись под рисунком по центру без абзацного отступа:
  // «Рисунок 1 – Название» (методичка: короткое тире), без точки в конце.
  // Пустыми строками от текста не отделяются: ни методичка, ни ГОСТ 7.32
  // этого не требуют (свободные строки обязательны только у формул)
  set figure(gap: LEADING, numbering: n => _elem-number(n))
  set figure.caption(separator: [ – ])
  show figure: set block(above: LEADING, below: LEADING)
  show figure: it => block(width: 100%, breakable: true, above: LEADING, below: LEADING)[
    // Название над таблицей или листингом «прилипает» к первым строкам:
    // не остаётся одно внизу страницы, а переносится вместе с ними
    #show figure.caption: c => context {
      let lbl = if it.has("label") { it.label }
      let number = c.counter.display(c.numbering)
      let body = [#_back-link(lbl)[#c.supplement #number]#c.separator#c.body]
      if c.position == top { block(width: 100%, sticky: true, body) } else { body }
    }
    #it
  ]
  show figure.caption: set par(first-line-indent: 0pt, justify: false)
  show figure.caption: set text(hyphenate: false)
  show figure.where(kind: image): set figure(supplement: [Рисунок])
  show figure.where(kind: image): set align(center)

  // ---------- Таблицы (ГОСТ 7.32 п. 6.6) ----------
  // Название над таблицей слева без абзацного отступа: «Таблица 1 –
  // Название». При переносе на следующей странице пишется
  // «Продолжение таблицы 1» и повторяется шапка (table.header).
  // Допускается кегль меньше основного и одинарный интервал
  show figure.where(kind: table): set figure(supplement: [Таблица])
  show figure.where(kind: table): set figure.caption(position: top)
  show figure.where(kind: table): set block(breakable: true)
  show figure.caption.where(kind: table): set align(left)

  set table(stroke: 0.5pt, inset: (x: 5pt, y: 4pt), align: left + top)
  show table.cell.where(y: 0): set align(center + horizon)
  show table: it => {
    _in-table.update(true)
    set text(size: SMALL)
    set par(justify: false, first-line-indent: 0pt, leading: SMALL_LEADING, spacing: SMALL_LEADING)
    set block(spacing: SMALL_LEADING)
    it
    [#metadata(none)<gost-table-end>]
    _in-table.update(false)
  }

  // ---------- Листинги ----------
  // Оформляются как таблицы: название сверху слева, «Листинг 1 – Название»,
  // 12 пт, одинарный интервал, в рамке
  show figure.where(kind: raw): set figure(supplement: [Листинг])
  show figure.where(kind: raw): set figure.caption(position: top)
  // Листинг не разрывается, чтобы название не отрывалось от кода; код
  // длиннее страницы лучше делить на несколько листингов
  show figure.where(kind: raw): set block(breakable: false)
  show figure.caption.where(kind: raw): set align(left)
  show raw.where(block: true): it => {
    set text(size: SMALL)
    set par(justify: false, first-line-indent: 0pt, leading: SMALL_LEADING)
    block(width: 100%, stroke: 0.5pt, inset: 6pt, breakable: true, align(left, it))
  }

  // ---------- Формулы (ГОСТ 7.32 п. 6.8) ----------
  // Отдельной строкой по центру, выше и ниже — свободная строка, номер в
  // круглых скобках у правого края: (1), в приложениях (А.1)
  set math.equation(numbering: n => [(#_elem-number(n))], number-align: end + horizon, supplement: none)
  show math.equation.where(block: true): set block(above: BLANK, below: BLANK)

  // ---------- Ссылки ----------
  // @label даёт только номер: «на рисунке @img» → «на рисунке 1».
  // Чтобы кликабельным было и слово, его пишут в скобках в нужном падеже:
  // «на @img[рисунке]» → «на рисунке 1», «(@tab[Табл.])» → «(Табл. 1)»,
  // «по @eq[формуле]» → «по формуле (1)», «в @p[пункте]» → «в пункте 2.1.1».
  // Подписи «Рисунок N», «Таблица N», номера заголовков и пунктов ведут
  // обратно к первому упоминанию
  set ref(supplement: none)

  // ---------- Сноски (ГОСТ 7.32 п. 6.9) ----------
  set footnote(numbering: "1")
  set footnote.entry(separator: line(length: 30%, stroke: 0.5pt), indent: 0pt)
  show footnote.entry: set text(size: SMALL)
  show footnote.entry: set par(leading: SMALL_LEADING + 1pt, first-line-indent: (amount: INDENT, all: true))

  // ---------- Содержание (методичка п. 2.2.4, ГОСТ 7.32 п. 5.4) ----------
  // Заголовки первого и второго уровней и приложения, номера страниц
  // через отточие. Подразделы не смещаются: ни методичка, ни ГОСТ 7.32,
  // ни ГОСТ 2.105 отступов в содержании не требуют. Титульный
  // лист, задание, аннотация и само содержание не включаются
  set outline(indent: 0pt, depth: 2)
  show outline: set par(justify: false, first-line-indent: 0pt)
  show outline.entry: set block(above: LEADING, below: LEADING)
  show outline.entry: set text(weight: "regular")
  show outline.entry: it => {
    if it.element.func() == heading and _appendix.at(it.element.location()) and it.level == 1 {
      link(it.element.location(), it.indented(
        none,
        [Приложение #it.prefix() #it.element.body] + [ ] + box(width: 1fr, it.fill) + [ ] + sym.wj + it.page(),
      ))
    } else {
      it
    }
  }

  // ---------- Список использованных источников (ГОСТ 7.32 п. 6.16,
  // ГОСТ Р 7.0.5-2008, ГОСТ 7.1-2003) ----------
  // Нумерация арабскими цифрами в порядке появления ссылок в тексте,
  // ссылки в тексте в квадратных скобках: [1], [1, с. 5]
  set bibliography(
    title: [Список источников],
    style: "gost-r-705-2008-numeric",
  )
  body
}


//======================= ФУНКЦИИ =======================\\

// Структурный элемент: ВВЕДЕНИЕ, ЗАКЛЮЧЕНИЕ, АННОТАЦИЯ и т.п.
// outlined: false — не включать в содержание (реферат/аннотация)
#let head(outlined: true, body) = heading(level: 1, numbering: none, outlined: outlined, body)

#let pb() = pagebreak(weak: true)

// Содержание: в него попадают только заголовки после него
#let contents() = context {
  pagebreak(weak: true)
  [#metadata(none)<gost-numbering-start>]
  outline(title: [Содержание], target: heading.where(outlined: true).after(here()))
}

// Включает оформление приложений: #show: appendices
#let appendices(body) = {
  _appendix.update(true)
  counter(heading).update(0)
  set heading(numbering: _app-numbering)
  body
}

// Приложение: #appendix(status: "справочное")[Название]
// Статус: «обязательное», «рекомендуемое» или «справочное»
// Ссылка на приложение: #appendix(label: <app-tz>)[...], в тексте @app-tz → «А»
#let appendix(status: "обязательное", label: none, body) = {
  [#metadata(status)<gost-appendix-status>]
  if label == none { heading(level: 1, body) } else [#heading(level: 1, body)#label]
}

// Пункт без заголовка (ГОСТ 7.32 п. 6.2.3): номер и текст одним абзацем.
// #punkt(label: <p-x>)[Текст пункта...] → «1.2.1 Текст пункта...»;
// подпункт — #punkt(level: 4)[...]. Ссылка: «в @p-x[пункте]»
#let punkt(level: 3, label: none, body) = {
  let h = heading(level: level, outlined: false, bookmarked: false, body)
  if label == none { h } else [#h#label]
}

// Пояснение к формуле: #explain[$x$ — ...;]
#let explain(body) = par(first-line-indent: 0pt)[где #body]

// Шаблон подключается как пакет, поэтому строковый путь разрешался бы от
// папки пакета. Путь к файлу документа передаётся как path("...")
#let _doc-path(src, fn) = {
  if type(src) == str {
    panic(fn + ": оберните путь в path(\"" + src + "\") — строка разрешается от папки шаблона, а не документа")
  }
  src
}

// Рисунок: #img(path("assets/scheme.png"), [Название]) <label>
#let img(src, caption, width: 100%) = figure(image(_doc-path(src, "img"), width: width), caption: caption)

// Таблица: #tbl([Название], table(...)) <label>
#let tbl(caption, content) = figure(content, caption: caption, kind: table)

// Список использованных источников из .bib: #references(path("refs.bib"))
// Стандартный вывод Typst ставит номер «висячим», а по ГОСТ 7.32 номер с
// точкой пишется с абзацного отступа, перенос — от левого поля. Поэтому
// сам bibliography скрыт (он нужен для ссылок [1]), а записи выводятся
// абзацами в порядке первого упоминания в тексте
#let references(src, title: [Список источников]) = {
  head(title)
  box(height: 0pt, clip: true, bibliography(_doc-path(src, "references"), title: none))
  context {
    for key in query(cite).map(c => c.key).dedup() {
      par(cite(key, form: "full"))
    }
  }
}

// Ручной список источников (если не используется .bib):
// #sources([Иванов И. И. ...], [Петров П. П. ...])
#let sources(title: [Список источников], ..entries) = {
  head(title)
  for (i, e) in entries.pos().enumerate(start: 1) {
    par[#i. #e]
  }
}

// Электронный ресурс по ГОСТ Р 7.0.5-2008 / ГОСТ 7.1-2003
#let elsource(name, url, date) = {
  let wrapped-url = url.clusters().join("\u{200B}")
  [#name \[Электронный ресурс\]. — URL: #wrapped-url (дата обращения: #date).]
}

// Перечень сокращений / терминов: #abbreviations(("ИС", [информационная система]), ...)
#let abbreviations(title: [Перечень сокращений и обозначений], ..pairs) = {
  head(title)
  for (short, full) in pairs.pos() {
    par(first-line-indent: 0pt)[#short – #full]
  }
}

// Счётчики для реферата/аннотации
#let total-pages = context counter(page).final().first()
#let total-figures = context query(figure.where(kind: image)).len()
#let total-tables = context query(figure.where(kind: table)).len()
#let total-sources = context query(cite).map(c => c.key).dedup().len()
#let total-appendices = context query(<gost-appendix-status>).len()
#let total-chapters = context query(heading.where(level: 1)).filter(h => h.numbering != none and not _appendix.at(h.location())).len()
// Сколько листов занимают приложения
#let appendix-pages = context {
  let apps = query(heading.where(level: 1)).filter(h => _appendix.at(h.location()))
  if apps.len() == 0 { 0 } else { counter(page).final().first() - counter(page).at(apps.first().location()).first() + 1 }
}
