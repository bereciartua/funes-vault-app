# Spike H answers, round 2 (astra set, links from r3)

Each query answered 3 times per arm: A plain, B people ranking, C1 hint, C2 hint + prompt sentence, C3 + bridges, W a wrong hint on a trap, M the answer memory's hint removed. Judged by Opus 5.5 without the arm.

## people (16 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 38/45 | 42/45 | 41/45 | 42/45 | 42/45 | 0/0 | 41/42 |
| No-answer queries abstained right | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 0/0 | 0/0 |
| Claims: fact | 37 | 42 | 20 | 20 | 20 | 0 | 35 |
| Claims: true_other | 9 | 16 | 6 | 12 | 12 | 0 | 19 |
| Claims: hedged | 1 | 0 | 28 | 24 | 24 | 0 | 7 |
| Claims: denies_true | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims: wrong_person | 3 | 3 | 3 | 1 | 1 | 0 | 0 |
| Claims: unsupported | 5 | 7 | 12 | 11 | 11 | 0 | 7 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 28 (3) | 25 (14) | 25 (14) | 0 (0) | 0 (0) |

## To read by hand

- **a01** What does Jordan drink in the evening?: covers A 0/3, B 1/3, C1 1/3, C2 1/3, C3 1/3, M 2/3
  - A1 denies_true: Your memories don't record what Jordan drinks in the evening; the only drink-related note is that Jordan likes specialty tea. — judge: Denies that the vault records the rooibos fact.
  - B3 unsupported: Jordan, your partner, drinks rooibos in the evening, and you keep a tin beside the kettle. — judge: The tin detail isn't quoted.
  - B1 unsupported: Jordan drinks rooibos in the evening, since your partner is Jordan and you keep a tin of it beside the kettle. — judge: The tin detail isn't quoted, and the reasoning is muddled.
  - C13 unsupported: Jordan drinks rooibos in the evening, according to your note that your partner drinks it then and keeps a tin beside the kettle. — judge: Says the partner keeps the tin, which the note doesn't say, and the tin isn't quoted.
  - C12 unsupported: Jordan drinks rooibos in the evening, and you keep a tin beside the kettle for them. — judge: The tin detail isn't quoted.
  - C21 unsupported: Your note says Jordan drinks rooibos in the evening, and you keep a tin of it beside the kettle (Funes infers that "my partner" in this note is Jordan). — judge: The tin detail isn't quoted.
  - C22 unsupported: Jordan drinks rooibos in the evening, according to your note about your partner, and you keep a tin beside the kettle. — judge: The tin detail isn't quoted.
  - C31 unsupported: Your note says Jordan drinks rooibos in the evening, and you keep a tin of it beside the kettle (Funes infers that "my partner" in this note is Jordan). — judge: The quote doesn't include the tin detail.
  - C32 unsupported: Jordan drinks rooibos in the evening, according to your note about your partner, and you keep a tin beside the kettle. — judge: The tin detail isn't in the quotes.
  - M2 unsupported: Jordan, your partner, drinks rooibos in the evening, and you keep a tin beside the kettle. — judge: The tin detail isn't quoted.
- **a02** What does Lucía drink in the evening?: covers A 2/3, B 2/3, C1 1/3, C2 2/3, C3 2/3, M 3/3
  - A3 unsupported: Your sister Lucía drinks unsweetened mate in the evening, and you bought her a spare bombilla. — judge: No quote mentions the bombilla.
  - B2 unsupported: Your sister Lucía drinks unsweetened mate in the evening, and you bought her a spare bombilla. — judge: No quote mentions the bombilla.
  - C13 unsupported: Your sister Lucía drinks unsweetened mate in the evening, according to a note you wrote on 4 June 2026. — judge: No quote gives the date.
  - C12 unsupported: Your sister drinks unsweetened mate in the evening, and you bought her a spare bombilla. — judge: No quote mentions the bombilla.
  - C21 unsupported: Your sister, whom Funes infers is probably Lucía, drinks unsweetened mate in the evening, and you once bought her a spare bombilla. — judge: No quote mentions the bombilla.
  - C31 unsupported: Your sister, whom Funes infers is probably Lucía, drinks unsweetened mate in the evening, and you once bought her a spare bombilla. — judge: No quote mentions the bombilla.
- **a03** Elena's evening tea?: covers A 0/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, M 3/3
- **a05** ¿Qué me pidió Lucía para su cumpleaños?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, M 3/3
  - C13 unsupported: La nota dice «probablemente» Lucía, y es del 1 de julio de 2026; tu otra nota sitúa el cumpleaños de Lucía el 30 de julio, así que ese pedido podría ser de este año ya pasado. — judge: Note does not say 'probablemente'
  - M2 unsupported: La nota no dice el nombre de tu hermana, pero tu nota sobre tu hermana Lucía indica que tiene una sola, y tu cumpleaños de Lucía es el 30 de julio (Funes infiere que es ella). — judge: Quote doesn't say she has only one sister
- **a07** Who's my manager at Nordwind now?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, M 3/3
  - B3 unsupported: An older note from June 2026 says Erik Halvorsen was your manager for the Nordwind contract, but the later handover note replaces that; Halvorsen remains CTO. — judge: remains CTO not in quote
  - C12 unsupported: Before that, your manager for the Nordwind contract was Erik Halvorsen, who remains CTO and is a different person from Erik Lund. — judge: CTO/different person not in quote
  - C21 unsupported: Older notes from June 2026 name Erik Halvorsen as your manager, but he has handed that role over and remains Nordwind's CTO. — judge: handover/CTO not in quote
  - C23 unsupported: Before that, your manager was Erik Halvorsen, who remains Nordwind's CTO; the handover note says they are two different people. — judge: remains CTO not in quotes
  - C31 unsupported: Older notes from June 2026 name Erik Halvorsen as your manager, but he has handed that role over and remains Nordwind's CTO. — judge: handover/CTO not in quote
  - C33 unsupported: Before that, your manager was Erik Halvorsen, who remains Nordwind's CTO; the handover note says they are two different people. — judge: remains CTO not in quotes
  - M1 unsupported: An older note from June 2026 says Erik Halvorsen was your manager for the contract; that role has since moved to Erik Lund, while Halvorsen remains CTO. — judge: move to Lund/CTO not in quote
  - M3 unsupported: An older memory from June 2026 names Erik Halvorsen, the CTO, as your manager, which conflicts with the later handover; Erik Halvorsen is a different person from Erik Lund. — judge: CTO/different person not in quote
- **a08** What format does my manager want for weekly Nordwind updates now?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, M 3/3
  - A1 unsupported: Your older format was PDF attachments, requested by Erik Halvorsen, who is now CTO and no longer your manager for the contract. — judge: CTO not in quotes
  - B2 unsupported: An older note from June 2026 says Erik Halvorsen asked for PDF attachments, but he is now CTO and no longer your manager, since Erik Lund took over on 19 October 2026. — judge: CTO not in quotes
  - C11 unsupported: An older note from June 2026 says Erik Halvorsen wanted PDF attachments, but he has since handed the manager role to Erik Lund and stays on as CTO, so that PDF format is outdated. — judge: handover not in quote
  - C22 unsupported: Erik Lund, the operations lead, has been your Nordwind manager since 19 October 2026, taking over from Erik Halvorsen, who remains CTO. — judge: Halvorsen/CTO not in quote
  - C21 unsupported: The Markdown request comes from Erik Lund, who has been your manager for the contract since 19 October 2026, while Erik Halvorsen remains CTO. — judge: CTO not in quote
  - C32 unsupported: Erik Lund, the operations lead, has been your Nordwind manager since 19 October 2026, taking over from Erik Halvorsen, who remains CTO. — judge: Halvorsen/CTO not in quote
  - C31 unsupported: The Markdown request comes from Erik Lund, who has been your manager for the contract since 19 October 2026, while Erik Halvorsen remains CTO. — judge: CTO not in quote
  - M2 unsupported: An older note from 10 June 2026 says Erik Halvorsen asked for PDF attachments, but that predates the handover to Erik Lund and is superseded by the newer Markdown note. — judge: handover not in quote
- **a09** What format did Erik Halvorsen ask for when he managed my Nordwind contract?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, M 3/3
  - A3 unsupported: A later note says your manager now wants Markdown files, but that is from after the handover to Erik Lund, not Erik Halvorsen's request. — judge: quote doesn't show the handover to Lund
  - C13 unsupported: Erik Halvorsen handed the manager role to Erik Lund on 19 October 2026 and remains CTO, so the later Markdown format request is from a different manager. — judge: quote doesn't mention Halvorsen, the handover or CTO
  - C12 unsupported: The later Markdown format is from your newer manager, Erik Lund, who took over the Nordwind contract from Erik Halvorsen on 19 October 2026. — judge: quote doesn't mention Markdown or the takeover from Halvorsen
- **a10** What does Erik Lund usually drink in meetings?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, M 3/3
  - A1 unsupported: Don't confuse this with Erik Halvorsen, whose usual meeting drink is a double espresso; your notes say they are two different people. — judge: quote lacks espresso
  - B3 unsupported: The double espresso note is for Erik Halvorsen, your former manager and CTO, not Erik Lund, since the memories say they are two different people. — judge: quote lacks espresso/CTO
  - C12 unsupported: Don't confuse him with Erik Halvorsen, your former manager, whose noted drink is a double espresso; your notes say they are two different people. — judge: quote lacks espresso/manager
  - C23 unsupported: Your note about a double espresso is for Erik Halvorsen, a different person (your former manager, who remains CTO), not Erik Lund. — judge: manager/CTO not in quote
  - C33 unsupported: Your note about a double espresso is for Erik Halvorsen, a different person (your former manager, who remains CTO), not Erik Lund. — judge: manager/CTO not in quote
  - M2 unsupported: Don't confuse this with Erik Halvorsen, your former manager and CTO, whose noted meeting drink is a double espresso; the memories say they are two different people. — judge: manager/CTO details not in quotes
  - M3 unsupported: Your note about a double espresso is for Erik Halvorsen, not Erik Lund, and you recorded that they are two different people. — judge: 'two different people' not in quote
- **a11** Erik Halvorsen's usual meeting drink: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, M 3/3
  - A2 unsupported: Erik Halvorsen's usual drink for your meetings is a double espresso, according to a note you saved on 14 September 2026. — judge: The quote doesn't name Halvorsen.
  - B2 unsupported: Don't mix this up with Erik Lund, whose noted meeting drink is peppermint tea, since your notes say Erik Lund and Erik Halvorsen are two different people. — judge: No quote gives Lund's peppermint tea.
  - C12 unsupported: Erik Halvorsen is no longer your contract manager: from 19 October 2026 Erik Lund took over that role, and Halvorsen remains CTO. — judge: The quote gives no date for the handover and doesn't say Halvorsen remains CTO.
  - C11 unsupported: Your note for peppermint tea is about Erik Lund, your current Nordwind manager, not Erik Halvorsen, so it doesn't apply to him. — judge: Neither quote says Lund is the current Nordwind manager.
  - C22 unsupported: Don't confuse this with Erik Lund, who is your current Nordwind manager; his noted meeting drink is peppermint tea, because Erik Lund and Erik Halvorsen are two different people. — judge: Neither quote says Lund is the current Nordwind manager.
  - C21 unsupported: Don't confuse him with Erik Lund, your current Nordwind manager, whose usual meeting drink you noted as peppermint tea. — judge: Neither quote says Lund is the current Nordwind manager.
  - C23 unsupported: Don't confuse him with Erik Lund, whose noted meeting drink is peppermint tea; Lund is your current Nordwind manager and a different person from Halvorsen. — judge: Neither quote says Lund is the current Nordwind manager.
  - C32 unsupported: Don't confuse this with Erik Lund, who is your current Nordwind manager; his noted meeting drink is peppermint tea, because Erik Lund and Erik Halvorsen are two different people. — judge: Neither quote says Lund is the current Nordwind manager.
  - C33 unsupported: Don't confuse him with Erik Lund, whose noted meeting drink is peppermint tea; Lund is your current Nordwind manager and a different person from Halvorsen. — judge: Neither quote says Lund is the current Nordwind manager.
  - C31 unsupported: Don't confuse him with Erik Lund, your current Nordwind manager, whose usual meeting drink you noted as peppermint tea. — judge: Neither quote says Lund is the current Nordwind manager.
- **a15** How do I make coffee at home?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3
  - A2 wrong_person: Your memories don't cover making a flat white at home; they only record your usual order: an oat milk flat white with no sugar, or a black americano if oat milk isn't available. — judge: other person's order called user's
  - A1 wrong_person: Your usual drink order is an oat milk flat white with no sugar, or a black americano if oat milk isn't available. — judge: other person's order
  - A3 wrong_person: Your usual coffee order is an oat milk flat white with no sugar, or a black americano if oat milk isn't available. — judge: other person's order
  - B3 wrong_person: Your usual coffee order is an oat milk flat white with no sugar, or a black americano if oat milk isn't available. — judge: someone else's espresso order attributed to user
  - B1 wrong_person: Your usual drink order is an oat milk flat white with no sugar, or a black americano if oat milk isn't available. — judge: other person's order
  - B2 wrong_person: Your memories don't cover making a flat white at home; they only record your usual order: an oat milk flat white with no sugar, or a black americano if oat milk isn't available. — judge: other person's order
  - C13 wrong_person: Your usual coffee order is an oat milk flat white with no sugar, or a black americano if oat milk isn't available. — judge: other person's order
  - C12 wrong_person: Your memories don't cover making a flat white at home; they only record your usual order: an oat milk flat white with no sugar, or a black americano if oat milk isn't available. — judge: other person's order
  - C11 wrong_person: Your usual drink order is an oat milk flat white with no sugar, or a black americano if oat milk isn't available. — judge: other person's order
  - C22 wrong_person: Your usual drink is an oat milk flat white with no sugar; if oat milk isn't available, you have a black americano. Your memories don't include step-by-step brewing amounts or times. — judge: other person's order
  - C32 wrong_person: Your usual drink is an oat milk flat white with no sugar; if oat milk isn't available, you have a black americano. Your memories don't include step-by-step brewing amounts or times. — judge: other person's order