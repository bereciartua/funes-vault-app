# Phase 13b gate: search with links on

Fixtures only; learned facts from the spike's r3 reads through `FactStore.apply`; no model calls. Pass: 0 targets worse, 0 out of the top 3, 0 out of the top 10.

## main · bge · shipped uses

PASS: 81 queries, 126 targets: worse 0 · out of top 3 0 · out of top 10 0 · better 2; matched 25 queries, 153 admitted, 37 demoted
- s12 p16: 2 → 1 (top 3 with links: p16, p15, p02)
- q31 m042: – → 6 (top 3 with links: p11, m006, p19)

## main · bge · every declared use

PASS: 81 queries, 126 targets: worse 0 · out of top 3 0 · out of top 10 0 · better 2; matched 25 queries, 153 admitted, 37 demoted
- s12 p16: 2 → 1 (top 3 with links: p16, p15, p02)
- q31 m042: – → 6 (top 3 with links: p11, m006, p19)

## main · qwen · shipped uses

PASS: 81 queries, 126 targets: worse 0 · out of top 3 0 · out of top 10 0 · better 4; matched 25 queries, 153 admitted, 103 demoted
- s01 p01: 7 → 6 (top 3 with links: p07, m152, m042)
- s02 p03: 2 → 1 (top 3 with links: p03, m040, m135)
- bq16 m044: 2 → 1 (top 3 with links: m044, p16, m040)
- bq20 m043: 9 → 7 (top 3 with links: p19, p05, m006)

## main · qwen · every declared use

PASS: 81 queries, 126 targets: worse 0 · out of top 3 0 · out of top 10 0 · better 4; matched 25 queries, 153 admitted, 103 demoted
- s01 p01: 7 → 6 (top 3 with links: p07, m152, m042)
- s02 p03: 2 → 1 (top 3 with links: p03, m040, m135)
- bq16 m044: 2 → 1 (top 3 with links: m044, p16, m040)
- bq20 m043: 9 → 7 (top 3 with links: p19, p05, m006)

## main · qwen-uncalibrated · shipped uses

PASS: 81 queries, 126 targets: worse 0 · out of top 3 0 · out of top 10 0 · better 4; matched 25 queries, 153 admitted, 38 demoted
- s01 p01: 7 → 6 (top 3 with links: p07, m152, m042)
- s02 p03: 2 → 1 (top 3 with links: p03, m040, m135)
- bq16 m044: 2 → 1 (top 3 with links: m044, p16, m040)
- bq20 m043: 9 → 7 (top 3 with links: p19, p05, m006)

## main · qwen-uncalibrated · every declared use

PASS: 81 queries, 126 targets: worse 0 · out of top 3 0 · out of top 10 0 · better 4; matched 25 queries, 153 admitted, 38 demoted
- s01 p01: 7 → 6 (top 3 with links: p07, m152, m042)
- s02 p03: 2 → 1 (top 3 with links: p03, m040, m135)
- bq16 m044: 2 → 1 (top 3 with links: m044, p16, m040)
- bq20 m043: 9 → 7 (top 3 with links: p19, p05, m006)

## main · qwen-as-cloud · shipped uses

PASS: 81 queries, 126 targets: worse 0 · out of top 3 0 · out of top 10 0 · better 4; matched 25 queries, 153 admitted, 103 demoted
- s01 p01: 8 → 7 (top 3 with links: p07, m152, m042)
- s02 p03: 3 → 1 (top 3 with links: p03, m135, m040)
- bq16 m044: 2 → 1 (top 3 with links: m044, p16, m040)
- bq20 m043: 11 → 9 (top 3 with links: p19, p05, m006)

## main · qwen-as-cloud · every declared use

PASS: 81 queries, 126 targets: worse 0 · out of top 3 0 · out of top 10 0 · better 4; matched 25 queries, 153 admitted, 103 demoted
- s01 p01: 8 → 7 (top 3 with links: p07, m152, m042)
- s02 p03: 3 → 1 (top 3 with links: p03, m135, m040)
- bq16 m044: 2 → 1 (top 3 with links: m044, p16, m040)
- bq20 m043: 11 → 9 (top 3 with links: p19, p05, m006)

## astra · bge · shipped uses

PASS: 15 queries, 15 targets: worse 0 · out of top 3 0 · out of top 10 0 · better 2; matched 17 queries, 92 admitted, 62 demoted
- a01 h01: 3 → 1 (top 3 with links: h01, h02, h04)
- a03 h04: 2 → 1 (top 3 with links: h04, h14, h02)

## astra · bge · every declared use

PASS: 15 queries, 15 targets: worse 0 · out of top 3 0 · out of top 10 0 · better 2; matched 17 queries, 92 admitted, 62 demoted
- a01 h01: 3 → 1 (top 3 with links: h01, h02, h04)
- a03 h04: 2 → 1 (top 3 with links: h04, h14, h02)

## astra · qwen · shipped uses

PASS: 15 queries, 15 targets: worse 0 · out of top 3 0 · out of top 10 0 · better 2; matched 17 queries, 92 admitted, 120 demoted
- a02 h02: 2 → 1 (top 3 with links: h02, h04, h14)
- a03 h04: 2 → 1 (top 3 with links: h04, h14, h12)

## astra · qwen · every declared use

PASS: 15 queries, 15 targets: worse 0 · out of top 3 0 · out of top 10 0 · better 2; matched 17 queries, 92 admitted, 120 demoted
- a02 h02: 2 → 1 (top 3 with links: h02, h04, h14)
- a03 h04: 2 → 1 (top 3 with links: h04, h14, h12)

## astra · qwen-uncalibrated · shipped uses

PASS: 15 queries, 15 targets: worse 0 · out of top 3 0 · out of top 10 0 · better 2; matched 17 queries, 92 admitted, 59 demoted
- a02 h02: 2 → 1 (top 3 with links: h02, h04, h14)
- a03 h04: 2 → 1 (top 3 with links: h04, h14, h12)

## astra · qwen-uncalibrated · every declared use

PASS: 15 queries, 15 targets: worse 0 · out of top 3 0 · out of top 10 0 · better 2; matched 17 queries, 92 admitted, 59 demoted
- a02 h02: 2 → 1 (top 3 with links: h02, h04, h14)
- a03 h04: 2 → 1 (top 3 with links: h04, h14, h12)

## astra · qwen-as-cloud · shipped uses

PASS: 15 queries, 15 targets: worse 0 · out of top 3 0 · out of top 10 0 · better 2; matched 17 queries, 92 admitted, 120 demoted
- a02 h02: 2 → 1 (top 3 with links: h02, h04, h14)
- a03 h04: 2 → 1 (top 3 with links: h04, h14, h12)

## astra · qwen-as-cloud · every declared use

PASS: 15 queries, 15 targets: worse 0 · out of top 3 0 · out of top 10 0 · better 2; matched 17 queries, 92 admitted, 120 demoted
- a02 h02: 2 → 1 (top 3 with links: h02, h04, h14)
- a03 h04: 2 → 1 (top 3 with links: h04, h14, h12)

## busy · bge · shipped uses

PASS: 38 queries, 39 targets: worse 0 · out of top 3 0 · out of top 10 0 · better 6; matched 41 queries, 1572 admitted, 655 demoted
- wq01 w001: 2 → 1 (top 3 with links: w001, w101, w033)
- wq03 w002: 2 → 1 (top 3 with links: w002, w018, w035)
- wq08 w057: 8 → 5 (top 3 with links: w066, w062, w001)
- wq11 w063: 3 → 1 (top 3 with links: w063, w088, w120)
- wq13 w062: 3 → 2 (top 3 with links: w123, w062, w124)
- wq33 w129: 3 → 2 (top 3 with links: w105, w129, w145)

## busy · bge · every declared use

PASS: 38 queries, 39 targets: worse 0 · out of top 3 0 · out of top 10 0 · better 6; matched 41 queries, 1572 admitted, 655 demoted
- wq01 w001: 2 → 1 (top 3 with links: w001, w101, w033)
- wq03 w002: 2 → 1 (top 3 with links: w002, w018, w035)
- wq08 w057: 8 → 5 (top 3 with links: w066, w062, w001)
- wq11 w063: 3 → 1 (top 3 with links: w063, w088, w120)
- wq13 w062: 3 → 2 (top 3 with links: w123, w062, w124)
- wq33 w129: 3 → 2 (top 3 with links: w105, w129, w145)

## busy · qwen · shipped uses

FAIL: 38 queries, 39 targets: worse 1 · out of top 3 0 · out of top 10 0 · better 4; matched 41 queries, 1572 admitted, 1630 demoted
- wq03 w002: 2 → 1 (top 3 with links: w002, w018, w042)
- wq07 w060: 3 → 1 (top 3 with links: w060, w076, w099)
- wq11 w063: 4 → 2 (top 3 with links: w088, w063, w120)
- wq14 w010: 2 → 1 (top 3 with links: w010, w125, w126)
- wq15 m044: 2 → 3 (top 3 with links: w002, w018, m044)

## busy · qwen · every declared use

FAIL: 38 queries, 39 targets: worse 1 · out of top 3 0 · out of top 10 0 · better 4; matched 41 queries, 1572 admitted, 1630 demoted
- wq03 w002: 2 → 1 (top 3 with links: w002, w018, w042)
- wq07 w060: 3 → 1 (top 3 with links: w060, w076, w099)
- wq11 w063: 4 → 2 (top 3 with links: w088, w063, w120)
- wq14 w010: 2 → 1 (top 3 with links: w010, w125, w126)
- wq15 m044: 2 → 3 (top 3 with links: w002, w018, m044)

## busy · qwen-uncalibrated · shipped uses

FAIL: 38 queries, 39 targets: worse 1 · out of top 3 0 · out of top 10 0 · better 4; matched 41 queries, 1572 admitted, 317 demoted
- wq03 w002: 2 → 1 (top 3 with links: w002, w018, w042)
- wq07 w060: 3 → 1 (top 3 with links: w060, w076, w099)
- wq11 w063: 4 → 2 (top 3 with links: w088, w063, w120)
- wq14 w010: 2 → 1 (top 3 with links: w010, w125, w126)
- wq15 m044: 2 → 3 (top 3 with links: w002, w018, m044)

## busy · qwen-uncalibrated · every declared use

FAIL: 38 queries, 39 targets: worse 1 · out of top 3 0 · out of top 10 0 · better 4; matched 41 queries, 1572 admitted, 317 demoted
- wq03 w002: 2 → 1 (top 3 with links: w002, w018, w042)
- wq07 w060: 3 → 1 (top 3 with links: w060, w076, w099)
- wq11 w063: 4 → 2 (top 3 with links: w088, w063, w120)
- wq14 w010: 2 → 1 (top 3 with links: w010, w125, w126)
- wq15 m044: 2 → 3 (top 3 with links: w002, w018, m044)

## busy · qwen-as-cloud · shipped uses

FAIL: 38 queries, 39 targets: worse 1 · out of top 3 0 · out of top 10 0 · better 4; matched 41 queries, 1572 admitted, 1612 demoted
- wq03 w002: 2 → 1 (top 3 with links: w002, w018, w042)
- wq07 w060: 3 → 1 (top 3 with links: w060, w076, w099)
- wq11 w063: 4 → 2 (top 3 with links: w088, w063, w120)
- wq14 w010: 2 → 1 (top 3 with links: w010, w125, w126)
- wq15 m044: 2 → 3 (top 3 with links: w002, w018, m044)

## busy · qwen-as-cloud · every declared use

FAIL: 38 queries, 39 targets: worse 1 · out of top 3 0 · out of top 10 0 · better 4; matched 41 queries, 1572 admitted, 1612 demoted
- wq03 w002: 2 → 1 (top 3 with links: w002, w018, w042)
- wq07 w060: 3 → 1 (top 3 with links: w060, w076, w099)
- wq11 w063: 4 → 2 (top 3 with links: w088, w063, w120)
- wq14 w010: 2 → 1 (top 3 with links: w010, w125, w126)
- wq15 m044: 2 → 3 (top 3 with links: w002, w018, m044)

## work · bge · shipped uses

PASS: 31 queries, 69 targets: worse 0 · out of top 3 0 · out of top 10 0 · better 0; matched 0 queries, 0 admitted, 0 demoted

## work · bge · every declared use

FAIL: 31 queries, 69 targets: worse 10 · out of top 3 2 · out of top 10 2 · better 6; matched 20 queries, 187 admitted, 428 demoted
- w01 j001: 18 → 12 (top 3 with links: j003, j026, j010)
- w03 j010: 3 → 4 (top 3 with links: j026, j013, j012)
- w03 j006: 41 → 49 (top 3 with links: j026, j013, j012)
- w07 j021: 19 → 27 (top 3 with links: j020, j016, j013)
- w10 j026: 3 → 1 (top 3 with links: j026, j037, j034)
- w10 j025: 58 → 68 (top 3 with links: j026, j037, j034)
- w10 j037: 4 → 2 (top 3 with links: j026, j037, j034)
- w12 j036: 18 → 31 (top 3 with links: j037, j033, j004)
- w12 j038: 36 → 17 (top 3 with links: j037, j033, j004)
- w14 j043: 55 → 120 (top 3 with links: j045, j048, m182)
- w14 j047: 8 → 21 (top 3 with links: j045, j048, m182)
- w18 j029: 8 → 12 (top 3 with links: j021, j027, j025)
- w21 j049: 5 → 7 (top 3 with links: j057, m102, j056)
- w21 j050: 3 → 5 (top 3 with links: j057, m102, j056)
- w21 j056: 4 → 3 (top 3 with links: j057, m102, j056)
- w24 j027: 7 → 4 (top 3 with links: j022, j023, j024)

## work · qwen · shipped uses

PASS: 31 queries, 69 targets: worse 0 · out of top 3 0 · out of top 10 0 · better 0; matched 0 queries, 0 admitted, 0 demoted

## work · qwen · every declared use

FAIL: 31 queries, 69 targets: worse 13 · out of top 3 1 · out of top 10 1 · better 8; matched 20 queries, 187 admitted, 617 demoted
- w01 j001: 18 → 14 (top 3 with links: j003, j026, j010)
- w02 j001: 22 → 31 (top 3 with links: j036, j003, j006)
- w03 j006: 32 → 47 (top 3 with links: j012, j011, j010)
- w04 j010: 6 → 7 (top 3 with links: j012, j013, j016)
- w04 j006: 18 → 23 (top 3 with links: j012, j013, j016)
- w07 j017: 15 → 12 (top 3 with links: j020, j010, j012)
- w07 j020: 2 → 1 (top 3 with links: j020, j010, j012)
- w07 j021: 36 → 51 (top 3 with links: j020, j010, j012)
- w10 j026: 2 → 1 (top 3 with links: j026, j037, j003)
- w10 j025: 47 → 72 (top 3 with links: j026, j037, j003)
- w10 j037: 4 → 2 (top 3 with links: j026, j037, j003)
- w12 j036: 5 → 6 (top 3 with links: j037, j033, j010)
- w12 j038: 38 → 20 (top 3 with links: j037, j033, j010)
- w14 j043: 45 → 82 (top 3 with links: j045, j041, j049)
- w14 j047: 8 → 16 (top 3 with links: j045, j041, j049)
- w16 j045: 3 → 2 (top 3 with links: j036, j045, j018)
- w16 j043: 25 → 39 (top 3 with links: j036, j045, j018)
- w18 j029: 13 → 14 (top 3 with links: j021, j027, j025)
- w21 j049: 2 → 6 (top 3 with links: j056, m102, j057)
- w21 j050: 7 → 9 (top 3 with links: j056, m102, j057)
- w24 j027: 9 → 5 (top 3 with links: j022, j023, j024)

## work · qwen-uncalibrated · shipped uses

PASS: 31 queries, 69 targets: worse 0 · out of top 3 0 · out of top 10 0 · better 0; matched 0 queries, 0 admitted, 0 demoted

## work · qwen-uncalibrated · every declared use

FAIL: 31 queries, 69 targets: worse 7 · out of top 3 1 · out of top 10 1 · better 8; matched 20 queries, 187 admitted, 156 demoted
- w01 j001: 18 → 14 (top 3 with links: j003, j026, j010)
- w04 j010: 6 → 7 (top 3 with links: j012, j013, j016)
- w07 j017: 15 → 12 (top 3 with links: j020, j010, j012)
- w07 j020: 2 → 1 (top 3 with links: j020, j010, j012)
- w07 j021: 21 → 22 (top 3 with links: j020, j010, j012)
- w10 j026: 2 → 1 (top 3 with links: j026, j037, j003)
- w10 j037: 4 → 2 (top 3 with links: j026, j037, j003)
- w12 j036: 5 → 6 (top 3 with links: j037, j033, j010)
- w12 j038: – → 20 (top 3 with links: j037, j033, j010)
- w14 j047: 8 → 12 (top 3 with links: j045, j041, j049)
- w16 j045: 3 → 2 (top 3 with links: j036, j045, j018)
- w18 j029: 13 → 14 (top 3 with links: j021, j027, j025)
- w21 j049: 2 → 6 (top 3 with links: j056, m102, j057)
- w21 j050: 7 → 9 (top 3 with links: j056, m102, j057)
- w24 j027: 9 → 5 (top 3 with links: j022, j023, j024)

## work · qwen-as-cloud · shipped uses

PASS: 31 queries, 69 targets: worse 0 · out of top 3 0 · out of top 10 0 · better 0; matched 0 queries, 0 admitted, 0 demoted

## work · qwen-as-cloud · every declared use

FAIL: 31 queries, 69 targets: worse 13 · out of top 3 1 · out of top 10 0 · better 8; matched 20 queries, 187 admitted, 617 demoted
- w01 j001: 18 → 14 (top 3 with links: j003, j026, j010)
- w02 j001: 24 → 30 (top 3 with links: j036, j003, j006)
- w03 j006: 33 → 48 (top 3 with links: j012, j011, j010)
- w04 j010: 6 → 7 (top 3 with links: j012, j016, j013)
- w04 j006: 18 → 23 (top 3 with links: j012, j016, j013)
- w07 j017: 15 → 12 (top 3 with links: j020, j010, j012)
- w07 j020: 2 → 1 (top 3 with links: j020, j010, j012)
- w07 j021: 37 → 53 (top 3 with links: j020, j010, j012)
- w10 j026: 2 → 1 (top 3 with links: j026, j037, j003)
- w10 j025: 50 → 72 (top 3 with links: j026, j037, j003)
- w10 j037: 4 → 2 (top 3 with links: j026, j037, j003)
- w12 j036: 5 → 6 (top 3 with links: j037, j033, j010)
- w12 j038: 40 → 20 (top 3 with links: j037, j033, j010)
- w14 j043: 65 → 99 (top 3 with links: j045, m182, m164)
- w14 j047: 11 → 22 (top 3 with links: j045, m182, m164)
- w16 j045: 3 → 2 (top 3 with links: j036, j045, j026)
- w16 j043: 25 → 37 (top 3 with links: j036, j045, j026)
- w18 j029: 14 → 15 (top 3 with links: j021, j027, j025)
- w21 j049: 2 → 6 (top 3 with links: j056, m102, j057)
- w21 j050: 7 → 9 (top 3 with links: j056, m102, j057)
- w24 j027: 9 → 5 (top 3 with links: j022, j023, j024)
