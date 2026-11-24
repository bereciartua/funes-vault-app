# Spike T results

Prompts sha256 15335ddeb8c9; stores: work13 and workt gold, mixed recorded (H3b).

| engine | arm | split | decidable: right / n | decidable: wrong | undecidable: not sure / n | undecidable: wrong | negatives: triggered / n |
|---|---|---|---|---|---|---|---|
| haiku | 1 | dev | 54 / 54 | 0 | 4 / 5 | 1 | 0 (answered 0) / 16 |
| haiku | 1 | held | 67 / 67 | 0 | 28 / 38 | 10 | 1 (answered 0) / 38 |
| haiku | 2 | dev | 32 / 54 | 0 | 5 / 5 | 0 | 0 (answered 0) / 16 |
| haiku | 2 | held | 9 / 67 | 0 | 38 / 38 | 0 | 0 (answered 0) / 38 |
| haiku | 2+1 | dev | 49 / 54 | 0 | 5 / 5 | 0 | 0 (answered 0) / 16 |
| haiku | 2+1 | held | 58 / 67 | 0 | 34 / 38 | 4 | 0 (answered 0) / 38 |
| haiku | 3.0 | dev | 38 / 54 | 0 | 5 / 5 | 0 | 0 (answered 0) / 16 |
| haiku | 3.0 | held | 40 / 67 | 1 | 38 / 38 | 0 | 2 (answered 0) / 38 |
| haiku | 3.0+1 | dev | 38 / 54 | 0 | 5 / 5 | 0 | 0 (answered 0) / 16 |
| haiku | 3.0+1 | held | 42 / 67 | 1 | 37 / 38 | 1 | 2 (answered 0) / 38 |
| haiku | 3.1 | dev | 38 / 54 | 0 | 5 / 5 | 0 | 0 (answered 0) / 16 |
| haiku | 3.1 | held | 42 / 67 | 1 | 38 / 38 | 0 | 0 (answered 0) / 38 |
| haiku | 3.1+1 | dev | 38 / 54 | 0 | 5 / 5 | 0 | 0 (answered 0) / 16 |
| haiku | 3.1+1 | held | 42 / 67 | 1 | 37 / 38 | 1 | 0 (answered 0) / 38 |
| haiku | 4 | dev | 54 / 54 | 0 | 4 / 5 | 1 | 0 (answered 0) / 16 |
| haiku | 4 | held | 67 / 67 | 0 | 29 / 38 | 9 | 0 (answered 0) / 38 |
| terra | 1 | dev | 52 / 54 | 0 | 5 / 5 | 0 | 0 (answered 0) / 16 |
| terra | 1 | held | 67 / 67 | 0 | 24 / 38 | 14 | 0 (answered 0) / 38 |
| terra | 2 | dev | 32 / 54 | 0 | 5 / 5 | 0 | 0 (answered 0) / 16 |
| terra | 2 | held | 9 / 67 | 0 | 38 / 38 | 0 | 0 (answered 0) / 38 |
| terra | 2+1 | dev | 49 / 54 | 0 | 5 / 5 | 0 | 0 (answered 0) / 16 |
| terra | 2+1 | held | 58 / 67 | 0 | 30 / 38 | 8 | 0 (answered 0) / 38 |
| terra | 3.0 | dev | 38 / 54 | 0 | 5 / 5 | 0 | 0 (answered 0) / 16 |
| terra | 3.0 | held | 42 / 67 | 0 | 37 / 38 | 1 | 0 (answered 0) / 38 |
| terra | 3.0+1 | dev | 38 / 54 | 0 | 5 / 5 | 0 | 0 (answered 0) / 16 |
| terra | 3.0+1 | held | 43 / 67 | 0 | 37 / 38 | 1 | 0 (answered 0) / 38 |
| terra | 3.1 | dev | 38 / 54 | 0 | 5 / 5 | 0 | 0 (answered 0) / 16 |
| terra | 3.1 | held | 42 / 67 | 0 | 35 / 38 | 3 | 0 (answered 0) / 38 |
| terra | 3.1+1 | dev | 38 / 54 | 0 | 5 / 5 | 0 | 0 (answered 0) / 16 |
| terra | 3.1+1 | held | 43 / 67 | 0 | 35 / 38 | 3 | 0 (answered 0) / 38 |
| terra | 4 | dev | 54 / 54 | 0 | 4 / 5 | 1 | 0 (answered 0) / 16 |
| terra | 4 | held | 67 / 67 | 0 | 24 / 38 | 14 | 0 (answered 0) / 38 |

## Latency (ms, p50 / p95)

- haiku arm 1: 4307 / 6708 (218 calls)
- haiku arm 3: 2637 / 3659 (436 calls)
- haiku arm 4: 4383 / 6591 (218 calls)
- terra arm 1: 5254 / 8975 (218 calls)
- terra arm 3: 3447 / 5093 (436 calls)
- terra arm 4: 5598 / 9865 (218 calls)

## Wrong answers and triggered negatives

### haiku arm 1 (12)
- work13 w05 n3 (held, no_answer): What was the very first employer I ever had?
- mixed x01 n4 (held, negative): Who went over the quarterly plan with me at Cinder Arc?
- mixed x05 q2 (dev, before): Where did I work before North Kestrel?
- workt t01 q3 (held, before): Where did I work before Cedar Metrics?
- workt t02 q4 (held, current): What's my current workplace?
- workt t03 q3 (held, before): ¿Qué empleo tuve justo antes de Solera?
- workt t05 q3 (held, before): Which day job did I have before Bracken Health?
- workt t05 q5 (held, current): What organization do I currently work at?
- workt t07 q3 (held, before): Which employer preceded Alder Press Ltd.?
- workt t08 q5 (held, current): ¿Dónde trabajo ahora?
- workt t10 q3 (held, before): ¿Qué empleo principal tuve antes de Canto?
- workt t10 q5 (held, current): ¿Cuál es mi trabajo actual?
### haiku arm 2+1 (4)
- work13 w05 n3 (held, no_answer): What was the very first employer I ever had?
- workt t07 q3 (held, before): Which employer preceded Alder Press Ltd.?
- workt t08 q5 (held, current): ¿Dónde trabajo ahora?
- workt t10 q3 (held, before): ¿Qué empleo principal tuve antes de Canto?
### haiku arm 3.0 (3)
- work13 w07 n4 (held, role_in_stint): Had I become test lead by 2019 at Hush Audio, or was I still a junior tester?
- work13 w12 n4 (held, role_in_stint): Al terminar mi etapa en Prisma, ¿seguía de auxiliar o ya era responsable de archivo?
- mixed x09 n2 (held, year): Which of my 2020 jobs had Karim Rook as my manager?
### haiku arm 3.0+1 (4)
- work13 w05 n3 (held, no_answer): What was the very first employer I ever had?
- work13 w07 n4 (held, role_in_stint): Had I become test lead by 2019 at Hush Audio, or was I still a junior tester?
- work13 w12 n4 (held, role_in_stint): Al terminar mi etapa en Prisma, ¿seguía de auxiliar o ya era responsable de archivo?
- mixed x09 n2 (held, year): Which of my 2020 jobs had Karim Rook as my manager?
### haiku arm 3.1 (1)
- mixed x09 n2 (held, year): Which of my 2020 jobs had Karim Rook as my manager?
### haiku arm 3.1+1 (2)
- work13 w05 n3 (held, no_answer): What was the very first employer I ever had?
- mixed x09 n2 (held, year): Which of my 2020 jobs had Karim Rook as my manager?
### haiku arm 4 (10)
- work13 w05 n3 (held, no_answer): What was the very first employer I ever had?
- mixed x05 q2 (dev, before): Where did I work before North Kestrel?
- workt t01 q3 (held, before): Where did I work before Cedar Metrics?
- workt t02 q4 (held, current): What's my current workplace?
- workt t03 q3 (held, before): ¿Qué empleo tuve justo antes de Solera?
- workt t05 q3 (held, before): Which day job did I have before Bracken Health?
- workt t05 q5 (held, current): What organization do I currently work at?
- workt t08 q5 (held, current): ¿Dónde trabajo ahora?
- workt t10 q3 (held, before): ¿Qué empleo principal tuve antes de Canto?
- workt t10 q5 (held, current): ¿Cuál es mi trabajo actual?
### terra arm 1 (14)
- work13 w05 n3 (held, no_answer): What was the very first employer I ever had?
- mixed x05 n3 (held, year): Where exactly was I employed on 1 February 2016?
- workt t01 q3 (held, before): Where did I work before Cedar Metrics?
- workt t03 q5 (held, current): ¿Cuál es mi empresa actual?
- workt t04 q3 (held, before): What job came immediately before Cobalt House?
- workt t04 q4 (held, after): Which employer did I join after Ash Harbor?
- workt t04 q5 (held, year): Who employed me on June 15, 2019?
- workt t05 q3 (held, before): Which day job did I have before Bracken Health?
- workt t05 q5 (held, current): What organization do I currently work at?
- workt t06 q5 (held, year): ¿Quién me empleaba el 20 de septiembre de 2016?
- workt t08 q5 (held, current): ¿Dónde trabajo ahora?
- workt t09 q3 (held, before): What was my work immediately before Juniper Dock?
- workt t09 q4 (held, after): Which job did I take after leaving Juniper Dock?
- workt t10 q3 (held, before): ¿Qué empleo principal tuve antes de Canto?
### terra arm 2+1 (8)
- work13 w05 n3 (held, no_answer): What was the very first employer I ever had?
- mixed x05 n3 (held, year): Where exactly was I employed on 1 February 2016?
- workt t04 q3 (held, before): What job came immediately before Cobalt House?
- workt t04 q5 (held, year): Who employed me on June 15, 2019?
- workt t06 q5 (held, year): ¿Quién me empleaba el 20 de septiembre de 2016?
- workt t08 q5 (held, current): ¿Dónde trabajo ahora?
- workt t09 q3 (held, before): What was my work immediately before Juniper Dock?
- workt t10 q3 (held, before): ¿Qué empleo principal tuve antes de Canto?
### terra arm 3.0 (1)
- workt t08 q5 (held, current): ¿Dónde trabajo ahora?
### terra arm 3.0+1 (1)
- workt t08 q5 (held, current): ¿Dónde trabajo ahora?
### terra arm 3.1 (3)
- workt t02 q4 (held, current): What's my current workplace?
- workt t05 q5 (held, current): What organization do I currently work at?
- workt t08 q5 (held, current): ¿Dónde trabajo ahora?
### terra arm 3.1+1 (3)
- workt t02 q4 (held, current): What's my current workplace?
- workt t05 q5 (held, current): What organization do I currently work at?
- workt t08 q5 (held, current): ¿Dónde trabajo ahora?
### terra arm 4 (15)
- work13 w03 n3 (held, year): Can you pin down my employer on New Year's Day 2016?
- work13 w05 n3 (held, no_answer): What was the very first employer I ever had?
- mixed x05 q2 (dev, before): Where did I work before North Kestrel?
- mixed x05 n3 (held, year): Where exactly was I employed on 1 February 2016?
- workt t01 q3 (held, before): Where did I work before Cedar Metrics?
- workt t02 q4 (held, current): What's my current workplace?
- workt t03 q3 (held, before): ¿Qué empleo tuve justo antes de Solera?
- workt t04 q5 (held, year): Who employed me on June 15, 2019?
- workt t05 q3 (held, before): Which day job did I have before Bracken Health?
- workt t05 q5 (held, current): What organization do I currently work at?
- workt t06 q5 (held, year): ¿Quién me empleaba el 20 de septiembre de 2016?
- workt t07 q3 (held, before): Which employer preceded Alder Press Ltd.?
- workt t07 q4 (held, after): What job followed Alder Press?
- workt t08 q5 (held, current): ¿Dónde trabajo ahora?
- workt t10 q3 (held, before): ¿Qué empleo principal tuve antes de Canto?

## By family (all splits)

- haiku arm 1 concurrent_slots: answered_right 8, quiet 2, right 30, told 8, wrong 6
- haiku arm 1 gap: answered_right 8, quiet 2, right 26, told 10, wrong 1
- haiku arm 1 import: answered_right 10, quiet 4, right 43, told 18, wrong 4
- haiku arm 1 other: answered_right 16, quiet 9, right 38, told 5, triggered 1, wrong 1
- haiku arm 1 precision: answered_right 23, quiet 5, right 83, told 27, wrong 10
- haiku arm 1 rehire: answered_right 8, quiet 2, right 28, told 6, wrong 7
- haiku arm 1 renamed: answered_right 7, quiet 2, right 39, told 18, wrong 9
- haiku arm 1 spanish: answered_right 5, quiet 3, right 26, told 11, wrong 5
- haiku arm 1 undated_order: answered_right 6, quiet 2, right 23, told 12, wrong 2
- haiku arm 1 untrusted_end: answered_right 12, quiet 2, right 39, told 14, wrong 5
- haiku arm 2 concurrent_slots: miss 20, quiet 10, right 8, told 5, told_decidable 2, told_no_intent 9
- haiku arm 2 gap: miss 15, quiet 10, right 5, right_gap 2, told 4, told_decidable 4, told_no_intent 7
- haiku arm 2 import: miss 16, quiet 14, right 19, right_gap 1, told 13, told_decidable 7, told_no_intent 9
- haiku arm 2 other: miss 19, quiet 26, right 15, told 2, told_decidable 4, told_no_intent 4
- haiku arm 2 precision: miss 47, quiet 28, right 24, right_gap 2, told 19, told_decidable 10, told_no_intent 18
- haiku arm 2 rehire: miss 14, quiet 10, right 10, told 11, told_decidable 4, told_no_intent 2
- haiku arm 2 renamed: miss 18, quiet 9, right 15, told 16, told_decidable 6, told_no_intent 11
- haiku arm 2 spanish: miss 12, quiet 8, right 10, right_gap 1, told 7, told_decidable 3, told_no_intent 9
- haiku arm 2 undated_order: miss 12, quiet 8, right 3, right_gap 2, told 7, told_decidable 6, told_no_intent 7
- haiku arm 2 untrusted_end: miss 24, quiet 14, right 7, right_gap 1, told 12, told_decidable 7, told_no_intent 7
- haiku arm 2+1 concurrent_slots: quiet 10, right 28, told 12, told_decidable 2, wrong 2
- haiku arm 2+1 gap: quiet 10, right 20, right_gap 2, told 10, told_decidable 4, wrong 1
- haiku arm 2+1 import: quiet 14, right 35, right_gap 1, told 20, told_decidable 7, wrong 2
- haiku arm 2+1 other: quiet 26, right 34, told 6, told_decidable 4
- haiku arm 2+1 precision: quiet 28, right 71, right_gap 2, told 33, told_decidable 10, wrong 4
- haiku arm 2+1 rehire: quiet 10, right 24, told 11, told_decidable 4, wrong 2
- haiku arm 2+1 renamed: quiet 9, right 33, told 24, told_decidable 6, wrong 3
- haiku arm 2+1 spanish: quiet 8, right 22, right_gap 1, told 14, told_decidable 3, wrong 2
- haiku arm 2+1 undated_order: quiet 8, right 15, right_gap 2, told 13, told_decidable 6, wrong 1
- haiku arm 2+1 untrusted_end: quiet 14, right 31, right_gap 1, told 17, told_decidable 7, wrong 2
- haiku arm 3.0 concurrent_slots: quiet 10, right 21, told 14, told_decidable 9
- haiku arm 3.0 gap: quiet 10, right 13, right_gap 4, told 9, told_decidable 9, told_gap 1, told_no_intent 1
- haiku arm 3.0 import: miss 1, quiet 12, right 26, right_gap 3, told 20, told_decidable 13, told_gap 1, told_no_intent 1, triggered 2
- haiku arm 3.0 other: miss 1, quiet 26, right 27, told 5, told_decidable 9, told_no_intent 1, wrong 1
- haiku arm 3.0 precision: miss 1, quiet 26, right 47, right_gap 4, told 35, told_decidable 31, told_gap 1, told_no_intent 1, triggered 2
- haiku arm 3.0 rehire: quiet 9, right 13, right_gap 1, told 13, told_decidable 14, triggered 1
- haiku arm 3.0 renamed: miss 1, quiet 7, right 23, told 27, told_decidable 15, triggered 2
- haiku arm 3.0 spanish: miss 1, quiet 7, right 16, right_gap 1, told 16, told_decidable 8, triggered 1
- haiku arm 3.0 undated_order: quiet 8, right 10, right_gap 3, told 12, told_decidable 10, told_gap 1, told_no_intent 1
- haiku arm 3.0 untrusted_end: quiet 14, right 16, right_gap 1, told 18, told_decidable 22, told_gap 1
- haiku arm 3.0+1 concurrent_slots: quiet 10, right 21, told 14, told_decidable 9
- haiku arm 3.0+1 gap: quiet 10, right 13, right_gap 4, told 9, told_decidable 9, told_gap 1, wrong 1
- haiku arm 3.0+1 import: quiet 12, right 27, right_gap 3, told 20, told_decidable 13, told_gap 1, triggered 2, wrong 1
- haiku arm 3.0+1 other: quiet 26, right 28, told 6, told_decidable 9, wrong 1
- haiku arm 3.0+1 precision: quiet 26, right 48, right_gap 4, told 35, told_decidable 31, told_gap 1, triggered 2, wrong 1
- haiku arm 3.0+1 rehire: quiet 9, right 13, right_gap 1, told 13, told_decidable 14, triggered 1
- haiku arm 3.0+1 renamed: quiet 7, right 24, told 27, told_decidable 15, triggered 2
- haiku arm 3.0+1 spanish: quiet 7, right 17, right_gap 1, told 16, told_decidable 8, triggered 1
- haiku arm 3.0+1 undated_order: quiet 8, right 10, right_gap 3, told 12, told_decidable 10, told_gap 1, wrong 1
- haiku arm 3.0+1 untrusted_end: quiet 14, right 16, right_gap 1, told 18, told_decidable 22, told_gap 1
- haiku arm 3.1 concurrent_slots: quiet 10, right 21, told 14, told_decidable 9
- haiku arm 3.1 gap: quiet 10, right 13, right_gap 4, told 9, told_decidable 9, told_gap 1, told_no_intent 1
- haiku arm 3.1 import: quiet 14, right 27, right_gap 3, told 20, told_decidable 13, told_gap 1, told_no_intent 1
- haiku arm 3.1 other: quiet 26, right 28, told 5, told_decidable 9, told_no_intent 1, wrong 1
- haiku arm 3.1 precision: quiet 28, right 48, right_gap 4, told 35, told_decidable 31, told_gap 1, told_no_intent 1
- haiku arm 3.1 rehire: quiet 10, right 13, right_gap 1, told 13, told_decidable 14
- haiku arm 3.1 renamed: quiet 9, right 24, told 27, told_decidable 15
- haiku arm 3.1 spanish: quiet 8, right 17, right_gap 1, told 16, told_decidable 8
- haiku arm 3.1 undated_order: quiet 8, right 10, right_gap 3, told 12, told_decidable 10, told_gap 1, told_no_intent 1
- haiku arm 3.1 untrusted_end: quiet 14, right 16, right_gap 1, told 18, told_decidable 22, told_gap 1
- haiku arm 3.1+1 concurrent_slots: quiet 10, right 21, told 14, told_decidable 9
- haiku arm 3.1+1 gap: quiet 10, right 13, right_gap 4, told 9, told_decidable 9, told_gap 1, wrong 1
- haiku arm 3.1+1 import: quiet 14, right 27, right_gap 3, told 20, told_decidable 13, told_gap 1, wrong 1
- haiku arm 3.1+1 other: quiet 26, right 28, told 6, told_decidable 9, wrong 1
- haiku arm 3.1+1 precision: quiet 28, right 48, right_gap 4, told 35, told_decidable 31, told_gap 1, wrong 1
- haiku arm 3.1+1 rehire: quiet 10, right 13, right_gap 1, told 13, told_decidable 14
- haiku arm 3.1+1 renamed: quiet 9, right 24, told 27, told_decidable 15
- haiku arm 3.1+1 spanish: quiet 8, right 17, right_gap 1, told 16, told_decidable 8
- haiku arm 3.1+1 undated_order: quiet 8, right 10, right_gap 3, told 12, told_decidable 10, told_gap 1, wrong 1
- haiku arm 3.1+1 untrusted_end: quiet 14, right 16, right_gap 1, told 18, told_decidable 22, told_gap 1
- haiku arm 4 concurrent_slots: answered_right 8, quiet 2, right 30, told 8, wrong 6
- haiku arm 4 gap: answered_right 8, quiet 2, right 26, told 10, wrong 1
- haiku arm 4 import: answered_right 10, quiet 4, right 43, told 19, wrong 3
- haiku arm 4 other: answered_right 17, quiet 9, right 38, told 5, wrong 1
- haiku arm 4 precision: answered_right 23, quiet 5, right 83, told 28, wrong 9
- haiku arm 4 rehire: answered_right 8, quiet 2, right 28, told 7, wrong 6
- haiku arm 4 renamed: answered_right 7, quiet 2, right 39, told 19, wrong 8
- haiku arm 4 spanish: answered_right 5, quiet 3, right 26, told 11, wrong 5
- haiku arm 4 undated_order: answered_right 6, quiet 2, right 23, told 12, wrong 2
- haiku arm 4 untrusted_end: answered_right 12, quiet 2, right 39, told 15, wrong 4
- terra arm 1 concurrent_slots: answered_right 8, quiet 2, right 30, told 10, wrong 4
- terra arm 1 gap: answered_right 8, quiet 2, right 26, told 4, wrong 7
- terra arm 1 import: answered_right 10, quiet 4, right 42, told 12, told_decidable 1, told_no_intent 1, wrong 9
- terra arm 1 other: answered_right 18, quiet 8, right 37, told 5, told_decidable 1, wrong 1
- terra arm 1 precision: answered_right 23, quiet 5, right 82, told 23, told_decidable 1, told_no_intent 1, wrong 13
- terra arm 1 rehire: answered_right 8, quiet 2, right 27, told 7, told_decidable 1, told_no_intent 1, wrong 5
- terra arm 1 renamed: answered_right 7, quiet 2, right 38, told 19, told_decidable 1, told_no_intent 1, wrong 7
- terra arm 1 spanish: answered_right 5, quiet 3, right 26, told 12, wrong 4
- terra arm 1 undated_order: answered_right 6, quiet 2, right 23, told 6, wrong 8
- terra arm 1 untrusted_end: answered_right 12, quiet 2, right 39, told 10, told_no_intent 1, wrong 8
- terra arm 2 concurrent_slots: miss 20, quiet 10, right 8, told 5, told_decidable 2, told_no_intent 9
- terra arm 2 gap: miss 15, quiet 10, right 5, right_gap 2, told 4, told_decidable 4, told_no_intent 7
- terra arm 2 import: miss 16, quiet 14, right 19, right_gap 1, told 13, told_decidable 7, told_no_intent 9
- terra arm 2 other: miss 19, quiet 26, right 15, told 2, told_decidable 4, told_no_intent 4
- terra arm 2 precision: miss 47, quiet 28, right 24, right_gap 2, told 19, told_decidable 10, told_no_intent 18
- terra arm 2 rehire: miss 14, quiet 10, right 10, told 11, told_decidable 4, told_no_intent 2
- terra arm 2 renamed: miss 18, quiet 9, right 15, told 16, told_decidable 6, told_no_intent 11
- terra arm 2 spanish: miss 12, quiet 8, right 10, right_gap 1, told 7, told_decidable 3, told_no_intent 9
- terra arm 2 undated_order: miss 12, quiet 8, right 3, right_gap 2, told 7, told_decidable 6, told_no_intent 7
- terra arm 2 untrusted_end: miss 24, quiet 14, right 7, right_gap 1, told 12, told_decidable 7, told_no_intent 7
- terra arm 2+1 concurrent_slots: quiet 10, right 28, told 12, told_decidable 2, wrong 2
- terra arm 2+1 gap: quiet 10, right 20, right_gap 2, told 6, told_decidable 4, wrong 5
- terra arm 2+1 import: quiet 14, right 35, right_gap 1, told 16, told_decidable 7, told_no_intent 1, wrong 5
- terra arm 2+1 other: quiet 26, right 34, told 5, told_decidable 4, wrong 1
- terra arm 2+1 precision: quiet 28, right 71, right_gap 2, told 29, told_decidable 10, told_no_intent 1, wrong 7
- terra arm 2+1 rehire: quiet 10, right 24, told 11, told_decidable 4, told_no_intent 1, wrong 1
- terra arm 2+1 renamed: quiet 9, right 33, told 23, told_decidable 6, told_no_intent 1, wrong 3
- terra arm 2+1 spanish: quiet 8, right 22, right_gap 1, told 13, told_decidable 3, wrong 3
- terra arm 2+1 undated_order: quiet 8, right 15, right_gap 2, told 9, told_decidable 6, wrong 5
- terra arm 2+1 untrusted_end: quiet 14, right 31, right_gap 1, told 14, told_decidable 7, told_no_intent 1, wrong 4
- terra arm 3.0 concurrent_slots: quiet 10, right 21, told 13, told_decidable 9, wrong 1
- terra arm 3.0 gap: quiet 10, right 13, right_gap 4, told 9, told_decidable 9, told_gap 2
- terra arm 3.0 import: quiet 14, right 27, right_gap 3, told 20, told_decidable 13, told_gap 2
- terra arm 3.0 other: miss 1, quiet 26, right 28, told 5, told_decidable 9, told_no_intent 1
- terra arm 3.0 precision: quiet 28, right 48, right_gap 4, told 33, told_decidable 31, told_gap 2, told_no_intent 1, wrong 1
- terra arm 3.0 rehire: quiet 10, right 13, right_gap 1, told 13, told_decidable 14
- terra arm 3.0 renamed: quiet 9, right 24, told 25, told_decidable 15, told_no_intent 1, wrong 1
- terra arm 3.0 spanish: quiet 8, right 17, right_gap 1, told 15, told_decidable 8, wrong 1
- terra arm 3.0 undated_order: quiet 8, right 10, right_gap 3, told 12, told_decidable 10, told_gap 2
- terra arm 3.0 untrusted_end: quiet 14, right 16, right_gap 1, told 17, told_decidable 22, told_gap 1, told_no_intent 1
- terra arm 3.0+1 concurrent_slots: quiet 10, right 21, told 13, told_decidable 9, wrong 1
- terra arm 3.0+1 gap: quiet 10, right 13, right_gap 4, told 9, told_decidable 9, told_gap 2
- terra arm 3.0+1 import: quiet 14, right 27, right_gap 3, told 20, told_decidable 13, told_gap 2
- terra arm 3.0+1 other: quiet 26, right 29, told 6, told_decidable 9
- terra arm 3.0+1 precision: quiet 28, right 48, right_gap 4, told 34, told_decidable 31, told_gap 2, wrong 1
- terra arm 3.0+1 rehire: quiet 10, right 13, right_gap 1, told 13, told_decidable 14
- terra arm 3.0+1 renamed: quiet 9, right 24, told 26, told_decidable 15, wrong 1
- terra arm 3.0+1 spanish: quiet 8, right 17, right_gap 1, told 15, told_decidable 8, wrong 1
- terra arm 3.0+1 undated_order: quiet 8, right 10, right_gap 3, told 12, told_decidable 10, told_gap 2
- terra arm 3.0+1 untrusted_end: quiet 14, right 16, right_gap 1, told 18, told_decidable 22, told_gap 1
- terra arm 3.1 concurrent_slots: quiet 10, right 21, told 11, told_decidable 9, wrong 3
- terra arm 3.1 gap: quiet 10, right 13, right_gap 4, told 9, told_decidable 9, told_gap 2
- terra arm 3.1 import: quiet 14, right 27, right_gap 3, told 20, told_decidable 13, told_gap 2
- terra arm 3.1 other: miss 1, quiet 26, right 28, told 5, told_decidable 9, told_no_intent 1
- terra arm 3.1 precision: quiet 28, right 48, right_gap 4, told 31, told_decidable 31, told_gap 2, told_no_intent 1, wrong 3
- terra arm 3.1 rehire: quiet 10, right 13, right_gap 1, told 12, told_decidable 14, wrong 1
- terra arm 3.1 renamed: quiet 9, right 24, told 23, told_decidable 15, told_no_intent 1, wrong 3
- terra arm 3.1 spanish: quiet 8, right 17, right_gap 1, told 14, told_decidable 8, wrong 2
- terra arm 3.1 undated_order: quiet 8, right 10, right_gap 3, told 12, told_decidable 10, told_gap 2
- terra arm 3.1 untrusted_end: quiet 14, right 16, right_gap 1, told 17, told_decidable 22, told_gap 1, told_no_intent 1
- terra arm 3.1+1 concurrent_slots: quiet 10, right 21, told 11, told_decidable 9, wrong 3
- terra arm 3.1+1 gap: quiet 10, right 13, right_gap 4, told 9, told_decidable 9, told_gap 2
- terra arm 3.1+1 import: quiet 14, right 27, right_gap 3, told 20, told_decidable 13, told_gap 2
- terra arm 3.1+1 other: quiet 26, right 29, told 6, told_decidable 9
- terra arm 3.1+1 precision: quiet 28, right 48, right_gap 4, told 32, told_decidable 31, told_gap 2, wrong 3
- terra arm 3.1+1 rehire: quiet 10, right 13, right_gap 1, told 12, told_decidable 14, wrong 1
- terra arm 3.1+1 renamed: quiet 9, right 24, told 24, told_decidable 15, wrong 3
- terra arm 3.1+1 spanish: quiet 8, right 17, right_gap 1, told 14, told_decidable 8, wrong 2
- terra arm 3.1+1 undated_order: quiet 8, right 10, right_gap 3, told 12, told_decidable 10, told_gap 2
- terra arm 3.1+1 untrusted_end: quiet 14, right 16, right_gap 1, told 18, told_decidable 22, told_gap 1
- terra arm 4 concurrent_slots: answered_right 8, quiet 2, right 30, told 9, wrong 5
- terra arm 4 gap: answered_right 8, quiet 2, right 26, told 7, told_no_intent 1, wrong 3
- terra arm 4 import: answered_right 10, quiet 4, right 43, told 13, told_no_intent 2, wrong 7
- terra arm 4 other: answered_right 18, quiet 8, right 38, told 4, wrong 2
- terra arm 4 precision: answered_right 23, quiet 5, right 83, told 22, told_no_intent 2, wrong 13
- terra arm 4 rehire: answered_right 8, quiet 2, right 28, told 5, told_no_intent 1, wrong 7
- terra arm 4 renamed: answered_right 7, quiet 2, right 39, told 15, told_no_intent 1, wrong 11
- terra arm 4 spanish: answered_right 5, quiet 3, right 26, told 11, wrong 5
- terra arm 4 undated_order: answered_right 6, quiet 2, right 23, told 9, told_no_intent 1, wrong 4
- terra arm 4 untrusted_end: answered_right 12, quiet 2, right 39, told 11, told_no_intent 1, wrong 7
