#set text(font: ("PingFang SC", "Songti SC", "Noto Serif CJK SC", "Noto Sans CJK SC", "Times New Roman"), size: 10.5pt)
#set par(justify: true, leading: 0.75em)
#set page(
  paper: "a4",
  margin: (top: 24mm, bottom: 24mm, left: 22mm, right: 22mm),
  numbering: "1",
)

#set heading(numbering: "1.")
#show heading.where(level: 1): it => {
  pagebreak(weak: true)
  block(sticky: true)[
    #set text(size: 20pt, weight: "bold")
    #it
  ]
}

#show heading.where(level: 2): it => block(sticky: true)[
  #set text(size: 15pt, weight: "semibold")
  #it
]

#show heading.where(level: 3): it => block(sticky: true)[
  #set text(size: 12pt, weight: "medium")
  #it
]

#set quote(block: true)
#set list(indent: 1.2em, spacing: 0.35em)
#set enum(indent: 1.4em, spacing: 0.35em)

#show raw.where(block: true): it => block(
  breakable: false,
  inset: (x: 8pt, y: 8pt),
  radius: 4pt,
  fill: luma(245),
  stroke: (paint: luma(220), thickness: 0.5pt),
  it,
)
