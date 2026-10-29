// work_type — «Лабораторная работа», «Практическая работа», «Реферат» и т. п.
// lab_number — номер работы; "" или none — без номера.
// teachers — "должность - ФИО", несколько через ", "; "" или none — без блока «Проверил».
#let make_title(
  course: "",
  topic: "",
  lab_number: "",
  teachers: "",
  student_group: "",
  student_name: "",
  work_type: "Лабораторная работа",
  year: datetime.today().year(),
) = {
  set document(title: topic, author: student_name)
  // Основной стиль выравнивает по ширине с отступом — на титульнике это растягивает шапку
  set par(justify: false, first-line-indent: 0pt)

  let teachers = if teachers in (none, "") { () } else { teachers.split(", ") }
  let number = if lab_number in (none, "") { none } else { lab_number }

  pagebreak(weak: true)

  align(center)[
    Министерство науки и высшего образования Российской Федерации
    Федеральное государственное автономное образовательное учреждение высшего образования\
    «МОСКОВСКИЙ ПОЛИТЕХНИЧЕСКИЙ УНИВЕРСИТЕТ»\
    (МОСКОВСКИЙ ПОЛИТЕХ)
    #v(10%)
  #upper(work_type)#if number != none [ #number]\
  #if topic != "" {
    [по теме:\
    *#upper(topic)*\ ]
  }
  по курсу:\
  #course
  ]

  align(right + bottom)[
    Выполнил:\
    Студент группы #student_group\
    #student_name
    #if teachers.len() > 0 {
      [\ \ ]
      if teachers.len() == 1 [Проверил:\ ] else [Проверили:\ ]
      for teacher in teachers {
        teacher.split(" - ").join("\n")
        [\ ]
      }
    }

    #v(10%)
  ]

  align(center + bottom)[Москва #year \ \ ]

  pagebreak(weak: true)
}
