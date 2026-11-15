# Spike H answers, round 2 (busy set, links from r3)

Each query answered 3 times per arm: A plain, B people ranking, C1 hint, C2 hint + prompt sentence, C3 + bridges, W a wrong hint on a trap, M the answer memory's hint removed. Judged by Opus 5.5 without the arm.

## challenge test (8 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 18/24 | 18/24 | 24/24 | 0/0 | 0/0 | 23/24 | 19/24 |
| Claims: fact | 18 | 18 | 18 | 0 | 0 | 15 | 18 |
| Claims: true_other | 0 | 0 | 0 | 0 | 0 | 0 | 1 |
| Claims: hedged | 0 | 0 | 6 | 0 | 0 | 8 | 1 |
| Claims: denies_true | 2 | 1 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 2 | 0 |
| Claims: unsupported | 0 | 0 | 0 | 0 | 0 | 0 | 4 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 6 (0) | 0 (0) | 0 (0) | 6 (1) | 0 (0) |

## challenge tune (6 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 9/18 | 9/18 | 18/18 | 0/0 | 0/0 | 18/18 | 9/18 |
| Claims: fact | 9 | 9 | 6 | 0 | 0 | 4 | 8 |
| Claims: true_other | 1 | 1 | 0 | 0 | 0 | 0 | 0 |
| Claims: hedged | 0 | 0 | 12 | 0 | 0 | 14 | 1 |
| Claims: denies_true | 4 | 6 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: unsupported | 1 | 2 | 0 | 0 | 0 | 0 | 9 |
| Claims: other | 2 | 1 | 0 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 12 (0) | 0 (0) | 0 (0) | 12 (6) | 0 (0) |

## collision test (4 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 12/12 | 12/12 | 12/12 | 0/0 | 0/0 | 3/3 | 3/3 |
| Claims: fact | 12 | 12 | 12 | 0 | 0 | 3 | 3 |
| Claims: true_other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: hedged | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: denies_true | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: unsupported | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) |

## collision tune (2 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 6/6 | 6/6 | 6/6 | 0/0 | 0/0 | 3/3 | 3/3 |
| Claims: fact | 6 | 6 | 6 | 0 | 0 | 3 | 3 |
| Claims: true_other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: hedged | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: denies_true | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: unsupported | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) |

## no_answer test (1 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 |
| No-answer queries abstained right | 3/3 | 3/3 | 3/3 | 0/0 | 0/0 | 3/3 | 0/0 |
| Claims: fact | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: true_other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: hedged | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: denies_true | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: unsupported | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) |

## no_answer tune (2 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 |
| No-answer queries abstained right | 6/6 | 6/6 | 6/6 | 0/0 | 0/0 | 6/6 | 0/0 |
| Claims: fact | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: true_other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: hedged | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: denies_true | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: unsupported | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) |

## ordinary test (9 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 27/27 | 27/27 | 27/27 | 0/0 | 0/0 | 26/27 | 27/27 |
| Claims: fact | 27 | 27 | 27 | 0 | 0 | 26 | 27 |
| Claims: true_other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: hedged | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: denies_true | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: unsupported | 0 | 0 | 0 | 0 | 0 | 1 | 0 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) |

## ordinary tune (6 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 18/18 | 18/18 | 18/18 | 0/0 | 0/0 | 9/9 | 15/15 |
| Claims: fact | 18 | 18 | 18 | 0 | 0 | 9 | 15 |
| Claims: true_other | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: hedged | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: denies_true | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: unsupported | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 3 (0) | 0 (0) | 0 (0) | 3 (0) | 0 (0) |

## privacy test (1 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 3/3 | 3/3 | 3/3 | 0/0 | 0/0 | 0/0 | 0/0 |
| Claims: fact | 3 | 3 | 3 | 0 | 0 | 0 | 0 |
| Claims: true_other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: hedged | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: denies_true | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: unsupported | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) |

## privacy tune (2 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 6/6 | 6/6 | 6/6 | 0/0 | 0/0 | 0/0 | 0/0 |
| Claims: fact | 6 | 6 | 6 | 0 | 0 | 0 | 0 |
| Claims: true_other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: hedged | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: denies_true | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: unsupported | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) |

## To read by hand

- **wq01** What does Lucía drink in the morning?: covers A 0/3, B 0/3, C1 3/3, W 3/3, M 1/3
  - A3 denies_true: No tienes una nota que diga qué bebe Lucía por la mañana; sí consta que cultiva menta en su balcón. — judge: It says there is no note on Lucía's morning drink, but there is one.
  - B2 denies_true: No tienes una nota que diga qué bebe Lucía por la mañana; la única bebida matinal registrada para tu hermana es mate amargo sin azúcar. — judge: It says there is no note about Lucía, but the note about the sister is about her.
  - B1 denies_true: No tienes una nota que indique qué bebe Lucía por la mañana; solo consta que tu hermana toma mate amargo sin azúcar. — judge: It denies the vault has a note about Lucía, but the sister's note is about her.
  - M2 unsupported: Probablemente Lucía toma mate amargo por la mañana, sin azúcar. — judge: The quote says only 'my sister', not Lucía, and there is no inferred-link note to connect them.
  - M1 unsupported: Tu hermana Lucía toma mate amargo por la mañana, sin azúcar. — judge: The quote doesn't name Lucía, and there is no note linking the sister to her.
- **wq03** What did Lucía ask me to get for her next birthday?: covers A 0/3, B 0/3, C1 3/3, W 3/3, M 0/3
  - A1 denies_true: Lucía asked you for a lemon cake recipe for her birthday lunch; the memories do not identify a requested item for her next birthday. — judge: Says the vault has no requested present, but it does
  - B1 denies_true: Your notes say your sister asked you for linocut tools for her next birthday, but they do not identify her as Lucía. — judge: Doubts that the sister is Lucía
  - B2 denies_true: Your sister asked you for linocut tools for her next birthday, but the memory does not identify her as Lucía. — judge: Denies that the sister is Lucía
  - B3 unsupported: Lucía asked you for linocut tools for her next birthday. — judge: The quote doesn't name Lucía and the link isn't marked as inferred
  - M2 unsupported: You should get Lucía linocut tools for her next birthday. — judge: The quote doesn't name Lucía and the link isn't marked as inferred
  - M1 unsupported: You were asked for linocut tools for your sister’s next birthday; Funes infers this was Lucía. — judge: Not marked as inferred by the app; the quote doesn't name Lucía
  - M3 unsupported: Funes infers your sister Lucía asked you for linocut tools for her next birthday. — judge: Not marked as inferred by the app; the quote doesn't name Lucía
- **wq04** Which fruit is my sister allergic to?: covers A 3/3, B 3/3, C1 3/3, W 3/3, M 3/3
  - W3 wrong_person: Separately, Funes infers that Nia Okafor is your sister, and that she is allergic to oranges. — judge: Nia is a trap, not the sister
- **wq06** What is Jordan's usual evening drink?: covers A 0/3, B 0/3, C1 3/3, W 3/3, M 0/3
  - A2 unsupported: Jordan's usual evening drink is roasted barley tea. — judge: The quote says only 'my partner', and nothing in the answer ties it to Jordan
  - A3 denies_true: You have noted that Jordan likes specialty tea, but your memories do not specify Jordan's usual evening drink. — judge: Says the drink isn't specified, but the vault specifies it
  - A1 denies_true: You have not recorded Jordan's usual evening drink; you only note that Jordan likes specialty tea. — judge: Says the drink isn't recorded, but the vault records it
  - B2 denies_true: Jordan’s usual evening drink is not specified, though you note that Jordan likes specialty tea. — judge: Says the drink isn't recorded, but the vault records roasted barley tea
  - B1 denies_true: Jordan’s usual evening drink is not explicitly recorded; your notes only say that Jordan likes specialty tea. — judge: Says the drink isn't recorded, but the vault records it
  - B3 unsupported: Jordan’s usual evening drink is roasted barley tea. — judge: The quote doesn't name Jordan
  - M1 unsupported: Your partner Jordan’s usual evening drink is roasted barley tea. — judge: The quote doesn't name Jordan
  - M2 unsupported: Jordan’s usual evening drink is roasted barley tea. — judge: The quote doesn't name Jordan
  - M3 unsupported: Jordan’s usual evening drink is roasted barley tea. — judge: Neither quote shows that the partner is Jordan
- **wq07** How late does Jordan sleep after a night shift?: covers A 3/3, B 3/3, C1 3/3, W 3/3, M 2/3
  - M3 unsupported: Jordan sleeps until 13:00 Lisbon time after a night shift. — judge: Quote says only 'my partner' and nothing links that to Jordan
- **wq10** What subtitle file format does Lucía need from me?: covers A 0/3, B 0/3, C1 3/3, W 3/3, M 0/3
  - M1 unsupported: You need to send Lucía subtitle files in SRT format, not burned into the video. — judge: The quote says only 'my sister'. It never names Lucía, and there is no inferred note.
  - M3 unsupported: You need to send Lucía subtitle files in SRT format, not burned into the video. — judge: The quote doesn't name Lucía, and there is no inferred note.
- **wq11** How much can Jordan spend on new hiking boots?: covers A 0/3, B 0/3, C1 3/3, W 3/3, M 1/3
  - A3 denies_true: You have a €120 budget for your partner’s new hiking boots, but the memories do not explicitly identify your partner as Jordan. — judge: Doubts that the memory is about Jordan, but it is.
  - A2 denies_true: You have a €120 budget for new hiking boots, but the memory does not explicitly identify this budget as Jordan’s. — judge: Doubts that the budget is Jordan's, but it is.
  - B2 denies_true: You have a €120 budget for your partner’s new hiking boots, but the memories do not explicitly identify your partner as Jordan. — judge: Doubts that the memory is about Jordan, but it is.
  - M2 unsupported: Jordan can spend up to €120 on new hiking boots. — judge: The quote says only 'my partner'. Nothing in it or in a note ties it to Jordan.
  - M3 unsupported: Jordan can spend up to €120 on new hiking boots. — judge: The quote never names Jordan.
- **wq13** When does my partner want to go to Madeira?: covers A 3/3, B 3/3, C1 3/3, W 2/3, M 3/3
  - W2 wrong_person: Quieres ir a Madeira en febrero de 2027. — judge: attributes partner's wish to the user
- **wq23** Jordan birthday date: covers A 3/3, B 3/3, C1 3/3, W 2/3, M 3/3
  - W1 unsupported: Your partner Jordan’s birthday is 12 March. — judge: Date is correct, but the quote doesn't support calling Jordan the user's partner; that relationship is invented.