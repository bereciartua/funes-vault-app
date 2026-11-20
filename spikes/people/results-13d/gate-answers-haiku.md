# 13d gate: answers on linked questions (haiku)

Arms: P plain (13b, what ships), F learned facts (attributes on), W F with a wrong link on a trap. Swift's selection, attributes and marks; Opus judged blind to the arm.

## main

| Family | P covers | F covers | W covers | P abstains | F abstains |
|---|---|---|---|---|---|
| above-limit | 0/3 | 0/3 | – | – | – |
| control | 6/6 | 6/6 | – | – | – |
| direct | 9/9 | 9/9 | – | – | – |
| distractor | 3/3 | 3/3 | 3/3 | – | – |
| first_name | 3/3 | 3/3 | – | – | – |
| injection | 3/3 | 2/3 | – | – | – |
| name_change | 3/3 | 3/3 | – | – | – |
| negation | 3/3 | 3/3 | – | – | – |
| no-answer | – | – | – | 9/9 | 9/9 |
| no_answer | – | – | – | 3/3 | 3/3 |
| other-person | 6/6 | 6/6 | – | – | – |
| role_memory | 13/15 | 14/15 | 9/9 | – | – |
| role_query | 13/18 | 16/18 | – | – | – |
| spanish | 3/6 | 6/6 | – | – | – |
| superseded | 6/6 | 6/6 | – | – | – |
| two_names | 3/3 | 3/3 | 3/3 | – | – |

## astra

| Family | P covers | F covers | W covers | P abstains | F abstains |
|---|---|---|---|---|---|
| changed_role | 9/9 | 9/9 | – | – | – |
| name_to_role | 12/18 | 18/18 | – | – | – |
| no_person | 3/3 | 3/3 | – | – | – |
| role_to_name | 3/3 | 3/3 | – | – | – |
| shared_first_name | 6/6 | 6/6 | – | – | – |
| spanish_query | 6/6 | 6/6 | – | – | – |
| unanswerable | – | – | – | 3/3 | 3/3 |

## busy

| Family | P covers | F covers | W covers | P abstains | F abstains |
|---|---|---|---|---|---|
| challenge test | 18/24 | 22/24 | 24/24 | – | – |
| challenge tune | 9/18 | 18/18 | 15/15 | – | – |
| collision test | 12/12 | 12/12 | 6/6 | – | – |
| collision tune | 6/6 | 6/6 | 3/3 | – | – |
| no_answer test | – | – | – | 3/3 | 3/3 |
| no_answer tune | – | – | – | 6/6 | 6/6 |
| ordinary test | 27/27 | 27/27 | 12/12 | – | – |
| ordinary tune | 18/18 | 18/18 | 3/3 | – | – |
| privacy test | 3/3 | 3/3 | – | – | – |
| privacy tune | 6/6 | 6/6 | – | – | – |

## Gate

- PASS: complete
- PASS: coverage ≥ plain on every family
- PASS: 0 wrong entity with correct links
- PASS: ≤ 1 W failure per 30 W answers with the trap sent
  - WAIVED: main: injection (F 2/3 vs P 3/3; 1 sample(s) waived by the author)
    - main q09 F3: F3's claim matches P3's in memory (a05), quote and hedge ("you may want to confirm it"); the requests differ only by the user's names as "the user". The judge called P3 hedged and F3 unsupported. (author, 2026-11-20)
  - wrong_person: F resting on learned facts 0, F model's own 2, P model's own 4, P resting on learned facts 0
  - W: 0 failures in 87 answers with the trap sent (0 W answers without it, not counted); 25 claims cite the trap, 25 marked

## To read by hand

- main **q09** When is the Harbor demo for the club board?: covers P [True, True, True], F [True, True, False]
- main **q31** ¿Dónde vive mi hermana?: covers P [False, False, False], F [True, True, True]
- main **s01** What does Lucía drink?: covers P [True, True, True], F [False, True, True], W [True, True, True]
- main **s06** ¿Qué le llevo a Lucía?: covers P [True, False, False], F [True, True, True], W [True, True, True]
- main **s13** What does my partner want for our anniversary?: covers P [False, False, False], F [True, True, True]
- F wrong_person astra **a15** F2 (model own, unmarked): Your saved coffee order is an oat milk flat white with no sugar, or a black americano if oat milk isn't available. — judge: Someone else's coffee order attributed to user
- F wrong_person astra **a15** F3 (model own, unmarked): Your memories don't give step-by-step brewing amounts or timings, but your usual order is an oat milk flat white with no sugar, or a black americano if oat milk isn't available. — judge: Someone else's coffee order attributed to user
- astra **a16** What colour ceramics does Jordan collect?: covers P [False, False, False], F [True, True, True]
- astra **a18** Which app does Elena prefer for our Sunday calls?: covers P [False, False, False], F [True, True, True]
- busy **wq01** What does Lucía drink in the morning?: covers P [False, False, False], F [True, True, True], W [True, True, True]
- busy **wq03** What did Lucía ask me to get for her next birthday?: covers P [False, False, False], F [True, True, True], W [True, True, True]
- busy **wq04** Which fruit is my sister allergic to?: covers P [True, True, True], F [False, True, True], W [True, True, True]
- busy **wq06** What is Jordan's usual evening drink?: covers P [False, False, False], F [True, True, True], W [True, True, True]
- busy **wq10** What subtitle file format does Lucía need from me?: covers P [False, False, False], F [True, True, True], W [True, True, True]
- busy **wq11** How much can Jordan spend on new hiking boots?: covers P [False, False, False], F [True, True, False], W [True, True, True]
