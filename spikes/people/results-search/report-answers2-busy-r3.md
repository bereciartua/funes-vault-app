# Spike H answers, round 2 (busy set, links from r3)

Each query answered 3 times per arm: A plain, B people ranking, C1 hint, C2 hint + prompt sentence, C3 + bridges, W a wrong hint on a trap, M the answer memory's hint removed. Judged by Opus 5.5 without the arm.

## challenge test (8 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 18/24 | 18/24 | 24/24 | 23/24 | 24/24 | 24/24 | 18/24 |
| Claims: fact | 18 | 18 | 10 | 7 | 13 | 6 | 18 |
| Claims: true_other | 3 | 2 | 2 | 3 | 3 | 7 | 1 |
| Claims: hedged | 0 | 0 | 18 | 17 | 15 | 18 | 0 |
| Claims: denies_true | 1 | 0 | 1 | 0 | 0 | 5 | 2 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 7 | 0 |
| Claims: unsupported | 1 | 1 | 0 | 1 | 3 | 0 | 6 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 0 | 1 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 18 (10) | 16 (15) | 14 (12) | 32 (20) | 0 (0) |

## challenge tune (6 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 9/18 | 9/18 | 18/18 | 18/18 | 18/18 | 17/18 | 15/18 |
| Claims: fact | 9 | 9 | 5 | 6 | 6 | 5 | 8 |
| Claims: true_other | 4 | 0 | 0 | 0 | 1 | 10 | 3 |
| Claims: hedged | 0 | 0 | 13 | 12 | 12 | 12 | 7 |
| Claims: denies_true | 1 | 2 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: unsupported | 0 | 0 | 0 | 0 | 1 | 1 | 3 |
| Claims: other | 0 | 0 | 1 | 0 | 0 | 1 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 14 (6) | 12 (9) | 13 (8) | 18 (12) | 0 (0) |

## collision test (4 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 9/12 | 9/12 | 12/12 | 11/12 | 11/12 | 6/6 | 0/3 |
| Claims: fact | 9 | 9 | 9 | 9 | 9 | 3 | 0 |
| Claims: true_other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: hedged | 0 | 0 | 3 | 4 | 4 | 3 | 0 |
| Claims: denies_true | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: unsupported | 5 | 5 | 2 | 2 | 2 | 0 | 3 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
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
| Required facts covered (answers) | 26/27 | 26/27 | 27/27 | 27/27 | 27/27 | 27/27 | 27/27 |
| Claims: fact | 24 | 23 | 25 | 22 | 22 | 24 | 24 |
| Claims: true_other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: hedged | 0 | 0 | 0 | 2 | 3 | 1 | 0 |
| Claims: denies_true | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 1 | 0 |
| Claims: unsupported | 3 | 5 | 2 | 3 | 2 | 2 | 3 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 1 | 1 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 0 (0) | 2 (0) | 3 (0) | 1 (0) | 0 (0) |

## ordinary tune (6 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 12/18 | 11/18 | 17/18 | 17/18 | 17/18 | 9/9 | 9/15 |
| Claims: fact | 12 | 11 | 12 | 12 | 12 | 6 | 9 |
| Claims: true_other | 0 | 0 | 3 | 1 | 1 | 1 | 2 |
| Claims: hedged | 0 | 0 | 6 | 6 | 6 | 5 | 2 |
| Claims: denies_true | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: unsupported | 11 | 14 | 4 | 5 | 5 | 0 | 7 |
| Claims: other | 2 | 0 | 0 | 1 | 1 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 6 (0) | 6 (1) | 6 (1) | 5 (0) | 2 (0) |

## privacy test (1 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 0/0 | 0/0 |
| Claims: fact | 2 | 3 | 3 | 3 | 3 | 0 | 0 |
| Claims: true_other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: hedged | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: denies_true | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: unsupported | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) |

## privacy tune (2 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 6/6 | 6/6 | 6/6 | 5/6 | 5/6 | 0/0 | 0/0 |
| Claims: fact | 6 | 6 | 6 | 5 | 5 | 0 | 0 |
| Claims: true_other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: hedged | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: denies_true | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: unsupported | 0 | 0 | 0 | 1 | 1 | 0 | 0 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) |

## To read by hand

- **wq01** What does Lucía drink in the morning?: covers A 0/3, B 0/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
- **wq02** ¿Qué toma mi hermana por la mañana?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - W2 unsupported: Esa nota es de noviembre de 2024, así que podría haber cambiado; no hay nada más reciente sobre su bebida de la mañana. — judge: The quote doesn't support a date or a claim that nothing newer exists.
- **wq03** What did Lucía ask me to get for her next birthday?: covers A 0/3, B 0/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 0/3
  - A2 denies_true: Your memories don't record a gift Lucía asked you to get for her next birthday; the gift requests for birthdays belong to your sister, Elena and Reina Duarte. — judge: Denies the linocut request, which is Lucía's
  - M2 unsupported: Your sister asked you for linocut tools for her next birthday; that note doesn't name her, but your other notes identify Lucía as your sister, so this is probably Lucía. — judge: Not marked as inferred, and the quote doesn't name Lucía or show she is the sister
  - M1 unsupported: Your sister asked you for linocut tools for her next birthday, and Funes infers she is probably Lucía, since other notes about Lucía describe her as your sister. — judge: Not marked as inferred, and the quote doesn't tie the note to Lucía
  - M3 unsupported: Your sister asked you for linocut tools for her next birthday, but that note doesn't name her; Funes infers she is probably Lucía, since other notes list Lucía as your sister. — judge: Neither quote shows that Lucía is the sister
- **wq04** Which fruit is my sister allergic to?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - W3 wrong_person: A note from 2 April 2026 says oranges, but it names Nia Okafor as the person, so it's unclear whether it refers to your sister; Funes links it to Lucía. — judge: Nia Okafor's orange allergy is linked to Lucía.
  - W1 wrong_person: A April 2026 note says Nia Okafor is allergic to oranges, and it is filed under Lucía, so it conflicts with the kiwi note unless they are different people. — judge: Nia's allergy is filed under Lucía.
  - W2 wrong_person: A later note from 2 April 2026 says Nia Okafor is allergic to oranges, and Funes probably links it to your sister Lucía, though the name differs, so the notes disagree and you should check. — judge: Nia's allergy is linked to Lucía.
- **wq06** What is Jordan's usual evening drink?: covers A 0/3, B 0/3, C1 3/3, C2 3/3, C3 3/3, W 2/3, M 3/3
  - B1 denies_true: Your notes don't say what Jordan drinks in the evening, but they say Jordan likes specialty tea. — judge: Says notes don't state Jordan's drink
  - B1 denies_true: A note says your partner's usual evening drink is roasted barley tea, but it doesn't name Jordan, so it may not be the same person. — judge: Doubts note is about Jordan
  - C31 unsupported: Your memory notes this from November 2024, so Jordan's current habit may have changed since then. — judge: Date not in quote
- **wq09** When is my regular call with my sister, in her time zone?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - C31 unsupported: Your sister, Lucía (Funes infers this from the memories), lives in Montevideo, so that is her local time zone. — judge: The claim that she lives in Montevideo rests on a quote the truth does not contain.
  - C32 unsupported: Her time zone is Montevideo time, since your sister Lucía lives in Montevideo. — judge: The quote about where she lives does not appear in the truth.
- **wq10** What subtitle file format does Lucía need from me?: covers A 0/3, B 0/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 0/3
  - W1 denies_true: Another note says subtitle files should be WebVTT with a .vtt extension, but it names Nia Okafor, not Lucía, even though its about-tag says Lucía, so it's unclear which applies. — judge: Says it's unclear which format applies, which casts doubt on Lucía's SRT
  - M1 unsupported: Your sister, whom Funes infers is Lucía, needs your subtitle files in SRT format, not burned into the video. — judge: The quote names neither the sister nor Lucía, and the claim isn't marked as inferred
  - M3 unsupported: Lucía (probably; Funes infers this from your other notes about your sister) needs subtitle files in SRT format, not burned into the video. — judge: The quote doesn't name Lucía, and the claim isn't marked as inferred
  - M2 unsupported: Your sister needs subtitle files in SRT format, not burned into the video; the memory doesn't name her, but Funes infers it is Lucía, since your other notes identify Lucía as your sister. — judge: Links the note to Lucía without the inferred marker, and the quote doesn't name her
- **wq11** How much can Jordan spend on new hiking boots?: covers A 0/3, B 0/3, C1 3/3, C2 2/3, C3 3/3, W 3/3, M 0/3
  - W2 denies_true: No memory states a boot budget for Jordan's own spending; the €180 and €90 budgets in your notes belong to Erik and Marta. — judge: Denies Jordan has a boot budget.
  - M2 unsupported: Jordan's budget for new hiking boots is €120, since your partner set that limit and Funes infers that partner is Jordan. — judge: Quote doesn't name Jordan and claim not marked inferred.
  - M1 unsupported: Jordan can spend up to €120 on new hiking boots, because your partner set that budget and you noted you should filter out the more expensive pairs (Funes infers your partner is Jordan). — judge: Quote doesn't name Jordan; not marked inferred.
  - M3 unsupported: Jordan probably can spend up to €120 on new hiking boots, since your note says your partner set that budget (Funes infers Jordan is your partner from other notes). — judge: Quotes don't establish Jordan is the partner; not marked inferred.
- **wq12** Where does my sister want to travel in October 2027?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - W3 wrong_person: A second note says Elena wants to visit Mendoza in October 2027, but it is titled "Mum's October trip", so it may be your mum rather than your sister, though it is tagged as about Lucía. — judge: Links Elena's Mendoza note to Lucía.
  - W2 wrong_person: A second memory says Elena wants to visit Mendoza in October 2027, but it is titled "Mum's October trip" and Funes infers it is about Lucía, so it is unclear whether this is your sister or your mum. — judge: Links Elena's Mendoza note to Lucía.
- **wq13** When does my partner want to go to Madeira?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - A3 unsupported: Your partner is Jordan, so this is Jordan's trip; the March 2027 and June 2027 Madeira trips in your notes are for Marta and Erik. — judge: The quote doesn't support the Marta and Erik trip details.
  - W2 wrong_person: A separate note from 18 August 2026 says Marta Silva plans to visit Madeira in March 2027; it is tagged as about your partner Jordan, but the name doesn't match, so it's unclear whether it refers to the same trip. — judge: Treats Marta's March trip as possibly the partner's, which is the trap.
  - W1 wrong_person: A separate note names Marta Silva, not Jordan, as planning a Madeira visit in March 2027; Funes infers it is about your partner, so this may conflict with February. — judge: Links Marta's March trip to the partner.
- **wq14** Where and when is the December family picnic my sister proposed?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - A3 denies_true: A conflicting memory says Rafael proposed a picnic in the Rosedal on 13 December 2026, so the place and date for the December picnic differ between your notes. — judge: treats as conflict
  - B2 unsupported: Your notes also say Lucía has a large insulated food bag you can borrow for the December picnic. — judge: not in truth
  - C12 denies_true: A different memory says Rafael proposed a December picnic in the Rosedal on 13 December 2026, which conflicts with the Prado date and place, so check which one is correct. — judge: casts doubt
  - C23 unsupported: Don't confuse it with Dad's picnic, which Rafael proposed for the Rosedal on 13 December 2026. — judge: Dad not in quote
  - C33 unsupported: Don't confuse it with Dad's picnic, which Rafael proposed for the Rosedal on 13 December 2026. — judge: Dad not in quote
  - W2 denies_true: A conflicting note from 22 September 2026 says Rafael proposed a picnic in the Rosedal on 13 December 2026, so you may want to check whether this is the same event. — judge: suggests may be same event
  - W1 denies_true: A different memory says Rafael proposed a December picnic in the Rosedal on 13 December 2026, which conflicts with the Prado date and place, so check which one is right. — judge: casts doubt
  - W3 denies_true: A different note says Rafael proposed a picnic in the Rosedal on 13 December 2026, so the venue and date conflict with the Prado note. — judge: treats as conflict
  - M2 denies_true: A separate note says Rafael proposed a picnic in the Rosedal on 13 December 2026, which conflicts with the sister's Prado date and place. — judge: frames separate picnic as conflicting
  - M3 denies_true: Another memory says Rafael proposed a different picnic in the Rosedal on 13 December 2026, so it's unclear whether that is the same event as your sister's. — judge: suggests same event
- **wq15** When is Lucía's birthday?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - C13 unsupported: Your sister Lucía's birthday is 30 July, according to your note on family birthdays. — judge: 'sister' is made up and not in the quote
  - C22 unsupported: Your sister Lucía's birthday is 30 July, according to your Family birthdays note. — judge: 'sister' is made up
  - C31 unsupported: Your sister Lucía's birthday is on 30 July, according to your note on family birthdays. — judge: 'sister' is made up
  - W2 unsupported: Your sister Lucía's birthday is 30 July, according to your Family birthdays note. — judge: 'sister' is made up
- **wq16** What does Jordan do for work?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - A1 unsupported: Your memories also mention hospital shifts, which fits Jordan's nursing work. — judge: Quote doesn't name Jordan, not marked inferred.
  - B1 unsupported: Your memories also mention hospital shifts, which fits Jordan's nursing work. — judge: Quote doesn't name Jordan, not marked inferred.
- **wq17** How did Erik Halvorsen first find me?: covers A 0/3, B 0/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 0/3
  - A2 unsupported: Erik Halvorsen first found you through your blog post on offline-first apps, when he was your first contact at Nordwind Logistics. — judge: Quote doesn't name Erik; not marked inferred.
  - A3 unsupported: Erik Halvorsen found you through your blog post on offline-first apps, which is how your first contact at Nordwind Logistics started. — judge: Quote doesn't name Erik.
  - A1 unsupported: Erik Halvorsen, Nordwind Logistics' head of engineering, first found you through your blog post on offline-first apps. — judge: Quote doesn't name Erik.
  - B3 unsupported: Erik Halvorsen found you through your blog post on offline-first apps, which is how your first contact at Nordwind Logistics started. — judge: Quote doesn't name Erik; not marked inferred.
  - B2 unsupported: Erik Halvorsen first found you through your blog post on offline-first apps, when he was your first contact at Nordwind Logistics. — judge: Quote doesn't name Erik; not marked inferred.
  - B1 unsupported: Erik Halvorsen, Nordwind Logistics' head of engineering, first found you through your blog post on offline-first apps. — judge: Quote doesn't name Erik or role.
  - M1 unsupported: Erik Halvorsen found you through your blog post on offline-first apps, which was how your first contact at Nordwind Logistics began. — judge: Quote doesn't name Erik.
  - M2 unsupported: Erik Halvorsen found you through your blog post on offline-first apps, which is how he became your first contact at Nordwind Logistics. — judge: Quote doesn't name Erik.
  - M3 unsupported: Erik Halvorsen, then head of engineering at Nordwind Logistics, first found you through your blog post on offline-first apps. — judge: Quote doesn't name Erik.
- **wq18** Does Marta Silva prefer email or phone calls?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3
  - A3 unsupported: You also agreed a short invoice call with her on Fridays at 18:00 Lisbon time, but only when email has not resolved an issue. — judge: The quote doesn't mention a Friday call.
  - B1 unsupported: You also noted that she agreed to a short invoice call on Fridays at 18:00 Lisbon time, but only when email has not resolved an issue. — judge: The quote doesn't mention a Friday call.
  - B3 unsupported: You also agreed a short invoice call with her on Fridays at 18:00 Lisbon time, but only when email has not resolved an issue. — judge: The quote is incomplete for this claim.
  - B2 unsupported: You also agreed with Marta on a short invoice call on Fridays at 18:00 Lisbon time, but only when email has not resolved an issue. — judge: The quote is incomplete for this claim.
  - C11 unsupported: You also noted that she agreed to a short invoice call on Fridays at 18:00 Lisbon time, but only when email has not resolved an issue. — judge: The quote doesn't mention a Friday 18:00 call.
  - C13 unsupported: You also agreed a short invoice call with her on Fridays at 18:00 Lisbon time, but only when email has not resolved an issue. — judge: The quote doesn't include the time or the condition.
  - C12 unsupported: You also agreed with Marta on a short invoice call on Fridays at 18:00 Lisbon time, but only when email has not resolved an issue. — judge: The quote is incomplete for this claim.
  - C23 unsupported: You also agreed with her on a short invoice call on Fridays at 18:00 Lisbon time, used when email has not resolved an issue. — judge: The quote leaves out the condition about email not resolving an issue.
  - C21 unsupported: You also noted she agreed to a short invoice call with you on Fridays at 18:00 Lisbon time when email hasn't resolved an issue. — judge: The quote doesn't include the time or the condition.
  - C31 unsupported: You also noted she agreed to a short invoice call with you on Fridays at 18:00 Lisbon time when email hasn't resolved an issue. — judge: The quote doesn't include the time or the condition.
  - C33 unsupported: You also agreed with her on a short invoice call on Fridays at 18:00 Lisbon time, used when email has not resolved an issue. — judge: The quote leaves out the condition.
- **wq19** What coffee does Alex Morgan, my climbing instructor, drink?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - M3 unsupported: Alex Morgan drinks Turkish coffee, unsweetened, according to a note you wrote on 4 March 2026 for the climbing instructors' breakfast. — judge: The core fact is right, but the date of 4 March 2026 isn't in the quote or the truth, so it looks invented.
- **wq20** ¿Qué toma por la noche Alex Costa, mi vecino?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - B1 unsupported: Alex Costa es tu vecino, al otro lado del rellano, y os prestáis herramientas de jardinería. — judge: The quote doesn't say anything about lending garden tools to each other.
- **wq21** Which ferry route does Lucía prefer for visiting our parents?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - A2 unsupported: Lucía prefers the direct Montevideo–Buenos Aires ferry when visiting your parents, as you noted in June 2025. — judge: The 'June 2025' date doesn't appear in the quote.
  - A3 unsupported: Lucía told you she prefers the direct Montevideo–Buenos Aires ferry when visiting your parents. — judge: The quote doesn't name Lucía, and the claim isn't marked as inferred.
  - B2 unsupported: Lucía prefers the direct Montevideo–Buenos Aires ferry when you visit your parents in Buenos Aires. — judge: The quote doesn't name Lucía, and the claim isn't marked as inferred.
  - B3 unsupported: Lucía prefers the direct Montevideo–Buenos Aires ferry when visiting your parents, as she told you. — judge: The quote doesn't name Lucía, and the claim isn't marked as inferred.
  - B1 unsupported: Lucía prefers the direct Montevideo–Buenos Aires ferry when visiting your parents. — judge: The quote doesn't name Lucía, and the claim isn't marked as inferred.
  - C11 unsupported: Lucía prefers the direct Montevideo–Buenos Aires ferry when visiting your parents, according to a note you saved from June 2025. — judge: The June 2025 date isn't in the quote.
  - C21 unsupported: Lucía prefers the direct Montevideo–Buenos Aires ferry when she visits your parents, according to a note you saved in June 2025. — judge: The June 2025 date isn't in the quote.
  - M1 unsupported: Lucía prefers the direct Montevideo–Buenos Aires ferry when visiting your parents, as she told you. — judge: The quote only says 'she' and doesn't name Lucía, and the claim isn't marked as inferred.
  - M2 unsupported: Lucía prefers the direct Montevideo–Buenos Aires ferry when visiting your parents, according to a note you saved on 9 June 2025. — judge: The quote doesn't name Lucía, and the date isn't supported by it.
- **wq23** Jordan birthday date: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - C22 unsupported: Your partner Jordan's birthday is 12 March, according to your saved family birthdays note. — judge: The 'partner' relationship is invented.
  - C32 unsupported: Your partner Jordan's birthday is 12 March, according to your saved family birthdays note. — judge: The 'partner' relationship is invented.
  - W2 unsupported: Your partner Jordan's birthday is 12 March, according to your saved family birthdays note. — judge: Date correct, but the quote doesn't support calling Jordan a 'partner'.
- **wq24** How old were Lucía's two kids in my March 2026 note?: covers A 0/3, B 0/3, C1 3/3, C2 3/3, C3 3/3, M 1/3
  - A3 unsupported: Your March 2026 note says Lucía's two kids were aged 8 and 5. — judge: Quote doesn't name Lucía; not marked inferred.
  - A2 unsupported: Your March 2026 note says Lucía's two kids were aged 8 and 5. — judge: Quote doesn't name Lucía; not marked inferred.
  - A1 unsupported: Your March 2026 note says Lucía's two kids were aged 8 and 5. — judge: Quote doesn't name Lucía; not marked inferred.
  - B3 unsupported: Your March 2026 note says Lucía's two kids were aged 8 and 5. — judge: Quote doesn't name Lucía; not marked inferred.
  - B2 unsupported: Your March 2026 note says Lucía's two kids were aged 8 and 5. — judge: Quote doesn't name Lucía; not marked inferred.
  - B1 unsupported: Your March 2026 note says Lucía's two kids were aged 8 and 5. — judge: Quote doesn't name Lucía; not marked inferred.
  - M1 unsupported: In your 13 March 2026 note, Lucía's two kids were aged 8 and 5. — judge: Quote doesn't name Lucía; not marked inferred.
  - M2 unsupported: Your March 2026 note says Lucía's two kids were aged 8 and 5. — judge: Quote doesn't name Lucía; not marked inferred.
- **wq25** When can Lucía collect my photo order from the print shop?: covers A 2/3, B 2/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - A3 unsupported: You noted that Lucía can collect your photo order from the print shop on Monday 9 November 2026. — judge: The quote leaves out Lucía, so it doesn't support attributing the collection to her.
  - B3 unsupported: You noted that Lucía can collect your photo order from the print shop on Monday 9 November 2026. — judge: The quote leaves out Lucía, so it doesn't support attributing the collection to her.
- **wq27** What does Farah Noor, Cecilia's sister, drink?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - W2 wrong_person: An older note from November 2024 says "my sister" drinks bitter mate without sugar in the morning, but it doesn't name Farah, so it may not be about her (Funes infers it relates to Cecilia). — judge: Links the mate memory to Cecilia. That memory is about Lucía.
- **wq28** Is Hugo Lima my brother or my friend?: covers A 3/3, B 2/3, C1 2/3, C2 2/3, C3 2/3, M 2/3
  - A1 unsupported: Your notes also describe Hugo Lima as a friend you met through the neighbourhood repair group. — judge: The repair group isn't in the quote.
  - A3 unsupported: You noted that you had mixed up the contact labels, and a separate note also describes him as your friend who is a florist. — judge: The mix-up isn't in the florist quote.
  - A2 unsupported: A separate note also describes Hugo Lima as your friend, a florist you met through the neighbourhood repair group. — judge: The repair group isn't in the quote.
  - B1 unsupported: Your notes also describe Hugo Lima as a friend you met through the neighbourhood repair group, and he is a florist. — judge: The repair group isn't in the quote.
  - B3 unsupported: Hugo Lima is your friend, not your brother. You corrected an earlier contact label mix-up in August 2025. — judge: The date isn't supported.
  - B3 unsupported: Your March 2025 note also describes him as a friend: you met Hugo Lima through the neighbourhood repair group, and he is a florist. — judge: The date and repair group aren't in the quote.
  - B2 unsupported: A separate note from March 2025 also describes Hugo Lima as your friend, a florist you met through the neighbourhood repair group. — judge: The date and repair group aren't in the quote.
  - C13 unsupported: Hugo Lima is your friend, not your brother; you corrected the contact label in August 2025. — judge: The August 2025 date isn't supported.
  - C23 unsupported: Hugo Lima is your friend, not your brother; you corrected a contact-label mix-up on 4 August 2025. — judge: The date isn't supported.
  - C23 unsupported: Your older note from 15 March 2025 also calls him your friend, describing him as a florist you met through the neighbourhood repair group. — judge: The date and repair group aren't in the quote.
  - C21 unsupported: A separate note from March 2025 also calls him your friend, a florist you met through the neighbourhood repair group. — judge: The date and repair group aren't in the quote.
  - C33 unsupported: Hugo Lima is your friend, not your brother; you corrected a contact-label mix-up on 4 August 2025. — judge: The date isn't supported.
  - C33 unsupported: Your older note from 15 March 2025 also calls him your friend, describing him as a florist you met through the neighbourhood repair group. — judge: The date and repair group aren't in the quote.
  - C31 unsupported: A separate note from March 2025 also calls him your friend, a florist you met through the neighbourhood repair group. — judge: The date and repair group aren't in the quote.
  - M2 unsupported: Hugo Lima is your friend, not your brother; you corrected an earlier contact-label mix-up on 4 August 2025. — judge: The date isn't supported.
  - M1 unsupported: Another memory also describes Hugo Lima as your friend, a florist you met through the neighbourhood repair group. — judge: The repair group isn't in the quote.
- **wq30** When may I sow the balcony coriander?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3
  - A1 unsupported: Since September 2026 has already passed, the next sowing window on that packet would be September 2027. — judge: The 2027 date is extrapolated and not marked as inferred
  - A3 unsupported: Since September 2026 has already passed, the next sowing window on that packet would be September 2027. — judge: The 2027 date is extrapolated and not marked as inferred
  - B3 unsupported: Since September 2026 has already passed, the next sowing window on that packet would be September 2027. — judge: The 2027 date is extrapolated and not marked as inferred
  - B1 unsupported: Since September 2026 has already passed, the next sowing window on that packet would be September 2027. — judge: The 2027 date is extrapolated and not marked as inferred
  - C13 unsupported: Since September 2026 has already passed, the next sowing window on that packet would be September 2027. — judge: The 2027 date is extrapolated and not marked as inferred
  - C11 unsupported: Since September 2026 has already passed, the next sowing window on that packet would be September 2027. — judge: The 2027 date is extrapolated and not marked as inferred
  - C23 unsupported: Since today is late October 2026, that September window has already passed, so your note points to sowing again in September 2027. — judge: The 2027 date is extrapolated and not marked as inferred
  - C33 unsupported: Since today is late October 2026, that September window has already passed, so your note points to sowing again in September 2027. — judge: The 2027 date is extrapolated and isn't in the quote, and the claim doesn't mark it as inferred
- **wq34** What does Will want for his next birthday?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - A2 unsupported: This note was saved on 3 February 2026, so it may be out of date for his upcoming birthday. — judge: The quote doesn't contain the date.
  - B2 unsupported: This note was saved on 3 February 2026, so it may be out of date for his upcoming birthday. — judge: The quote doesn't contain the date.
  - C13 unsupported: This note was saved on 3 February 2026, so his birthday wish may have changed since then. — judge: The quote doesn't contain the date.
  - W2 unsupported: That note is from February 2026, so check with Will that the chess clock is still what he wants. — judge: The quote doesn't contain the date or anything about the chess clock.
  - M2 unsupported: This note was saved on 3 February 2026, so Will's wish may have changed since then. — judge: The quote doesn't contain the date.
- **wq35** What does Mark do on Sunday mornings?: covers A 0/3, B 0/3, C1 3/3, C2 2/3, C3 2/3, W 3/3, M 0/3
  - A1 unsupported: Mark Evans goes road cycling on Sunday mornings, and he invited you along. — judge: The quote says only 'He' and never names Mark, and the claim isn't marked as inferred.
  - A2 unsupported: Mark Evans goes road cycling on Sunday mornings and has invited you along. — judge: The quote says only 'He' and never names Mark, and the claim isn't marked as inferred.
  - A3 unsupported: Mark Evans, your friend from bouldering, goes road cycling on Sunday mornings and has invited you along. — judge: The quote says only 'He' and never names Mark, and the claim isn't marked as inferred.
  - B2 unsupported: Mark Evans goes road cycling on Sunday mornings, and he invited you to come along. — judge: The quote says only 'He' and never names Mark, and the claim isn't marked as inferred.
  - B1 unsupported: Mark Evans goes road cycling on Sunday mornings, and he invited you along. — judge: The quote says only 'He' and never names Mark, and the claim isn't marked as inferred.
  - B3 unsupported: Mark Evans goes road cycling on Sunday mornings, and he has invited you along. — judge: The quote says only 'He' and never names Mark, and the claim isn't marked as inferred.
  - C21 unsupported: Mark goes road cycling on Sunday mornings, and he has invited you along. — judge: The quote says only 'He' and never names Mark, and the claim isn't marked as inferred.
  - C31 unsupported: Mark goes road cycling on Sunday mornings, and he has invited you along. — judge: The quote says only 'He' and never names Mark, and the claim isn't marked as inferred.
  - M3 unsupported: Mark goes road cycling on Sunday mornings, and he invited you along. — judge: The quote says only 'He' and never names Mark, and the claim isn't marked as inferred.
  - M2 unsupported: Mark Evans goes road cycling on Sunday mornings, and he invited you along. — judge: The quote says only 'He' and never names Mark, and the claim isn't marked as inferred.
  - M1 unsupported: Mark goes road cycling on Sunday mornings, and he invited you along. — judge: The quote says only 'He' and never names Mark, and the claim isn't marked as inferred.
- **wq36** What should I order for Tomás Vidal at a café?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3
  - A3 unsupported: Tomás Vidal orders hibiscus iced tea, according to a note you saved on 11 April 2026. — judge: The order is right, but the 11 April 2026 date isn't in the quote.
- **wq38** When and where is Tomás Vidal's photography exhibition?: covers A 3/3, B 3/3, C1 3/3, C2 2/3, C3 2/3
  - C23 unsupported: Tomás Vidal's photography exhibition is in Lisbon on 7 November 2026, to which he invited you. — judge: Quote omits Tomás, so it doesn't support attributing the exhibition to him.
  - C33 unsupported: Tomás Vidal's photography exhibition is in Lisbon on 7 November 2026, to which he invited you. — judge: Quote omits Tomás, so it doesn't support attributing the exhibition to him.