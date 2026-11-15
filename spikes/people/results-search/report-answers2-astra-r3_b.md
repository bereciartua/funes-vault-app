# Spike H answers, round 2 (astra set, links from r3)

Each query answered 3 times per arm: A plain, B people ranking, C1 hint, C2 hint + prompt sentence, C3 + bridges, W a wrong hint on a trap, M the answer memory's hint removed. Judged by Opus 5.5 without the arm.

## people (16 queries)

| Measure | A | B | C1 | C2 | C3 | W | M |
|---|---|---|---|---|---|---|---|
| Required facts covered (answers) | 38/45 | 44/45 | 43/45 | 44/45 | 44/45 | 0/0 | 42/42 |
| No-answer queries abstained right | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 0/0 | 0/0 |
| Claims: fact | 37 | 43 | 24 | 24 | 24 | 0 | 36 |
| Claims: true_other | 8 | 16 | 13 | 15 | 15 | 0 | 16 |
| Claims: hedged | 1 | 0 | 19 | 20 | 20 | 0 | 8 |
| Claims: denies_true | 1 | 0 | 0 | 0 | 0 | 0 | 1 |
| Claims: wrong_person | 3 | 3 | 3 | 1 | 1 | 0 | 0 |
| Claims: unsupported | 6 | 6 | 10 | 8 | 8 | 0 | 7 |
| Claims: other | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Claims code marks inferred (of which the model hedged) | 0 (0) | 0 (0) | 28 (3) | 25 (14) | 25 (14) | 0 (0) | 0 (0) |

## To read by hand

- **a01** What does Jordan drink in the evening?: covers A 0/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, M 3/3
  - A1 denies_true: Your memories don't record what Jordan drinks in the evening; the only drink-related note is that Jordan likes specialty tea. — judge: Says the vault has no record, but it says rooibos
  - M3 denies_true: Your notes say Jordan likes specialty tea, but they don't say which one Jordan drinks in the evening. — judge: Says the notes don't say which tea Jordan drinks in the evening, but they say rooibos
- **a02** What does Lucía drink in the evening?: covers A 2/3, B 2/3, C1 1/3, C2 2/3, C3 2/3, M 3/3
  - A3 unsupported: Your sister Lucía drinks unsweetened mate in the evening, and you bought her a spare bombilla. — judge: No quote contains the bombilla detail.
  - B2 unsupported: Your sister Lucía drinks unsweetened mate in the evening, and you bought her a spare bombilla. — judge: No quote contains the bombilla detail.
  - C13 unsupported: Your sister Lucía drinks unsweetened mate in the evening, according to a note you wrote on 4 June 2026. — judge: No quote contains the date.
  - C12 unsupported: Your sister drinks unsweetened mate in the evening, and you bought her a spare bombilla. — judge: The quote doesn't contain the bombilla detail.
  - C21 unsupported: Your sister, whom Funes infers is probably Lucía, drinks unsweetened mate in the evening, and you once bought her a spare bombilla. — judge: The quote doesn't contain the bombilla detail.
  - C31 unsupported: Your sister, whom Funes infers is probably Lucía, drinks unsweetened mate in the evening, and you once bought her a spare bombilla. — judge: The quote doesn't contain the bombilla detail.
- **a03** Elena's evening tea?: covers A 0/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, M 3/3
- **a05** ¿Qué me pidió Lucía para su cumpleaños?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, M 3/3
  - C13 unsupported: La nota dice «probablemente» Lucía, y es del 1 de julio de 2026; tu otra nota sitúa el cumpleaños de Lucía el 30 de julio, así que ese pedido podría ser de este año ya pasado. — judge: Note does not say 'probablemente'
  - M2 unsupported: La nota no dice el nombre de tu hermana, pero tu nota sobre tu hermana Lucía indica que tiene una sola, y tu cumpleaños de Lucía es el 30 de julio (Funes infiere que es ella). — judge: 'Only one sister' not in quote
- **a06** ¿Qué toma mi hermana por la noche?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, M 3/3
  - M3 unsupported: Usa un termo verde para su mate, que reconociste en la foto del picnic que te mandó. — judge: picnic photo detail not in quote; not in truth
  - M1 unsupported: Para el mate usa un termo verde, según una foto que te mandó de un picnic. — judge: picnic photo detail not in quote; not in truth
- **a07** Who's my manager at Nordwind now?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, M 3/3
  - A1 unsupported: An older June 2026 note names Erik Halvorsen as your manager for the Nordwind contract, but that predates the handover to Erik Lund. — judge: The quote doesn't mention the handover to Lund.
  - B3 unsupported: An older note from June 2026 says Erik Halvorsen was your manager for the Nordwind contract, but the later handover note replaces that; Halvorsen remains CTO. — judge: The quote doesn't mention the handover or that Halvorsen remains CTO.
  - C12 unsupported: Before that, your manager for the Nordwind contract was Erik Halvorsen, who remains CTO and is a different person from Erik Lund. — judge: The quote doesn't support 'remains CTO' or 'different person'.
  - C21 unsupported: Older notes from June 2026 name Erik Halvorsen as your manager, but he has handed that role over and remains Nordwind's CTO. — judge: The quote doesn't mention the handover or the CTO role.
  - C23 unsupported: Before that, your manager was Erik Halvorsen, who remains Nordwind's CTO; the handover note says they are two different people. — judge: 'Remains CTO' isn't in the quotes.
  - C31 unsupported: Older notes from June 2026 name Erik Halvorsen as your manager, but he has handed that role over and remains Nordwind's CTO. — judge: The quote doesn't mention the handover or the CTO role.
  - C33 unsupported: Before that, your manager was Erik Halvorsen, who remains Nordwind's CTO; the handover note says they are two different people. — judge: 'Remains CTO' isn't in the quotes.
  - M2 unsupported: An older note from June 2026 names Erik Halvorsen as your manager for the Nordwind contract, but your October 2026 handover note says he remains CTO and is a different person from Erik Lund. — judge: The quote doesn't support 'remains CTO' or 'different person'.
  - M1 unsupported: An older note from June 2026 says Erik Halvorsen was your manager for the contract; that role has since moved to Erik Lund, while Halvorsen remains CTO. — judge: The quote doesn't support the handover or the CTO role.
  - M3 unsupported: An older memory from June 2026 names Erik Halvorsen, the CTO, as your manager, which conflicts with the later handover; Erik Halvorsen is a different person from Erik Lund. — judge: The quote doesn't support 'the CTO' or 'different person'.
- **a08** What format does my manager want for weekly Nordwind updates now?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, M 3/3
  - A1 unsupported: Your older format was PDF attachments, requested by Erik Halvorsen, who is now CTO and no longer your manager for the contract. — judge: The quotes don't support CTO
  - B2 unsupported: An older note from June 2026 says Erik Halvorsen asked for PDF attachments, but he is now CTO and no longer your manager, since Erik Lund took over on 19 October 2026. — judge: The quotes don't support the CTO detail
  - C11 unsupported: An older note from June 2026 says Erik Halvorsen wanted PDF attachments, but he has since handed the manager role to Erik Lund and stays on as CTO, so that PDF format is outdated. — judge: The quote doesn't support the handover or CTO details
  - C22 unsupported: Erik Lund, the operations lead, has been your Nordwind manager since 19 October 2026, taking over from Erik Halvorsen, who remains CTO. — judge: The quote doesn't support CTO
  - C21 unsupported: The Markdown request comes from Erik Lund, who has been your manager for the contract since 19 October 2026, while Erik Halvorsen remains CTO. — judge: The quote doesn't support CTO or Lund being the source of the request
  - C32 unsupported: Erik Lund, the operations lead, has been your Nordwind manager since 19 October 2026, taking over from Erik Halvorsen, who remains CTO. — judge: The quote doesn't support CTO
  - C31 unsupported: The Markdown request comes from Erik Lund, who has been your manager for the contract since 19 October 2026, while Erik Halvorsen remains CTO. — judge: The quote doesn't support CTO or Lund being the source of the request
  - M2 unsupported: An older note from 10 June 2026 says Erik Halvorsen asked for PDF attachments, but that predates the handover to Erik Lund and is superseded by the newer Markdown note. — judge: The quote doesn't support the handover
- **a09** What format did Erik Halvorsen ask for when he managed my Nordwind contract?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, M 3/3
  - A3 unsupported: A later note says your manager now wants Markdown files, but that is from after the handover to Erik Lund, not Erik Halvorsen's request. — judge: quote doesn't mention handover or Lund
- **a10** What does Erik Lund usually drink in meetings?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, M 3/3
  - A1 unsupported: Don't confuse this with Erik Halvorsen, whose usual meeting drink is a double espresso; your notes say they are two different people. — judge: the quote doesn't mention espresso
  - B3 unsupported: The double espresso note is for Erik Halvorsen, your former manager and CTO, not Erik Lund, since the memories say they are two different people. — judge: espresso and CTO aren't in the quote
  - C12 unsupported: Don't confuse him with Erik Halvorsen, your former manager, whose noted drink is a double espresso; your notes say they are two different people. — judge: the quote doesn't mention double espresso
  - C11 unsupported: The double espresso in your notes belongs to Erik Halvorsen, your former manager who remains CTO, not Erik Lund, because your notes say they are two different people. — judge: the quote doesn't mention espresso
- **a11** Erik Halvorsen's usual meeting drink: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3, M 3/3
  - B2 unsupported: Don't mix this up with Erik Lund, whose noted meeting drink is peppermint tea, since your notes say Erik Lund and Erik Halvorsen are two different people. — judge: peppermint tea not in quote
  - C12 unsupported: Erik Halvorsen is no longer your contract manager: from 19 October 2026 Erik Lund took over that role, and Halvorsen remains CTO. — judge: date and CTO not in quote
  - C11 unsupported: Your note for peppermint tea is about Erik Lund, your current Nordwind manager, not Erik Halvorsen, so it doesn't apply to him. — judge: manager detail not in quotes
  - C22 unsupported: Don't confuse this with Erik Lund, who is your current Nordwind manager; his noted meeting drink is peppermint tea, because Erik Lund and Erik Halvorsen are two different people. — judge: 'current Nordwind manager' not in quotes
  - C21 unsupported: Don't confuse him with Erik Lund, your current Nordwind manager, whose usual meeting drink you noted as peppermint tea. — judge: manager detail not in quotes
  - C23 unsupported: Don't confuse him with Erik Lund, whose noted meeting drink is peppermint tea; Lund is your current Nordwind manager and a different person from Halvorsen. — judge: manager detail not in quotes
  - C32 unsupported: Don't confuse this with Erik Lund, who is your current Nordwind manager; his noted meeting drink is peppermint tea, because Erik Lund and Erik Halvorsen are two different people. — judge: manager detail not in quotes
  - C33 unsupported: Don't confuse him with Erik Lund, whose noted meeting drink is peppermint tea; Lund is your current Nordwind manager and a different person from Halvorsen. — judge: manager detail not in quotes
  - C31 unsupported: Don't confuse him with Erik Lund, your current Nordwind manager, whose usual meeting drink you noted as peppermint tea. — judge: manager detail not in quotes
- **a15** How do I make coffee at home?: covers A 3/3, B 3/3, C1 3/3, C2 3/3, C3 3/3
  - A2 wrong_person: Your memories don't cover making a flat white at home; they only record your usual order: an oat milk flat white with no sugar, or a black americano if oat milk isn't available. — judge: Someone else's order, given as the user's
  - A1 wrong_person: Your usual drink order is an oat milk flat white with no sugar, or a black americano if oat milk isn't available. — judge: Someone else's order, given as the user's
  - A3 unsupported: On weekend mornings you make pour-over coffee with a V60, using light-roast beans ground fresh. — judge: The quote leaves out 'ground fresh'
  - A3 wrong_person: Your usual coffee order is an oat milk flat white with no sugar, or a black americano if oat milk isn't available. — judge: Someone else's order, given as the user's
  - B3 unsupported: On weekend mornings you make pour-over coffee with a V60, using light-roast beans ground fresh. — judge: The quote leaves out 'ground fresh', so the grinding part isn't supported
  - B3 wrong_person: Your usual coffee order is an oat milk flat white with no sugar, or a black americano if oat milk isn't available. — judge: This is someone else's espresso order, given as the user's
  - B1 wrong_person: Your usual drink order is an oat milk flat white with no sugar, or a black americano if oat milk isn't available. — judge: Someone else's order, given as the user's
  - B2 wrong_person: Your memories don't cover making a flat white at home; they only record your usual order: an oat milk flat white with no sugar, or a black americano if oat milk isn't available. — judge: Someone else's order, given as the user's
  - C13 unsupported: On weekend mornings you make pour-over coffee with a V60, using light-roast beans ground fresh. — judge: The quote leaves out 'ground fresh'
  - C13 wrong_person: Your usual coffee order is an oat milk flat white with no sugar, or a black americano if oat milk isn't available. — judge: Someone else's order, given as the user's
  - C12 wrong_person: Your memories don't cover making a flat white at home; they only record your usual order: an oat milk flat white with no sugar, or a black americano if oat milk isn't available. — judge: Someone else's order, given as the user's
  - C11 wrong_person: Your usual drink order is an oat milk flat white with no sugar, or a black americano if oat milk isn't available. — judge: Someone else's order, given as the user's
  - C22 wrong_person: Your usual drink is an oat milk flat white with no sugar; if oat milk isn't available, you have a black americano. Your memories don't include step-by-step brewing amounts or times. — judge: Someone else's order, given as the user's
  - C32 wrong_person: Your usual drink is an oat milk flat white with no sugar; if oat milk isn't available, you have a black americano. Your memories don't include step-by-step brewing amounts or times. — judge: Someone else's order, given as the user's