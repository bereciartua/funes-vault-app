# Spike H answers, round 2 (busy set, links from r3)

Each query answered 3 times per arm: A plain, B people ranking, C1 hint, C2 hint + prompt sentence, C3 + bridges, W a wrong hint on a trap, M the answer memory's hint removed. Judged by Opus 5.5 without the arm.

## challenge test (8 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 18/24 | 18/24 | 24/24 | 23/24 | 24/24 | 24/24 | 24/24 |
| Claims: fact | 18 | 18 | 10 | 9 | 15 | 8 | 18 |
| Claims: true_other | 3 | 0 | 2 | 3 | 5 | 6 | 2 |
| Claims: hedged | 1 | 2 | 18 | 14 | 13 | 16 | 3 |
| Claims: denies_true | 1 | 0 | 1 | 0 | 0 | 4 | 2 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 7 | 0 |
| Claims: unsupported | 0 | 1 | 0 | 2 | 1 | 0 | 3 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 2 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 18 (10) | 16 (15) | 14 (12) | 32 (20) | 0 (0) |

## challenge tune (6 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 9/18 | 9/18 | 18/18 | 18/18 | 18/18 | 17/18 | 9/18 |
| Claims: fact | 9 | 9 | 5 | 6 | 7 | 6 | 9 |
| Claims: true_other | 3 | 0 | 0 | 0 | 1 | 11 | 2 |
| Claims: hedged | 0 | 0 | 14 | 12 | 11 | 11 | 1 |
| Claims: denies_true | 2 | 2 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: unsupported | 0 | 0 | 0 | 0 | 1 | 1 | 9 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 14 (6) | 12 (9) | 13 (8) | 18 (12) | 0 (0) |

## collision test (4 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 12/12 | 12/12 | 12/12 | 11/12 | 11/12 | 6/6 | 1/3 |
| Claims: fact | 12 | 12 | 12 | 11 | 11 | 6 | 1 |
| Claims: true_other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: hedged | 0 | 0 | 0 | 2 | 2 | 0 | 0 |
| Claims: denies_true | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: unsupported | 0 | 0 | 0 | 1 | 1 | 0 | 2 |
| Claims: other | 2 | 2 | 2 | 1 | 1 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 3 (0) | 2 (0) | 2 (0) | 3 (0) | 0 (0) |

## collision tune (2 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 6/6 | 6/6 | 6/6 | 6/6 | 6/6 | 3/3 | 3/3 |
| Claims: fact | 6 | 6 | 6 | 6 | 6 | 3 | 3 |
| Claims: true_other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: hedged | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: denies_true | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: unsupported | 1 | 1 | 1 | 0 | 0 | 1 | 1 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) |

## no_answer test (1 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 | 0/0 |
| No-answer queries abstained right | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 0/0 |
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
| No-answer queries abstained right | 6/6 | 6/6 | 6/6 | 6/6 | 6/6 | 6/6 | 0/0 |
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
| Required facts covered (answers) | 27/27 | 27/27 | 27/27 | 27/27 | 27/27 | 27/27 | 27/27 |
| Claims: fact | 27 | 27 | 26 | 26 | 26 | 26 | 27 |
| Claims: true_other | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| Claims: hedged | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: denies_true | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: unsupported | 0 | 1 | 1 | 1 | 1 | 1 | 0 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 1 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 0 (0) | 2 (0) | 3 (0) | 1 (0) | 0 (0) |

## ordinary tune (6 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 18/18 | 18/18 | 18/18 | 18/18 | 18/18 | 9/9 | 15/15 |
| Claims: fact | 18 | 18 | 18 | 18 | 18 | 9 | 15 |
| Claims: true_other | 3 | 1 | 4 | 2 | 2 | 3 | 4 |
| Claims: hedged | 0 | 0 | 0 | 1 | 1 | 0 | 0 |
| Claims: denies_true | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: unsupported | 4 | 6 | 3 | 4 | 4 | 0 | 1 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 6 (0) | 6 (1) | 6 (1) | 5 (0) | 2 (0) |

## privacy test (1 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 0/0 | 0/0 |
| Claims: fact | 3 | 3 | 3 | 3 | 3 | 0 | 0 |
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
| Required facts covered (answers) | 6/6 | 6/6 | 6/6 | 6/6 | 6/6 | 0/0 | 0/0 |
| Claims: fact | 6 | 6 | 6 | 6 | 6 | 0 | 0 |
| Claims: true_other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: hedged | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: denies_true | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: unsupported | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) |

## To read by hand

- **wq01** What does Lucía drink in the morning?: covers A 0/3, B 0/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 0/3
  - M3 unsupported: Your note says your sister drinks bitter mate in the morning, without sugar; it doesn't name Lucía, but you describe Lucía as your sister, so this probably refers to her. — judge: The quote says only 'my sister'. The link to Lucía rests on notes that aren't quoted, and Funes doesn't mark it as inferred.
  - M2 unsupported: Your note says your sister drinks bitter mate in the morning, without sugar; the note doesn't name Lucía, but other notes say Lucía is your sister, so this probably refers to her. — judge: The link to Lucía depends on other notes that aren't quoted, and it isn't marked as inferred.
  - M1 unsupported: Your sister drinks bitter mate in the morning, without sugar (a note from 3 November 2024). The note doesn't name Lucía; Funes infers it means Lucía, since other notes describe her as your sister. — judge: The link to Lucía depends on notes that aren't quoted, and it has no inferred marker.
- **wq02** ¿Qué toma mi hermana por la mañana?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - W2 unsupported: Esa nota es de noviembre de 2024, así que podría haber cambiado; no hay nada más reciente sobre su bebida de la mañana. — judge: The quote doesn't support the note's date or the claim that there is nothing more recent.
- **wq03** What did Lucía ask me to get for her next birthday?: covers A 0/3, B 0/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 0/3
  - A2 denies_true: The only thing Lucía asked you for around her birthday is a lemon cake recipe for her birthday lunch, a recipe rather than a gift, saved on 2 July 2025. — judge: Says the only request is the recipe, which denies the linocut request.
  - A2 denies_true: Your memories don't record a gift Lucía asked you to get for her next birthday; the gift requests for birthdays belong to your sister, Elena and Reina Duarte. — judge: Denies that a gift request is recorded and treats the sister as someone other than Lucía.
  - M2 unsupported: Your sister asked you for linocut tools for her next birthday; that note doesn't name her, but your other notes identify Lucía as your sister, so this is probably Lucía. — judge: Link to Lucía not supported by quote, not Funes-marked.
  - M1 unsupported: Your sister asked you for linocut tools for her next birthday, and Funes infers she is probably Lucía, since other notes about Lucía describe her as your sister. — judge: Sister link not in quote, not marked.
  - M3 unsupported: Your sister asked you for linocut tools for her next birthday, but that note doesn't name her; Funes infers she is probably Lucía, since other notes list Lucía as your sister. — judge: Quotes don't show Lucía is sister.
- **wq04** Which fruit is my sister allergic to?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - W3 wrong_person: A note from 2 April 2026 says oranges, but it names Nia Okafor as the person, so it's unclear whether it refers to your sister; Funes links it to Lucía. — judge: Links Nia's orange allergy to Lucía.
  - W1 wrong_person: A April 2026 note says Nia Okafor is allergic to oranges, and it is filed under Lucía, so it conflicts with the kiwi note unless they are different people. — judge: Files Nia's allergy under Lucía.
  - W2 wrong_person: A later note from 2 April 2026 says Nia Okafor is allergic to oranges, and Funes probably links it to your sister Lucía, though the name differs, so the notes disagree and you should check. — judge: Links Nia's allergy to Lucía.
- **wq06** What is Jordan's usual evening drink?: covers A 0/3, B 0/3, C1 3/3, C2 3/3, C3 3/3, W 2/3, M 0/3
  - B1 denies_true: Your notes don't say what Jordan drinks in the evening, but they say Jordan likes specialty tea. — judge: Says the notes don't give Jordan's evening drink, but they do.
  - B1 denies_true: A note says your partner's usual evening drink is roasted barley tea, but it doesn't name Jordan, so it may not be the same person. — judge: Doubts that the note is about Jordan when it is.
  - C31 unsupported: Your memory notes this from November 2024, so Jordan's current habit may have changed since then. — judge: The quote doesn't contain the November 2024 date.
  - M2 unsupported: Jordan's usual evening drink is probably roasted barley tea, since you noted your partner drinks it and Funes infers your partner is Jordan. — judge: The quote doesn't name Jordan, and there is no inference marker or quote that links the partner to Jordan.
  - M1 unsupported: Jordan's usual evening drink is probably roasted barley tea; your note says "My partner's usual evening drink is roasted barley tea" and doesn't name Jordan, though other notes list Jordan as your partner. — judge: It leans on other notes it doesn't quote to link the partner to Jordan.
  - M3 unsupported: Funes infers that Jordan is your partner, and your partner's usual evening drink is roasted barley tea, so Jordan probably drinks roasted barley tea in the evening. — judge: The quote doesn't name Jordan and there is no inference marker.
- **wq09** When is my regular call with my sister, in her time zone?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - C21 unsupported: Funes infers, but does not confirm, that this sister is Lucía, so the Montevideo time may be hers. — judge: Voice message quote doesn't support link.
- **wq10** What subtitle file format does Lucía need from me?: covers A 0/3, B 0/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
- **wq11** How much can Jordan spend on new hiking boots?: covers A 0/3, B 0/3, C1 3/3, C2 2/3, C3 3/3, W 3/3, M 3/3
  - W2 denies_true: No memory states a boot budget for Jordan's own spending; the €180 and €90 budgets in your notes belong to Erik and Marta. — judge: Denies that Jordan has a boot budget, but the €120 budget is Jordan's.
  - M2 unsupported: Jordan's budget for new hiking boots is €120, since your partner set that limit and Funes infers that partner is Jordan. — judge: The quote doesn't name Jordan, and there is no inferred-link note.
  - M1 unsupported: Jordan can spend up to €120 on new hiking boots, because your partner set that budget and you noted you should filter out the more expensive pairs (Funes infers your partner is Jordan). — judge: The quote doesn't name Jordan, and there is no inferred-link note.
  - M3 unsupported: Jordan probably can spend up to €120 on new hiking boots, since your note says your partner set that budget (Funes infers Jordan is your partner from other notes). — judge: The brush quote doesn't show that Jordan is the partner.
- **wq12** Where does my sister want to travel in October 2027?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - W3 wrong_person: A second note says Elena wants to visit Mendoza in October 2027, but it is titled "Mum's October trip", so it may be your mum rather than your sister, though it is tagged as about Lucía. — judge: Links Elena's Mendoza note to Lucía.
  - W2 wrong_person: A second memory says Elena wants to visit Mendoza in October 2027, but it is titled "Mum's October trip" and Funes infers it is about Lucía, so it is unclear whether this is your sister or your mum. — judge: Links Elena's note to Lucía.
- **wq13** When does my partner want to go to Madeira?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - W2 wrong_person: A separate note from 18 August 2026 says Marta Silva plans to visit Madeira in March 2027; it is tagged as about your partner Jordan, but the name doesn't match, so it's unclear whether it refers to the same trip. — judge: Treats the Marta note as possibly the partner's trip
  - W1 wrong_person: A separate note names Marta Silva, not Jordan, as planning a Madeira visit in March 2027; Funes infers it is about your partner, so this may conflict with February. — judge: Says Marta's March trip may be the partner's
- **wq14** Where and when is the December family picnic my sister proposed?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - A3 denies_true: A conflicting memory says Rafael proposed a picnic in the Rosedal on 13 December 2026, so the place and date for the December picnic differ between your notes. — judge: treats as conflicting
  - B2 unsupported: Your notes also say Lucía has a large insulated food bag you can borrow for the December picnic. — judge: not in truth
  - C12 denies_true: A different memory says Rafael proposed a December picnic in the Rosedal on 13 December 2026, which conflicts with the Prado date and place, so check which one is correct. — judge: doubts which is correct
  - C23 unsupported: Don't confuse it with Dad's picnic, which Rafael proposed for the Rosedal on 13 December 2026. — judge: 'Dad's picnic' invented
  - C33 unsupported: Don't confuse it with Dad's picnic, which Rafael proposed for the Rosedal on 13 December 2026. — judge: 'Dad's picnic' invented
  - W2 denies_true: A conflicting note from 22 September 2026 says Rafael proposed a picnic in the Rosedal on 13 December 2026, so you may want to check whether this is the same event. — judge: casts doubt via conflict
  - W1 denies_true: A different memory says Rafael proposed a December picnic in the Rosedal on 13 December 2026, which conflicts with the Prado date and place, so check which one is right. — judge: doubts which is right
  - W3 denies_true: A different note says Rafael proposed a picnic in the Rosedal on 13 December 2026, so the venue and date conflict with the Prado note. — judge: frames as conflict
  - M2 denies_true: A separate note says Rafael proposed a picnic in the Rosedal on 13 December 2026, which conflicts with the sister's Prado date and place. — judge: frames Rafael's picnic as conflicting with sister's
  - M3 denies_true: Another memory says Rafael proposed a different picnic in the Rosedal on 13 December 2026, so it's unclear whether that is the same event as your sister's. — judge: unclear if same event
- **wq15** When is Lucía's birthday?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - C13 unsupported: Your sister Lucía's birthday is 30 July, according to your note on family birthdays. — judge: The date is right, but nothing in the memory says Lucía is a sister.
  - C22 unsupported: Your sister Lucía's birthday is 30 July, according to your Family birthdays note. — judge: The date is right, but 'sister' is made up.
  - C31 unsupported: Your sister Lucía's birthday is on 30 July, according to your note on family birthdays. — judge: The date is right, but 'sister' is made up.
  - W2 unsupported: Your sister Lucía's birthday is 30 July, according to your Family birthdays note. — judge: The date is right, but 'sister' is made up.
- **wq18** Does Marta Silva prefer email or phone calls?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3
  - A3 unsupported: You also agreed a short invoice call with her on Fridays at 18:00 Lisbon time, but only when email has not resolved an issue. — judge: Quote doesn't support the call details.
  - B1 unsupported: You also noted that she agreed to a short invoice call on Fridays at 18:00 Lisbon time, but only when email has not resolved an issue. — judge: Quote doesn't support the call details.
  - B3 unsupported: You also agreed a short invoice call with her on Fridays at 18:00 Lisbon time, but only when email has not resolved an issue. — judge: Quote partial.
  - B2 unsupported: You also agreed with Marta on a short invoice call on Fridays at 18:00 Lisbon time, but only when email has not resolved an issue. — judge: Quote partial.
  - C11 unsupported: You also noted that she agreed to a short invoice call on Fridays at 18:00 Lisbon time, but only when email has not resolved an issue. — judge: Quote doesn't support the Friday call details.
  - C13 unsupported: You also agreed a short invoice call with her on Fridays at 18:00 Lisbon time, but only when email has not resolved an issue. — judge: Quote partial.
  - C12 unsupported: You also agreed with Marta on a short invoice call on Fridays at 18:00 Lisbon time, but only when email has not resolved an issue. — judge: Quote partial.
  - C23 unsupported: You also agreed with her on a short invoice call on Fridays at 18:00 Lisbon time, used when email has not resolved an issue. — judge: Quote lacks the email condition.
  - C21 unsupported: You also noted she agreed to a short invoice call with you on Fridays at 18:00 Lisbon time when email hasn't resolved an issue. — judge: Quote partial.
  - C31 unsupported: You also noted she agreed to a short invoice call with you on Fridays at 18:00 Lisbon time when email hasn't resolved an issue. — judge: Quote lacks the time and condition.
  - C33 unsupported: You also agreed with her on a short invoice call on Fridays at 18:00 Lisbon time, used when email has not resolved an issue. — judge: Quote lacks the condition.
- **wq20** ¿Qué toma por la noche Alex Costa, mi vecino?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - B1 unsupported: Alex Costa es tu vecino, al otro lado del rellano, y os prestáis herramientas de jardinería. — judge: Quote doesn't support lending garden tools
- **wq28** Is Hugo Lima my brother or my friend?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, M 3/3
  - A1 unsupported: Your notes also describe Hugo Lima as a friend you met through the neighbourhood repair group. — judge: Quote lacks repair group.
  - A3 unsupported: You noted that you had mixed up the contact labels, and a separate note also describes him as your friend who is a florist. — judge: Mix-up not in florist quote.
  - A2 unsupported: A separate note also describes Hugo Lima as your friend, a florist you met through the neighbourhood repair group. — judge: Quote lacks repair group.
  - B1 unsupported: Your notes also describe Hugo Lima as a friend you met through the neighbourhood repair group, and he is a florist. — judge: Quote lacks repair group.
  - B3 unsupported: Your March 2025 note also describes him as a friend: you met Hugo Lima through the neighbourhood repair group, and he is a florist. — judge: Quote lacks repair group.
  - B2 unsupported: A separate note from March 2025 also describes Hugo Lima as your friend, a florist you met through the neighbourhood repair group. — judge: Quote lacks repair group.
  - C23 unsupported: Your older note from 15 March 2025 also calls him your friend, describing him as a florist you met through the neighbourhood repair group. — judge: Quote lacks repair group.
  - C21 unsupported: A separate note from March 2025 also calls him your friend, a florist you met through the neighbourhood repair group. — judge: Quote lacks repair group.
  - C33 unsupported: Your older note from 15 March 2025 also calls him your friend, describing him as a florist you met through the neighbourhood repair group. — judge: Quote lacks repair group.
  - C31 unsupported: A separate note from March 2025 also calls him your friend, a florist you met through the neighbourhood repair group. — judge: Quote lacks repair group.
  - M1 unsupported: Another memory also describes Hugo Lima as your friend, a florist you met through the neighbourhood repair group. — judge: Quote lacks repair group.
- **wq34** What does Will want for his next birthday?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - A2 unsupported: This note was saved on 3 February 2026, so it may be out of date for his upcoming birthday. — judge: Date not in quote
  - B2 unsupported: This note was saved on 3 February 2026, so it may be out of date for his upcoming birthday. — judge: Date not in quote
  - C13 unsupported: This note was saved on 3 February 2026, so his birthday wish may have changed since then. — judge: Date not in quote
  - W2 unsupported: That note is from February 2026, so check with Will that the chess clock is still what he wants. — judge: Date not in quote
  - M2 unsupported: This note was saved on 3 February 2026, so Will's wish may have changed since then. — judge: Date not in quote
- **wq35** What does Mark do on Sunday mornings?: covers A 3/3, B 3/3, C1 3/3, C2 2/3, C3 2/3, W 3/3, M 1/3
  - C21 unsupported: Mark goes road cycling on Sunday mornings, and he has invited you along. — judge: Quote says only 'He', with no note tying it to Mark.
  - C31 unsupported: Mark goes road cycling on Sunday mornings, and he has invited you along. — judge: Quote says only 'He', with no note tying it to Mark.
  - M3 unsupported: Mark goes road cycling on Sunday mornings, and he invited you along. — judge: Quote says only 'He', with no note tying it to Mark.
  - M1 unsupported: Mark goes road cycling on Sunday mornings, and he invited you along. — judge: Quote says only 'He', with no note tying it to Mark.