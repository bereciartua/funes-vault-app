# Spike H search ranks, round 2

Locked 2026-11-14T18:40:34: boost 0.0, others −0.1, cap None. **Changed since the lock: search.py, rank_eval.py, search_answers.py, people.py.**

## Main set (tuning) (1 reads, counts summed over reads)

| Kind | Queries | Top 3 plain → people | Top 8 | Targets worse · out of top 3 · out of top 8 · newly in top 8 | Traps in top 3 | Missed link worse than plain | Missing relation worse than plain | Wrong link puts trap in top 3 |
|---|---|---|---|---|---|---|---|---|
| bench | 30 | 25 → 25 | 30 → 30 | 0 · 0 · 0 · 0 of 71 | 0 → 0 of 0 | 0 of 4 | 0 of 1 | 0 of 0 |
| people | 17 | 16 → 16 | 17 → 17 | 0 · 0 · 0 · 0 of 18 | 3 → 3 of 9 | 0 of 13 | 0 of 9 | 4 of 9 |
| people (name only) | – | precision in top 10: 13 → 17 of 20; recall: 13 → 17 of 18 | | | | | | |
| spike-g | 34 | 32 → 32 | 33 → 34 | 0 · 0 · 0 · 1 of 37 | 0 → 0 of 0 | 0 of 5 | 0 of 2 | 0 of 0 |

Per query (best target rank, plain → people):

- main/r3 s12 [people] What wine did Tomás recommend?: 2 → 1
- main/r3 q31 [spike-g] ¿Dónde vive mi hermana?: – → 6

## Busy set, tune families (1 reads, counts summed over reads)

| Kind | Queries | Top 3 plain → people | Top 8 | Targets worse · out of top 3 · out of top 8 · newly in top 8 | Traps in top 3 | Missed link worse than plain | Missing relation worse than plain | Wrong link puts trap in top 3 |
|---|---|---|---|---|---|---|---|---|
| challenge | 6 | 5 → 5 | 6 → 6 | 0 · 0 · 0 · 0 of 6 | 6 → 4 of 27 | 1 of 6 | 1 of 6 | 7 of 27 |
| collision | 2 | 2 → 2 | 2 → 2 | 0 · 0 · 0 · 0 of 2 | 0 → 0 of 6 | 0 of 1 | 0 of 0 | 2 of 6 |
| ordinary | 6 | 6 → 6 | 6 → 6 | 0 · 0 · 0 · 0 of 7 | 1 → 0 of 10 | 0 of 7 | 0 of 2 | 4 of 10 |
| privacy | 2 | 2 → 2 | 2 → 2 | 0 · 0 · 0 · 0 of 2 | 2 → 2 of 6 | 0 of 2 | 0 of 0 | 3 of 6 |

Per query (best target rank, plain → people):

- busy/r3 wq01 [challenge] What does Lucía drink in the morning?: 2 → 1
- busy/r3 wq03 [challenge] What did Lucía ask me to get for her next birthday?: 2 → 1
- busy/r3 wq08 [challenge] ¿Qué regalo de cerámica pidió mi pareja para su próximo cumpleaños?: 8 → 5

## Busy set, test families (1 reads, counts summed over reads)

| Kind | Queries | Top 3 plain → people | Top 8 | Targets worse · out of top 3 · out of top 8 · newly in top 8 | Traps in top 3 | Missed link worse than plain | Missing relation worse than plain | Wrong link puts trap in top 3 |
|---|---|---|---|---|---|---|---|---|
| challenge | 8 | 8 → 8 | 8 → 8 | 0 · 0 · 0 · 0 of 8 | 12 → 12 of 20 | 0 of 8 | 0 of 8 | 15 of 20 |
| collision | 4 | 4 → 4 | 4 → 4 | 0 · 0 · 0 · 0 of 4 | 1 → 1 of 13 | 0 of 2 | 0 of 0 | 1 of 13 |
| name_only (name only) | – | precision in top 10: 23 → 23 of 30; recall: 23 → 23 of 113 | | | | | | |
| ordinary | 9 | 9 → 9 | 9 → 9 | 0 · 0 · 0 · 0 of 9 | 5 → 3 of 16 | 0 of 9 | 0 of 1 | 8 of 16 |
| privacy | 1 | 1 → 1 | 1 → 1 | 0 · 0 · 0 · 0 of 1 | 1 → 0 of 4 | 0 of 1 | 0 of 0 | 2 of 4 |

Per query (best target rank, plain → people):

- busy/r3 wq11 [challenge] How much can Jordan spend on new hiking boots?: 3 → 1
- busy/r3 wq13 [challenge] When does my partner want to go to Madeira?: 3 → 2
- busy/r3 wq33 [collision] What does May order at a café?: 3 → 1

## Held-out set (Astra, round 1) (1 reads, counts summed over reads)

| Kind | Queries | Top 3 plain → people | Top 8 | Targets worse · out of top 3 · out of top 8 · newly in top 8 | Traps in top 3 | Missed link worse than plain | Missing relation worse than plain | Wrong link puts trap in top 3 |
|---|---|---|---|---|---|---|---|---|
| people | 15 | 15 → 15 | 15 → 15 | 0 · 0 · 0 · 0 of 15 | 0 → 0 of 0 | 1 of 14 | 0 of 11 | 0 of 0 |
| people (name only) | – | precision in top 10: 6 → 6 of 20; recall: 6 → 6 of 6 | | | | | | |

Per query (best target rank, plain → people):

- astra/r3 a01 [people] What does Jordan drink in the evening?: 3 → 1
- astra/r3 a03 [people] Elena's evening tea?: 2 → 1
- astra/r3 a06 [people] ¿Qué toma mi hermana por la noche?: 3 → 2

Busy-set links (r3) against the author's truth: recall 157/159; named 126/126 right; sole_known 14/14 right; stated_unique 11/11 right; untrusted 6/6 right; names in the truth that match no person found: 0
