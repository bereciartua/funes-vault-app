# Spike H answers, round 2 (main set, links from r3)

Each query answered 3 times per arm: A plain, B people ranking, C1 hint, C2 hint + prompt sentence, C3 + bridges, W a wrong hint on a trap, M the answer memory's hint removed. Judged by Opus 5.5 without the arm.

## people (18 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 49/51 | 50/51 | 51/51 | 51/51 | 51/51 | 15/15 | 25/27 |
| No-answer queries abstained right | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 0/0 | 0/0 |
| Claims: fact | 50 | 51 | 39 | 39 | 39 | 6 | 24 |
| Claims: true_other | 11 | 13 | 14 | 14 | 14 | 2 | 6 |
| Claims: hedged | 3 | 1 | 15 | 14 | 14 | 9 | 3 |
| Claims: denies_true | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 3 | 0 |
| Claims: unsupported | 6 | 6 | 4 | 5 | 5 | 1 | 5 |
| Claims: other | 1 | 1 | 1 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 17 (8) | 18 (10) | 18 (10) | 12 (7) | 0 (0) |

## spike-g (5 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 9/12 | 12/12 | 12/12 | 12/12 | 12/12 | 0/0 | 12/12 |
| No-answer queries abstained right | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 0/0 | 0/0 |
| Claims: fact | 11 | 15 | 13 | 15 | 15 | 0 | 15 |
| Claims: true_other | 4 | 4 | 4 | 4 | 4 | 0 | 4 |
| Claims: hedged | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: denies_true | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: unsupported | 1 | 1 | 3 | 2 | 2 | 0 | 3 |
| Claims: other | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) |

## To read by hand

- **s06** ¿Qué le llevo a Lucía?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - A3 unsupported: Si quieres algo para sus hijos, en una nota anotaste que el mayor quiere un modelo de T-rex para su cumpleaños. — judge: Quote doesn't tie to her kids
  - A2 unsupported: Tus memorias no dicen que lleves algo para sus hijos, pero su hijo mayor quiere un modelo de T-rex para su cumpleaños, por si te sirve como idea. — judge: Quote doesn't tie to her kids
  - B3 unsupported: Para sus hijos, al mayor le gustan los dinosaurios y quiere una réplica de T-rex para su cumpleaños. — judge: Dinosaur liking and kinship not in quote
  - B1 unsupported: Si es para sus hijos, el mayor quiere un modelo de T-rex para su cumpleaños. — judge: Quote doesn't tie to her kids
  - C11 unsupported: Si quieres llevarle algo a sus hijos, el mayor quiere un modelo de T-rex para su cumpleaños. — judge: Quote doesn't tie to her kids
  - C21 unsupported: Para sus hijos, tu nota dice que el mayor quiere un modelo de T-rex para su cumpleaños. — judge: Quote doesn't tie T-rex to sister's kids
  - C31 unsupported: Para sus hijos, tu nota dice que el mayor quiere un modelo de T-rex para su cumpleaños. — judge: Quote doesn't tie T-rex to sister's kids
  - W3 unsupported: Si quieres un regalo extra para sus hijos, una nota dice que el mayor quiere un modelo de T-rex para su cumpleaños. — judge: Quote doesn't tie to her kids
  - M1 unsupported: Si quieres llevarle algo a sus hijos, tu nota dice que el mayor quiere un modelo de T-rex para su cumpleaños. — judge: Quote doesn't tie to her kids
- **s10** What does Ana drink?: covers A 1/3, B 2/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 1/3
  - A1 unsupported: Ana, your climbing friend, only drinks matcha now; she gave up coffee last year. — judge: The part about giving up coffee isn't in the quote
  - A3 unsupported: Ana drinks only matcha; you noted this in July 2026, when she had already given up coffee the year before. — judge: Quote doesn't name Ana, and the claim isn't marked as inferred
  - B1 unsupported: Ana, your climbing friend, now only drinks matcha, and she gave up coffee last year. — judge: Quote doesn't name Ana, and the claim isn't marked as inferred
  - M3 unsupported: Ana only drinks matcha now, according to your note from 2 July 2026. — judge: Quote doesn't name Ana, and the claim isn't marked as inferred
  - M3 unsupported: You noted that she gave up coffee last year, so coffee is no longer part of her drinks. — judge: Quote doesn't identify who 'she' is
  - M1 unsupported: According to your note from 2 July 2026, Ana only drinks matcha now, and she gave up coffee last year. — judge: Quote doesn't name Ana, and the claim isn't marked as inferred
  - M2 unsupported: She gave up coffee, which your note says happened last year, so she no longer drinks it. — judge: Quote doesn't identify who 'she' is
- **s11** How does Marta want invoices?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3
  - A3 unsupported: You also noted that Marta, the treasurer, prefers email to phone calls when you contact her about invoices. — judge: The quote doesn't name Marta.
  - A2 unsupported: Marta, the treasurer, prefers email to phone calls, so send her invoices by email rather than by phone. — judge: The quote doesn't name Marta.
  - B3 unsupported: You also noted that Marta, the treasurer, prefers email to phone calls when you contact her about invoices. — judge: The quote doesn't name Marta.
  - B2 unsupported: Marta, the treasurer, prefers email to phone calls, so send her invoices by email rather than by phone. — judge: The quote doesn't name Marta.
  - C12 unsupported: Marta, the treasurer, prefers email to phone calls, so send her invoices by email rather than by phone. — judge: The quote doesn't name Marta or the treasurer.
  - C13 unsupported: You also noted that Marta, the treasurer, prefers email to phone calls when you contact her about invoices. — judge: The quote doesn't name Marta.
  - C22 unsupported: Marta is the sailing club's treasurer and approves invoices, and she prefers email to phone calls, so send invoices by email. — judge: The quote doesn't name Marta or a sailing club.
  - C32 unsupported: Marta is the sailing club's treasurer and approves invoices, and she prefers email to phone calls, so send invoices by email. — judge: The quote doesn't name Marta or a sailing club.
- **s13** What does my partner want for our anniversary?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3
  - C23 unsupported: The memories don't say what your partner wants for the anniversary as a gift, but they list general gift tastes: ceramics, specialty tea and hiking gear, and to avoid scented candles. — judge: The quote doesn't mention avoiding scented candles and doesn't say Jordan is the partner.
  - C21 unsupported: Your partner, Jordan, wants a quiet anniversary dinner this year with no surprises and no big group, according to a note saved by an agent on 30 June 2026. — judge: The quote never names the partner as Jordan, so that part is made up.
  - C31 unsupported: Your partner, Jordan, wants a quiet anniversary dinner this year with no surprises and no big group, according to a note saved by an agent on 30 June 2026. — judge: The quote never names the partner as Jordan, so that part is made up.
  - C33 unsupported: The memories don't say what your partner wants for the anniversary as a gift, but they list general gift tastes: ceramics, specialty tea and hiking gear, and to avoid scented candles. — judge: The quote doesn't mention avoiding scented candles and doesn't say Jordan is the partner.
- **s18** What's Erik's coffee order?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - W1 wrong_person: An older note from 7 December 2025 says Erik's order is an oat milk flat white with no sugar, or a black americano if oat milk isn't available, so your two notes conflict. — judge: oat milk order is someone else's
  - W2 wrong_person: An older note from 7 December 2025 says his order is an oat milk flat white with no sugar, or a black americano if oat milk isn't available, so your notes disagree. — judge: oat milk order is someone else's
  - W3 wrong_person: An older note from 7 December 2025 says his order is an oat milk flat white with no sugar, or a black americano if oat milk isn't available, so your notes disagree. — judge: oat milk order is someone else's
- **s19** How should I explain video calls to my dad?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3
  - B2 unsupported: If you write the explanation to him, use informal, affectionate Spanish with "vos", since that's how you write to your parents. — judge: quote doesn't mention Spanish or vos
  - C12 unsupported: If you write the explanation to him, use informal, affectionate Spanish with "vos", since that's how you write to your parents. — judge: Spanish/vos not in quote
  - C21 unsupported: If you write to him in Spanish, keep it informal and affectionate, in Rioplatense with "vos", as you do with your parents. — judge: Spanish/vos not in quote
  - C31 unsupported: If you write to him in Spanish, keep it informal and affectionate, in Rioplatense with "vos", as you do with your parents. — judge: Spanish/Rioplatense/vos not in quote
- **q30** ¿Cuándo es el cumpleaños de Lucía?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, M 3/3
  - A1 unsupported: Tu hermana Lucía cumple años el 30 de julio, según tu nota de cumpleaños de la familia. — judge: sister relation not in quote
  - C11 unsupported: El cumpleaños de tu hermana Lucía es el 30 de julio. — judge: sister relation not in quote
  - C13 unsupported: El cumpleaños de tu hermana Lucía es el 30 de julio, según tu nota de cumpleaños familiares. — judge: sister relation not in quote
- **q31** ¿Dónde vive mi hermana?: covers A 0/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, M 3/3
  - A2 denies_true: Solo consta que tu hermana te pidió dulce de leche y alfajores cuando viajaste a Montevideo, lo que no confirma que viva allí. — judge: doubts she lives in Montevideo
  - B3 unsupported: Solo de visita: tu hermana irá a Lisboa del 18 al 26 de diciembre con los chicos, y se quedarán en tu cuarto de huéspedes. — judge: guest room not in quote
  - C12 unsupported: Solo está de visita en Lisboa del 18 al 26 de diciembre, con los chicos, y se quedan en el cuarto de huéspedes. — judge: guest room not in quote
  - C23 unsupported: Según una nota del 5 de octubre de 2026, ella visitará Lisboa del 18 al 26 de diciembre con los chicos, pero eso es una visita y no su lugar de residencia. — judge: note date not in quote
  - C22 unsupported: Ella visitará Lisboa del 18 al 26 de diciembre con los chicos, y se quedarán en su cuarto de huéspedes. — judge: guest room not in quote
  - C32 unsupported: Ella visitará Lisboa del 18 al 26 de diciembre con los chicos, y se quedarán en su cuarto de huéspedes. — judge: guest room not in quote
  - C33 unsupported: Según una nota del 5 de octubre de 2026, ella visitará Lisboa del 18 al 26 de diciembre con los chicos, pero eso es una visita y no su lugar de residencia. — judge: note date not in quote
  - M2 unsupported: En diciembre no vive en Lisboa: solo te visita del 18 al 26 de diciembre con los chicos, y se quedan en el cuarto de huéspedes. — judge: guest room not in quote
  - M3 unsupported: Según una nota de octubre, tu hermana visitará Lisboa del 18 al 26 de diciembre con los chicos; es una visita, no su lugar de residencia. — judge: October date not in quote
  - M1 unsupported: En diciembre, tu hermana visitará Lisboa del 18 al 26 con los chicos, y se quedarán en su cuarto de huéspedes. — judge: guest room not in quote