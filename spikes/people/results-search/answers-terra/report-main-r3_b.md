# Spike H answers, round 2 (main set, links from r3)

Each query answered 3 times per arm: A plain, B people ranking, C1 hint, C2 hint + prompt sentence, C3 + bridges, W a wrong hint on a trap, M the answer memory's hint removed. Judged by Opus 5.5 without the arm.

## people (18 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 51/51 | 51/51 | 51/51 | 0/0 | 0/0 | 15/15 | 27/27 |
| No-answer queries abstained right | 3/3 | 3/3 | 3/3 | 0/0 | 0/0 | 0/0 | 0/0 |
| Claims: fact | 47 | 50 | 43 | 0 | 0 | 5 | 24 |
| Claims: true_other | 5 | 7 | 9 | 0 | 0 | 0 | 0 |
| Claims: hedged | 0 | 0 | 7 | 0 | 0 | 9 | 0 |
| Claims: denies_true | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 3 | 0 |
| Claims: unsupported | 4 | 1 | 1 | 0 | 0 | 0 | 3 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 10 (0) | 0 (0) | 0 (0) | 9 (6) | 0 (0) |

## spike-g (5 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 9/12 | 12/12 | 12/12 | 0/0 | 0/0 | 0/0 | 12/12 |
| No-answer queries abstained right | 3/3 | 3/3 | 3/3 | 0/0 | 0/0 | 0/0 | 0/0 |
| Claims: fact | 12 | 13 | 15 | 0 | 0 | 0 | 15 |
| Claims: true_other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: hedged | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: denies_true | 2 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: unsupported | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) |

## To read by hand

- **s05** When is Lucía visiting?: covers A 3/3, B 3/3, C1 3/3, M 3/3
  - A1 unsupported: Lucía is visiting Lisbon from 18 to 26 December with her kids. — judge: Quote only says 'my sister'; nothing ties it to Lucía
  - A3 unsupported: Lucía is visiting Lisbon from 18 to 26 December with her kids. — judge: Quote only says 'my sister'; nothing ties it to Lucía
  - M1 unsupported: Lucía is visiting Lisbon from 18 to 26 December with her kids. — judge: Quote only says 'my sister'; nothing ties it to Lucía
  - M2 unsupported: Lucía is visiting Lisbon from 18 to 26 December with her kids. — judge: Quote only says 'my sister'; nothing ties it to Lucía
  - M3 unsupported: Lucía is visiting Lisbon from 18 to 26 December with her kids. — judge: Quote only says 'my sister'; nothing ties it to Lucía
- **s17** How does my manager want status updates?: covers A 3/3, B 3/3, C1 3/3
  - A1 unsupported: You should send an async written summary rather than book a call; for the weekly update, post it in Slack before Friday noon as three bullet points. — judge: States the Slack/Friday/bullets fact, but merges Priya's async preference into the manager's instructions. Nothing shows Priya is the manager.
  - A2 unsupported: You should send an async written summary in Slack before Friday noon, formatted as three bullet points. — judge: Treats Priya's async-summary preference as part of the manager's request without support.
  - B1 unsupported: Your manager wants a written, asynchronous weekly update in Slack before Friday noon, formatted as three bullet points. — judge: Says the manager wants a written, asynchronous update, which only comes from Priya's memory. Nothing shows Priya is the manager.
  - C11 unsupported: Your manager wants a written, asynchronous weekly update in Slack before Friday noon, formatted as three bullet points. — judge: Says the manager wants a written, asynchronous update, which only comes from Priya's memory. Nothing shows Priya is the manager.
- **s18** What's Erik's coffee order?: covers A 3/3, B 3/3, C1 3/3, W 3/3, M 3/3
  - W3 wrong_person: An older note instead lists an oat-milk flat white with no sugar; if unavailable, a black americano. — judge: It presents the oat-milk order as Erik's, but that memory is about someone else.
  - W2 wrong_person: You have two conflicting recorded orders for Erik: a double espresso with no milk, and an oat-milk flat white with no sugar (black americano if oat milk is unavailable). — judge: It gets the espresso right but also calls the oat-milk order Erik's, which is about someone else.
  - W1 wrong_person: An older note instead lists an oat-milk flat white with no sugar, or a black Americano if oat milk is unavailable. — judge: It presents the oat-milk order as Erik's, but that memory is about someone else.
- **q31** ¿Dónde vive mi hermana?: covers A 0/3, B 3/3, C1 3/3, M 3/3
  - A1 denies_true: Tu hermana te pidió dulce de leche y alfajores de maicena cuando viajes a Montevideo, pero las memorias no indican dónde vive. — judge: Says the memories don't show where she lives, but the vault does
  - A2 denies_true: No tienes una nota que indique dónde vive tu hermana; solo consta que te pidió dulces para cuando viajes a Montevideo. — judge: Says no note shows where she lives, but the vault does