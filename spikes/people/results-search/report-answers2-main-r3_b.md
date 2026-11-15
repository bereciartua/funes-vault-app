# Spike H answers, round 2 (main set, links from r3)

Each query answered 3 times per arm: A plain, B people ranking, C1 hint, C2 hint + prompt sentence, C3 + bridges, W a wrong hint on a trap, M the answer memory's hint removed. Judged by Opus 5.5 without the arm.

## people (18 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 51/51 | 51/51 | 51/51 | 51/51 | 51/51 | 15/15 | 27/27 |
| No-answer queries abstained right | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 0/0 | 0/0 |
| Claims: fact | 49 | 49 | 41 | 42 | 42 | 8 | 22 |
| Claims: true_other | 11 | 14 | 15 | 11 | 11 | 1 | 5 |
| Claims: hedged | 3 | 0 | 12 | 11 | 11 | 8 | 5 |
| Claims: denies_true | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 3 | 0 |
| Claims: unsupported | 6 | 7 | 5 | 8 | 8 | 1 | 6 |
| Claims: other | 2 | 2 | 0 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 17 (8) | 18 (10) | 18 (10) | 12 (7) | 0 (0) |

## spike-g (5 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 9/12 | 12/12 | 12/12 | 12/12 | 12/12 | 0/0 | 12/12 |
| No-answer queries abstained right | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 0/0 | 0/0 |
| Claims: fact | 11 | 15 | 13 | 15 | 15 | 0 | 15 |
| Claims: true_other | 4 | 4 | 4 | 5 | 5 | 0 | 5 |
| Claims: hedged | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: denies_true | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: unsupported | 1 | 1 | 3 | 1 | 1 | 0 | 2 |
| Claims: other | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) | 0 (0) |

## To read by hand

- **s06** ¿Qué le llevo a Lucía?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - A1 unsupported: Tu hermana Lucía te pidió dulce de leche y alfajores de maicena para cuando viajes a Montevideo. — judge: Lucía not in quote, no inference mark
  - A3 unsupported: Tu hermana Lucía te pidió dulce de leche y alfajores de maicena para cuando viajes a Montevideo. — judge: Lucía not in quote
  - A3 unsupported: Si quieres algo para sus hijos, en una nota anotaste que el mayor quiere un modelo de T-rex para su cumpleaños. — judge: Child not tied to sister
  - A2 unsupported: Tu hermana Lucía te pidió que le llevaras dulce de leche y alfajores de maicena cuando viajes a Montevideo. — judge: Lucía not in quote
  - A2 unsupported: Tus memorias no dicen que lleves algo para sus hijos, pero su hijo mayor quiere un modelo de T-rex para su cumpleaños, por si te sirve como idea. — judge: Child not tied to sister
  - B2 unsupported: Lucía te pidió dulce de leche y alfajores de maicena para cuando viajes a Montevideo. — judge: Quote says 'mi hermana'; naming Lucía not supported by quote or marked inference
  - B3 unsupported: Tu hermana Lucía te pidió dulce de leche y alfajores de maicena para cuando viajes a Montevideo. — judge: Lucía not in quote
  - B3 unsupported: Para sus hijos, al mayor le gustan los dinosaurios y quiere una réplica de T-rex para su cumpleaños. — judge: Dinosaur liking and sister link not in quote
  - B1 unsupported: Tu hermana Lucía te pidió dulce de leche y alfajores de maicena para cuando viajes a Montevideo. — judge: Lucía not in quote
  - B1 unsupported: Si es para sus hijos, el mayor quiere un modelo de T-rex para su cumpleaños. — judge: Child not tied to sister
  - C11 unsupported: Si quieres llevarle algo a sus hijos, el mayor quiere un modelo de T-rex para su cumpleaños. — judge: Child not tied to sister
  - C21 unsupported: Para sus hijos, tu nota dice que el mayor quiere un modelo de T-rex para su cumpleaños. — judge: Quote doesn't tie child to sister
  - C31 unsupported: Para sus hijos, tu nota dice que el mayor quiere un modelo de T-rex para su cumpleaños. — judge: Quote doesn't tie T-rex child to sister
  - W3 unsupported: Si quieres un regalo extra para sus hijos, una nota dice que el mayor quiere un modelo de T-rex para su cumpleaños. — judge: Quote doesn't tie child to sister
  - M2 unsupported: Lucía te pidió dulce de leche y alfajores de maicena para cuando viajes a Montevideo. — judge: Lucía not in quote
  - M1 unsupported: Según tu nota, tu hermana Lucía te pidió dulce de leche y alfajores de maicena para cuando viajes a Montevideo. — judge: Lucía not in quote
  - M1 unsupported: Si quieres llevarle algo a sus hijos, tu nota dice que el mayor quiere un modelo de T-rex para su cumpleaños. — judge: Child not tied to sister
- **s07** Where should I take Jordan for dinner?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, M 3/3
  - A1 unsupported: A note from an agent says Jordan wants a quiet anniversary dinner with no surprises and no big group, though no specific restaurant is named. — judge: no Jordan link
  - B1 unsupported: A note from an agent says Jordan wants a quiet anniversary dinner with no surprises and no big group, though no specific restaurant is named. — judge: no Jordan link
  - C13 unsupported: An agent-written note says a quiet anniversary dinner with no surprises and no big group suits Jordan this year, though the memories don't name a specific restaurant. — judge: no Jordan link
  - C11 unsupported: An agent-recorded note says Jordan wants a quiet anniversary dinner with no surprises and no big group, though your memories don't name a specific restaurant. — judge: no Jordan link
  - C12 unsupported: A note from an agent (not written by you) says Jordan wants a quiet anniversary dinner with no surprises and no big group, so a calm, small setting fits. — judge: no Jordan link
  - C21 unsupported: A note written by an agent says Jordan wants a quiet dinner with no surprises and no big group, though it doesn't name a restaurant. — judge: quote doesn't link to Jordan
  - C23 unsupported: A note from an agent (not from you) says Jordan wants a quiet anniversary dinner with no surprises and no big group, so a small, calm setting fits that. — judge: no Jordan link
  - C22 unsupported: An agent-written note says Jordan wants a quiet anniversary dinner with no surprises and no big group, so keep the group small and the plans low-key. — judge: no Jordan link
  - C33 unsupported: A note from an agent (not from you) says Jordan wants a quiet anniversary dinner with no surprises and no big group, so a small, calm setting fits that. — judge: no Jordan link
  - C31 unsupported: A note written by an agent says Jordan wants a quiet dinner with no surprises and no big group, though it doesn't name a restaurant. — judge: no Jordan link
  - C32 unsupported: An agent-written note says Jordan wants a quiet anniversary dinner with no surprises and no big group, so keep the group small and the plans low-key. — judge: no Jordan link
  - M2 unsupported: A note saved by an agent (not written by you) says Jordan wants a quiet anniversary dinner with no surprises and no big group, so keep the plan low-key and small. — judge: quote doesn't link to Jordan
  - M3 unsupported: An agent-written note says Jordan wants a quiet anniversary dinner with no surprises and no big group, so keep it intimate if this is an anniversary. — judge: no Jordan link
  - M1 unsupported: An agent-written note says Jordan wants a quiet anniversary dinner with no surprises and no big group, though it names no specific restaurant. — judge: no Jordan link
- **s12** What wine did Tomás recommend?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, M 3/3
  - C21 unsupported: Your memory notes that Tomás is a sommelier, so you should ask him before buying wine for a dinner party. — judge: quote lacks sommelier
  - C31 unsupported: Your memory notes that Tomás is a sommelier, so you should ask him before buying wine for a dinner party. — judge: quote lacks sommelier
- **s13** What does my partner want for our anniversary?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3
  - C23 unsupported: The memories don't say what your partner wants for the anniversary as a gift, but they list general gift tastes: ceramics, specialty tea and hiking gear, and to avoid scented candles. — judge: The quote doesn't mention scented candles, and nothing in it says Jordan is the partner.
  - C21 unsupported: Your partner, Jordan, wants a quiet anniversary dinner this year with no surprises and no big group, according to a note saved by an agent on 30 June 2026. — judge: The quote never names the partner, so calling them Jordan is invented.
  - C31 unsupported: Your partner, Jordan, wants a quiet anniversary dinner this year with no surprises and no big group, according to a note saved by an agent on 30 June 2026. — judge: The quote never names the partner, so calling them Jordan is invented.
  - C33 unsupported: The memories don't say what your partner wants for the anniversary as a gift, but they list general gift tastes: ceramics, specialty tea and hiking gear, and to avoid scented candles. — judge: The quote doesn't mention scented candles, and nothing in it says Jordan is the partner.
- **s18** What's Erik's coffee order?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, W 3/3, M 3/3
  - W1 wrong_person: An older note from 7 December 2025 says Erik's order is an oat milk flat white with no sugar, or a black americano if oat milk isn't available, so your two notes conflict. — judge: oat milk note is about someone else
  - W2 wrong_person: An older note from 7 December 2025 says his order is an oat milk flat white with no sugar, or a black americano if oat milk isn't available, so your notes disagree. — judge: oat milk note is about someone else
  - W3 wrong_person: An older note from 7 December 2025 says his order is an oat milk flat white with no sugar, or a black americano if oat milk isn't available, so your notes disagree. — judge: oat milk note is about someone else
- **s19** How should I explain video calls to my dad?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3
  - B2 unsupported: If you write the explanation to him, use informal, affectionate Spanish with "vos", since that's how you write to your parents. — judge: Quote doesn't mention Spanish or vos
  - C12 unsupported: If you write the explanation to him, use informal, affectionate Spanish with "vos", since that's how you write to your parents. — judge: Quote doesn't mention Spanish or vos
  - C21 unsupported: If you write to him in Spanish, keep it informal and affectionate, in Rioplatense with "vos", as you do with your parents. — judge: Quote doesn't mention Spanish, Rioplatense or vos
  - C31 unsupported: If you write to him in Spanish, keep it informal and affectionate, in Rioplatense with "vos", as you do with your parents. — judge: Quote doesn't mention Spanish, Rioplatense or vos
- **q30** ¿Cuándo es el cumpleaños de Lucía?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, M 3/3
  - A1 unsupported: Tu hermana Lucía cumple años el 30 de julio, según tu nota de cumpleaños de la familia. — judge: 'sister' invented
  - C11 unsupported: El cumpleaños de tu hermana Lucía es el 30 de julio. — judge: date right but 'sister' invented
  - C13 unsupported: El cumpleaños de tu hermana Lucía es el 30 de julio, según tu nota de cumpleaños familiares. — judge: 'sister' invented
- **q31** ¿Dónde vive mi hermana?: covers A 0/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, M 3/3
  - A2 denies_true: Solo consta que tu hermana te pidió dulce de leche y alfajores cuando viajaste a Montevideo, lo que no confirma que viva allí. — judge: doubts she lives in Montevideo
  - B3 unsupported: Solo de visita: tu hermana irá a Lisboa del 18 al 26 de diciembre con los chicos, y se quedarán en tu cuarto de huéspedes. — judge: guest room not in quote
  - C12 unsupported: Solo está de visita en Lisboa del 18 al 26 de diciembre, con los chicos, y se quedan en el cuarto de huéspedes. — judge: guest room not in quote
  - C22 unsupported: Ella visitará Lisboa del 18 al 26 de diciembre con los chicos, y se quedarán en su cuarto de huéspedes. — judge: guest room not in quote
  - C32 unsupported: Ella visitará Lisboa del 18 al 26 de diciembre con los chicos, y se quedarán en su cuarto de huéspedes. — judge: guest room not in quote
  - M2 unsupported: En diciembre no vive en Lisboa: solo te visita del 18 al 26 de diciembre con los chicos, y se quedan en el cuarto de huéspedes. — judge: guest room not in quote
  - M1 unsupported: En diciembre, tu hermana visitará Lisboa del 18 al 26 con los chicos, y se quedarán en su cuarto de huéspedes. — judge: guest room not in quote