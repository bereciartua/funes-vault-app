# Spike H answers, round 2 (busy set, links from haiku)

Each query answered 3 times per arm (A plain, B people ranking, C ranking plus bridges and about); judged blind by Opus 5.5.

## challenge (14 queries)

| Measure | A plain | B ranking | C ranking + bridges + about |
|---|---|---|---|
| Required facts covered (answers) | 27/42 | 27/42 | 39/42 |
| Claims: fact | 25 | 27 | 22 |
| Claims: true_other | 3 | 6 | 2 |
| Claims: hedged | 0 | 0 | 18 |
| Claims: denies_true | 3 | 1 | 1 |
| Claims: wrong_person | 0 | 0 | 1 |
| Claims: unsupported | 4 | 1 | 8 |
| Claims: other | 2 | 1 | 1 |

## collision (6 queries)

| Measure | A plain | B ranking | C ranking + bridges + about |
|---|---|---|---|
| Required facts covered (answers) | 18/18 | 18/18 | 18/18 |
| Claims: fact | 18 | 18 | 18 |
| Claims: true_other | 1 | 1 | 2 |
| Claims: hedged | 0 | 0 | 0 |
| Claims: denies_true | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 |
| Claims: unsupported | 3 | 3 | 3 |
| Claims: other | 0 | 0 | 1 |

## no_answer (3 queries)

| Measure | A plain | B ranking | C ranking + bridges + about |
|---|---|---|---|
| Required facts covered (answers) | 0/0 | 0/0 | 0/0 |
| No-answer queries abstained right | 9/9 | 9/9 | 9/9 |
| Claims: fact | 0 | 0 | 0 |
| Claims: true_other | 0 | 0 | 0 |
| Claims: hedged | 0 | 0 | 0 |
| Claims: denies_true | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 |
| Claims: unsupported | 0 | 0 | 0 |
| Claims: other | 0 | 0 | 0 |

## ordinary (15 queries)

| Measure | A plain | B ranking | C ranking + bridges + about |
|---|---|---|---|
| Required facts covered (answers) | 45/45 | 45/45 | 45/45 |
| Claims: fact | 45 | 45 | 45 |
| Claims: true_other | 5 | 5 | 5 |
| Claims: hedged | 0 | 0 | 0 |
| Claims: denies_true | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 |
| Claims: unsupported | 2 | 2 | 4 |
| Claims: other | 0 | 0 | 0 |

## privacy (3 queries)

| Measure | A plain | B ranking | C ranking + bridges + about |
|---|---|---|---|
| Required facts covered (answers) | 9/9 | 9/9 | 8/9 |
| Claims: fact | 9 | 9 | 8 |
| Claims: true_other | 0 | 0 | 0 |
| Claims: hedged | 0 | 0 | 0 |
| Claims: denies_true | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 |
| Claims: unsupported | 0 | 0 | 1 |
| Claims: other | 0 | 0 | 0 |

## To read by hand

- **wq01** What does Lucía drink in the morning?: covers A 0/3, B 0/3, C 3/3
- **wq03** What did Lucía ask me to get for her next birthday?: covers A 0/3, B 0/3, C 3/3
  - A2 denies_true: Nothing in your memories says what Lucía asked you to get for her next birthday, so a gift request from her is not recorded. — judge: Says no gift request is recorded, but the linocut tools request exists.
  - A3 denies_true: Your notes don't record any gift Lucía asked you to get for her next birthday; they only note that her birthday is 30 July. — judge: Denies that the recorded linocut tools request exists.
  - A1 denies_true: Your only note of Lucía asking you for something birthday-related is a lemon cake recipe for her birthday lunch, not a gift for her next birthday. — judge: Says the recipe is the only request, which implicitly denies the linocut tools request.
  - B3 denies_true: Your memories don't name a gift Lucía asked you to get for her next birthday; the closest is a July 2025 note that she asked you for a lemon cake recipe for her birthday lunch. — judge: Says no gift is named, when the linocut tools request is.
- **wq04** Which fruit is my sister allergic to?: covers A 3/3, B 3/3, C 3/3
  - A3 unsupported: This note was saved on 11 February 2025, and no other memory mentions your sister's fruit allergy. — judge: Date and exclusivity not in quote.
- **wq06** What is Jordan's usual evening drink?: covers A 0/3, B 0/3, C 3/3
- **wq07** How late does Jordan sleep after a night shift?: covers A 3/3, B 3/3, C 0/3
  - C2 unsupported: Jordan sleeps until 13:00 Lisbon time after a night shift, and you keep the flat quiet until then. — judge: The quote only mentions a partner. Nothing quoted shows that the partner is Jordan.
  - C3 unsupported: Your note says Jordan sleeps until 13:00 Lisbon time after a night shift, and you keep the flat quiet until then. — judge: The quote doesn't name Jordan, so it doesn't support the attribution to him.
  - C1 unsupported: Your memory says Jordan sleeps until 13:00 Lisbon time after a night shift, and you keep the flat quiet until then. — judge: The quote doesn't show that the partner is Jordan.
- **wq08** ¿Qué regalo de cerámica pidió mi pareja para su próximo cumpleaños?: covers A 3/3, B 3/3, C 3/3
  - C3 unsupported: Otra memoria dice que Marta Silva quiere una fuente de cerámica con esmalte azul para su cumpleaños, pero no indica que sea tu pareja. — judge: Blue glaze not in the quoted text.
  - C2 unsupported: Otra nota habla de un bol de cerámica para servir con esmalte azul que Marta Silva quiere para su cumpleaños, pero no dice que Marta sea tu pareja. — judge: Blue glaze not in the quoted text.
  - C1 unsupported: Otra memoria menciona una fuente de cerámica con esmalte azul para el cumpleaños de Marta Silva, pero no dice que Marta sea tu pareja. — judge: Blue glaze not in the quoted text.
- **wq09** When is my regular call with my sister, in her time zone?: covers A 3/3, B 3/3, C 3/3
  - A1 unsupported: Your memories don't record your sister's own time zone, so I can't convert that call into her local time. — judge: The quote about subtitling doesn't support the claim.
- **wq10** What subtitle file format does Lucía need from me?: covers A 0/3, B 0/3, C 3/3
- **wq11** How much can Jordan spend on new hiking boots?: covers A 0/3, B 0/3, C 3/3
  - C2 denies_true: The note doesn't explicitly say the €120 limit covers Jordan's own purchase rather than yours, so confirm that with Jordan. — judge: Questions whether the budget is Jordan's, but the truth says it is.
- **wq12** Where does my sister want to travel in October 2027?: covers A 3/3, B 3/3, C 3/3
  - C2 unsupported: Your mum, Elena, wants to visit Mendoza in October 2027, which is a separate trip from your sister's. — judge: The quote doesn't say Elena is the user's mum. This is the trap memory, though it is not attributed to the sister.
- **wq13** When does my partner want to go to Madeira?: covers A 3/3, B 3/3, C 3/3
  - A1 unsupported: Your partner wants to go to Madeira in February 2027, according to a note you wrote on 17 August 2026. — judge: the date isn't in the quote
  - A3 unsupported: Your partner wants to go to Madeira in February 2027, and you plan to look for short routes near Funchal. — judge: the Funchal routes part isn't in the quote
  - B2 unsupported: Your partner wants to go to Madeira in February 2027, according to a note you saved in Spanish, and you planned to find short routes near Funchal. — judge: the Funchal part isn't quoted
  - C1 unsupported: Your partner wants to go to Madeira in February 2027, according to a note you saved on 17 August 2026 (the note is in Spanish and doesn't name the partner). — judge: the 17 August 2026 save date isn't in the quote
- **wq14** Where and when is the December family picnic my sister proposed?: covers A 3/3, B 3/3, C 3/3
  - C2 wrong_person: A different note says Rafael proposed a picnic in the Rosedal on 13 December 2026, so the place and date for the family picnic conflict between your notes. — judge: Treats Rafael's Rosedal picnic as a conflicting place and date for the sister's family picnic.
- **wq16** What does Jordan do for work?: covers A 3/3, B 3/3, C 3/3
  - C2 unsupported: Your notes also mention Jordan's hospital shifts, for which you once gave a lunch bag. — judge: Quote doesn't mention Jordan or a lunch bag.
  - C1 unsupported: Your notes also mention Jordan's hospital shifts, so the workplace is likely a hospital. — judge: Quote doesn't tie hospital shifts to Jordan; not in truth.
- **wq18** Does Marta Silva prefer email or phone calls?: covers A 3/3, B 3/3, C 3/3
  - A1 unsupported: You have agreed with her on a short invoice call on Fridays at 18:00 Lisbon time, but only when email has not resolved an issue. — judge: The quote doesn't cover 18:00 Lisbon or the email condition.
  - B3 unsupported: You also agreed a short invoice call with her on Fridays at 18:00 Lisbon time, but only when email has not resolved an issue. — judge: The quote doesn't cover 18:00 Lisbon or the email condition.
  - B1 unsupported: You agreed on a short invoice call with her on Fridays at 18:00 Lisbon time, but only when email has not resolved an issue. — judge: The quote doesn't cover 18:00 Lisbon or the email condition.
  - C3 unsupported: You also noted that she agreed to a short invoice call on Fridays at 18:00 Lisbon time, but only when email has not resolved an issue. — judge: The quote doesn't mention the Friday call, 18:00 or Lisbon.
  - C1 unsupported: You agreed a short invoice call with her on Fridays at 18:00 Lisbon time, but only when email has not resolved an issue. — judge: The quote doesn't cover 18:00 Lisbon or the email condition.
- **wq28** Is Hugo Lima my brother or my friend?: covers A 3/3, B 3/3, C 3/3
  - A3 unsupported: A separate note also calls him "my friend Hugo Lima" and says you met him through the neighbourhood repair group. — judge: Repair group detail not in truncated quote.
- **wq30** When may I sow the balcony coriander?: covers A 3/3, B 3/3, C 3/3
  - A1 unsupported: Since September 2026 has already passed, the next sowing window from that packet would be September 2027. — judge: The quote doesn't mention September
  - A2 unsupported: Since September 2026 has already passed, the next sowing window from that note would be September 2027. — judge: The quote doesn't mention September
  - B2 unsupported: Since September 2026 has already passed, the next sowing window from that note would be September 2027. — judge: The quote doesn't mention September
  - B1 unsupported: Since September 2026 has already passed, the next sowing window from that packet would be September 2027. — judge: The quote doesn't mention September
- **wq34** What does Will want for his next birthday?: covers A 3/3, B 3/3, C 3/3
  - A3 unsupported: This memory was saved on 3 February 2026, so the "next birthday" it refers to may be outdated; you may want to check with Will. — judge: The quote doesn't show the date.
  - B3 unsupported: This memory was saved on 3 February 2026, so the "next birthday" it refers to may be outdated; you may want to check with Will. — judge: The quote doesn't show the date.
  - C3 unsupported: This note is from 3 February 2026, so his birthday may have passed and the wish may have changed since then. — judge: The quote doesn't show the 3 February 2026 date.
  - C1 unsupported: This note was saved on 3 February 2026, so Will's wish may have changed since then. — judge: The quoted text has no date in it.
  - C2 unsupported: This note was saved on 3 February 2026, so his "next birthday" may already have passed; the memories don't say when it is, so you may want to check with him. — judge: The quote doesn't show the date.
- **wq38** When and where is Tomás Vidal's photography exhibition?: covers A 3/3, B 3/3, C 2/3
  - C3 unsupported: Tomás Vidal's photography exhibition is in Lisbon, on 7 November 2026, according to the note you saved on 11 October 2026. — judge: Truncated quote never names Tomás Vidal, so attribution to him isn't supported by the quote; the 11 October date isn't in it either.