# 13d gate: answers on linked questions (terra)

Arms: P plain (13b, what ships), F learned facts (attributes on), W F with a wrong link on a trap. Swift's selection, attributes and marks; Opus judged blind to the arm.

## main

| Family | P covers | F covers | W covers | P abstains | F abstains |
|---|---|---|---|---|---|
| above-limit | 0/3 | 0/3 | – | – | – |
| control | 6/6 | 6/6 | – | – | – |
| direct | 9/9 | 9/9 | – | – | – |
| distractor | 3/3 | 3/3 | 3/3 | – | – |
| first_name | 3/3 | 3/3 | – | – | – |
| injection | 3/3 | 3/3 | – | – | – |
| name_change | 3/3 | 3/3 | – | – | – |
| negation | 3/3 | 3/3 | – | – | – |
| no-answer | – | – | – | 9/9 | 9/9 |
| no_answer | – | – | – | 3/3 | 3/3 |
| other-person | 6/6 | 6/6 | – | – | – |
| role_memory | 15/15 | 15/15 | 9/9 | – | – |
| role_query | 16/18 | 18/18 | – | – | – |
| spanish | 3/6 | 6/6 | – | – | – |
| superseded | 5/6 | 4/6 | – | – | – |
| two_names | 3/3 | 3/3 | 3/3 | – | – |

## astra

| Family | P covers | F covers | W covers | P abstains | F abstains |
|---|---|---|---|---|---|
| changed_role | 9/9 | 9/9 | – | – | – |
| name_to_role | 15/18 | 18/18 | – | – | – |
| no_person | 3/3 | 3/3 | – | – | – |
| role_to_name | 3/3 | 3/3 | – | – | – |
| shared_first_name | 6/6 | 6/6 | – | – | – |
| spanish_query | 3/6 | 6/6 | – | – | – |
| unanswerable | – | – | – | 3/3 | 3/3 |

## busy

| Family | P covers | F covers | W covers | P abstains | F abstains |
|---|---|---|---|---|---|
| challenge test | 18/24 | 24/24 | 23/24 | – | – |
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
  - WAIVED: main: superseded (F 4/6 vs P 5/6; 1 sample(s) waived by the author)
    - main q06 F3: Sampling, not learned facts: P and F read the same ten memories with no attributes, the requests differing only by the user's names as "the user". Terra left out the superseded date (15 January) in F2, F3 and P2; the judge was consistent. F2 and F3 differ from P2 by no learned fact; one sample (F3) is waived to bring F level with P. (author, 2026-11-20)
  - wrong_person: F resting on learned facts 0, F model's own 0, P model's own 0, P resting on learned facts 0
  - W: 0 failures in 87 answers with the trap sent (0 W answers without it, not counted); 4 claims cite the trap, 4 marked

## To read by hand

- main **q06** When is the Harbor beta?: covers P [True, False, True], F [True, False, False]
- main **q31** ¿Dónde vive mi hermana?: covers P [False, False, False], F [True, True, True]
- main **s13** What does my partner want for our anniversary?: covers P [False, True, False], F [True, True, True]
- astra **a05** ¿Qué me pidió Lucía para su cumpleaños?: covers P [False, False, False], F [True, True, True]
- astra **a16** What colour ceramics does Jordan collect?: covers P [False, False, False], F [True, True, True]
- busy **wq01** What does Lucía drink in the morning?: covers P [False, False, False], F [True, True, True], W [True, True, True]
- busy **wq03** What did Lucía ask me to get for her next birthday?: covers P [False, False, False], F [True, True, True], W [True, True, True]
- busy **wq06** What is Jordan's usual evening drink?: covers P [False, False, False], F [True, True, True], W [True, True, True]
- busy **wq10** What subtitle file format does Lucía need from me?: covers P [False, False, False], F [True, True, True], W [True, True, True]
- busy **wq11** How much can Jordan spend on new hiking boots?: covers P [False, False, False], F [True, True, True], W [True, True, True]
