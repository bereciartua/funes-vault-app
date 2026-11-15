# Spike H answers, round 2 (astra set, links from r3)

Each query answered 3 times per arm: A plain, B people ranking, C1 hint, C2 hint + prompt sentence, C3 + bridges, W a wrong hint on a trap, M the answer memory's hint removed. Judged by Opus 5.5 without the arm.

## people (16 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 38/45 | 43/45 | 45/45 | 0/0 | 0/0 | 0/0 | 38/42 |
| No-answer queries abstained right | 3/3 | 3/3 | 3/3 | 0/0 | 0/0 | 0/0 | 0/0 |
| Claims: fact | 38 | 43 | 35 | 0 | 0 | 0 | 35 |
| Claims: true_other | 0 | 0 | 0 | 0 | 0 | 0 | 2 |
| Claims: hedged | 0 | 0 | 10 | 0 | 0 | 0 | 3 |
| Claims: denies_true | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: unsupported | 1 | 2 | 0 | 0 | 0 | 0 | 4 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 13 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) |

## To read by hand

- **a01** What does Jordan drink in the evening?: covers A 0/3, B 3/3, C1 3/3, M 3/3
  - A2 denies_true: You know Jordan likes specialty tea, but your memories do not specify what Jordan drinks in the evening. — judge: It says the vault doesn't record Jordan's evening drink, but the vault says rooibos.
- **a03** Elena's evening tea?: covers A 0/3, B 3/3, C1 3/3, M 3/3
- **a05** ¿Qué me pidió Lucía para su cumpleaños?: covers A 2/3, B 1/3, C1 3/3, M 1/3
  - A2 unsupported: Lucía te pidió ovillos de lana amarilla para su próximo cumpleaños, porque quiere tejer una bufanda. — judge: Quote says 'mi hermana' but never names Lucía.
  - B2 unsupported: Lucía te pidió ovillos de lana amarilla para su próximo cumpleaños, porque quiere tejer una bufanda. — judge: Quote never names Lucía.
  - B1 unsupported: Lucía te pidió ovillos de lana amarilla para su próximo cumpleaños, porque quiere tejer una bufanda. — judge: Quote never names Lucía.
  - M1 unsupported: Lucía te pidió ovillos de lana amarilla para su cumpleaños, porque quiere tejer una bufanda. — judge: The birthday-date quote doesn't show Lucía is the sister.
  - M3 unsupported: Lucía te pidió ovillos de lana amarilla para su cumpleaños, porque quiere tejer una bufanda. — judge: Quote never names Lucía.
- **a16** What colour ceramics does Jordan collect?: covers A 3/3, B 3/3, C1 3/3, M 1/3
  - M3 unsupported: Jordan collects blue ceramics, especially small bowls. — judge: The quote only says 'the user's partner'. Nothing in it, and no note, names Jordan.
  - M2 unsupported: Jordan collects blue ceramics, especially small bowls. — judge: The quote only says 'the user's partner'. Nothing in it, and no note, names Jordan.