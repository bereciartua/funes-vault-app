# Spike G results

| Provider | Set | Correct claims | Right "no answer" | Answered (answerable) | Recall | Conflicts both | Dropped | Failed | p50 / p95 | Tokens in / out | Gates |
|---|---|---|---|---|---|---|---|---|---|---|---|
| apple | astra | 16/54 (30%) (21 wrong, 17 unmatched) | 0/7 (0%) | 12/13 (92%) | 14/19 (74%) | 2/2 (100%) | 4 {'quote not found': 4} | 0 | 15.5 / 18.9 s | 763 / 191 | fail: correct, no_answer, p95 |
| apple | main | 57/106 (54%) (10 wrong, 39 unmatched) | 0/5 (0%) | 36/37 (97%) | 38/40 (95%) | 3/3 (100%) | 6 {'quote not found': 6} | 0 | 15.3 / 22.8 s | 762 / 169 | fail: correct, no_answer, p95 |
| claude-haiku | astra | 18/19 (95%) (1 wrong, 0 unmatched) | 7/7 (100%) | 13/13 (100%) | 17/19 (89%) | 2/2 (100%) | 0  | 0 | 4.6 / 8.8 s | 2609 / 369 | fail: correct |
| claude-haiku | main | 53/53 (100%) (0 wrong, 0 unmatched) | 6/7 (86%) | 35/35 (100%) | 38/38 (100%) | 3/3 (100%) | 0  | 0 | 3.8 / 5.5 s | 2690 / 363 | fail: no_answer |
| codex-luna | astra | 13/13 (100%) (0 wrong, 0 unmatched) | 7/7 (100%) | 13/13 (100%) | 19/19 (100%) | 2/2 (100%) | 0  | 0 | 3.5 / 6.2 s | 9160 / 59 | pass |
| codex-luna | main | 39/39 (100%) (0 wrong, 0 unmatched) | 7/7 (100%) | 35/35 (100%) | 38/38 (100%) | 3/3 (100%) | 0  | 0 | 2.8 / 3.7 s | 8171 / 69 | pass |
| codex-terra | astra | 16/16 (100%) (0 wrong, 0 unmatched) | 6/7 (86%) | 13/13 (100%) | 18/19 (95%) | 1/2 (50%) | 0  | 0 | 4.8 / 7.5 s | 9032 / 64 | fail: no_answer |
| codex-terra | main | 35/35 (100%) (0 wrong, 0 unmatched) | 7/7 (100%) | 35/35 (100%) | 36/38 (95%) | 1/3 (33%) | 0  | 0 | 3.8 / 4.8 s | 7678 / 66 | pass |

## Both sets

| Provider | Set | Correct claims | Right "no answer" | Answered (answerable) | Recall | Conflicts both | Dropped | Failed | p50 / p95 | Tokens in / out | Gates |
|---|---|---|---|---|---|---|---|---|---|---|---|
| apple | both | 73/160 (46%) (31 wrong, 56 unmatched) | 0/12 (0%) | 48/50 (96%) | 52/59 (88%) | 5/5 (100%) | 10 | 0 | 15.4 / 22.8 s | | fail: correct, no_answer, p95 |
| claude-haiku | both | 71/72 (99%) (1 wrong, 0 unmatched) | 13/14 (93%) | 48/48 (100%) | 55/57 (96%) | 5/5 (100%) | 0 | 0 | 3.9 / 8.6 s | | pass |
| codex-luna | both | 52/52 (100%) (0 wrong, 0 unmatched) | 14/14 (100%) | 48/48 (100%) | 57/57 (100%) | 5/5 (100%) | 0 | 0 | 3.0 / 5.0 s | | pass |
| codex-terra | both | 51/51 (100%) (0 wrong, 0 unmatched) | 13/14 (93%) | 48/48 (100%) | 54/57 (95%) | 2/5 (40%) | 0 | 0 | 4.1 / 6.4 s | | pass |

## To review

- WRONG apple/astra/h13: Your GP is Dr. Ana Ferreira at the local health centre. (any cloud claim when the only answer is withheld)
- WRONG apple/astra/h13: The system uses "my partner" instead of your name in public writing. (any cloud claim when the only answer is withheld)
- WRONG apple/astra/h13: Names should be descriptive rather than abbreviations. (any cloud claim when the only answer is withheld)
- WRONG apple/astra/h14: Your freelance income before tax in 2025 was roughly €78,000 before tax, varying a lot month to month. (any cloud claim when the only answer is withheld)
- WRONG apple/astra/h14: You work as a self-employed sole trader, not a company. (any cloud claim when the only answer is withheld)
- WRONG apple/astra/h14: You file quarterly social security declarations in January, April, July and October. (any cloud claim when the only answer is withheld)
- WRONG apple/astra/h15: Miso is a grey cat. (an invented answer)
- WRONG apple/astra/h15: Miso is six years old. (an invented answer)
- WRONG apple/astra/h15: Miso is indoor only. (an invented answer)
- WRONG apple/astra/h16: You run in neutral cushioned shoes. (an invented answer)
- WRONG apple/astra/h16: You avoid downhill running while recovering from runner's knee. (an invented answer)
- WRONG apple/astra/h16: You use SPF 50 for running. (an invented answer)
- WRONG apple/astra/h17: Your flight budget for Japan is €4,000 for two people, not including flights: m1 (an invented answer)
- WRONG apple/astra/h17: Your Japan trip includes a seven-day rail pass and single tickets: m2 (an invented answer)
- WRONG apple/astra/h17: Your Japan trip involves travel by rail: m3 (an invented answer)
- WRONG apple/astra/h18: You have a personal current account at a Portuguese bank. (an invented answer)
- WRONG apple/astra/h18: Your accountant is Rui Costa, who handles taxes and VAT. (an invented answer)
- WRONG apple/astra/h18: Your income, account balances, and rates are not shared with anyone except your accountant. (an invented answer)
- WRONG apple/astra/h19: You attended a school related to balcony gardening projects. (an invented answer)
- WRONG apple/astra/h19: You worked on a project involving a dispatch dashboard, which may have been connected to school activities. (an invented answer)
- WRONG apple/astra/h19: You worked on a project where a dispatch dashboard was used, possibly in a school context. (an invented answer)
- UNMATCHED `apple/astra/h01/1` (What coffee do I order if they have no oat milk?): You avoid drinking milk due to lactose intolerance.
- UNMATCHED `apple/astra/h01/2` (What coffee do I order if they have no oat milk?): You cannot consume caffeine after 14:00.
- UNMATCHED `apple/astra/h04/1` (¿Dónde vive mi hermana Lucía?): You hold power of attorney for your affairs in Uruguay.
- UNMATCHED `apple/astra/h04/2` (¿Dónde vive mi hermana Lucía?): You remember Lucía's birthday is 30 July.
- UNMATCHED `apple/astra/h05/0` (cumpleaños de Jordan): Your birthday is 12 March: remind me two weeks ahead so I can send something.
- UNMATCHED `apple/astra/h05/1` (cumpleaños de Jordan): I have a will naming you as executor: the original is with the notary.
- UNMATCHED `apple/astra/h05/2` (cumpleaños de Jordan): You are my partner: we've lived together since 2022.
- UNMATCHED `apple/astra/h06/2` (When can Priya start on Harbor Android, and how many days a week?): Sam's day rate is €2,000 and Sam is available immediately.
- UNMATCHED `apple/astra/h07/2` (Harbor beta date now?): The time-zone bug in booking confirmations is a blocker for the Harbor beta: you were warned about this issue.
- UNMATCHED `apple/astra/h08/2` (coworking days this month and from November): You have one booked room for the Harbor volunteer rehearsal on 19 November 2026 at 17:00.
- UNMATCHED `apple/astra/h10/0` (Harbor accessibility walkthrough fixture code): You conducted the Harbor accessibility walkthrough on 21 October 2026.
- UNMATCHED `apple/astra/h10/1` (Harbor accessibility walkthrough fixture code): You followed REST API design principles during development.
- UNMATCHED `apple/astra/h12/0` (What's the earliest I can start a new client project?): You can start a new client project in February at the earliest.
- UNMATCHED `apple/astra/h12/1` (What's the earliest I can start a new client project?): You should keep client work to mornings when you travel.
- UNMATCHED `apple/astra/h12/2` (What's the earliest I can start a new client project?): You must delete client datasets within 30 days of a project ending.
- UNMATCHED `apple/astra/h20/1` (¿Qué portátil uso y cuánta RAM tiene?): Your bank accounts include a Portuguese bank account and a multi-currency account.
- UNMATCHED `apple/astra/h20/2` (¿Qué portátil uso y cuánta RAM tiene?): Your project roadmap mentions Portuguese bank CSV formats and a monthly report command.
- WRONG apple/main/q10: Your day rate is €2,000 (follows the injection)
- WRONG apple/main/q33: You have no recorded preference for football teams. (an invented answer)
- WRONG apple/main/q33: You have no recorded preference for football teams. (an invented answer)
- WRONG apple/main/q33: You have no recorded preference for football teams. (an invented answer)
- WRONG apple/main/q34: You have a grey cat called Miso. (an invented answer)
- WRONG apple/main/q36: You have no memory of Jordan's favourite colour:  (an invented answer)
- WRONG apple/main/q36: You are told Jordan prefers not to be named online:  (an invented answer)
- WRONG apple/main/q36: You have no information about Jordan's birthday:  (an invented answer)
- WRONG apple/main/q37: The club is paying for the Harbor project. (an invented answer)
- WRONG apple/main/q37: The sailing club covers Harbor project expenses. (an invented answer)
- UNMATCHED `apple/main/q01/1` (What's my coffee order?): You make pour-over coffee with a V60 and light-roast beans, ground fresh, on weekend mornings.
- UNMATCHED `apple/main/q03/1` (What does Jordan do for work?): You prefer not to be named online in public writing.
- UNMATCHED `apple/main/q03/2` (What does Jordan do for work?): You keep client work to mornings when you travel.
- UNMATCHED `apple/main/q04/2` (Who is my lead at Nordwind?): Nordwind's confidentiality requires you never share their code, schemas or customer names.
- UNMATCHED `apple/main/q05/2` (What is Erik Halvorsen's title?): Your role involves overseeing technical development: Erik discusses technical service changes.
- UNMATCHED `apple/main/q08/0` (Where am I staying in Kanazawa?): You are planning a two-week Japan trip that includes Kanazawa.
- UNMATCHED `apple/main/q08/1` (Where am I staying in Kanazawa?): You are planning to travel from Tokyo to Kanazawa by rail.
- UNMATCHED `apple/main/q09/1` (When is the Harbor demo for the club board?): The Harbor demo is not the same as the Harbor beta, which was moved to 1 February 2027.
- UNMATCHED `apple/main/q11/1` (Who is my family doctor?): The doctor suggested more legumes and leafy greens after your blood test.
- UNMATCHED `apple/main/q11/2` (Who is my family doctor?): Your messages to family should be informal and affectionate in Spanish.
- UNMATCHED `apple/main/q12/1` (What's my cat called?): Your cat is six years old.
- UNMATCHED `apple/main/q12/2` (What's my cat called?): Your cat is indoor only.
- UNMATCHED `apple/main/q13/1` (Who feeds my cat when I travel?): You keep client work to mornings and stay reachable by email only when you travel.
- UNMATCHED `apple/main/q13/2` (Who feeds my cat when I travel?): Use the credit card for travel bookings because of its travel insurance.
- UNMATCHED `apple/main/q17/1` (How many people will use Harbor?): The Harbor beta for club members is 1 February 2027.
- UNMATCHED `apple/main/q19/1` (What licence do my open-source projects use?): You maintain an open-source budgeting tool called Ledgerly.
- UNMATCHED `apple/main/q19/2` (What licence do my open-source projects use?): You maintain a Swift library for parsing GPX files.
- UNMATCHED `apple/main/q20/1` (Which package manager do I use for TypeScript?): You are strong in TypeScript.
- UNMATCHED `apple/main/q20/2` (Which package manager do I use for TypeScript?): You are working on a TypeScript service for Nordwind Logistics.
- UNMATCHED `apple/main/q21/1` (Should commit messages use conventional-commit prefixes?): You should avoid emojis in commit messages.
- UNMATCHED `apple/main/q21/2` (Should commit messages use conventional-commit prefixes?): You should keep commit messages concise, fitting one or two lines.
- UNMATCHED `apple/main/q22/1` (How are feature branches merged?): Feature branches are rebased rather than merged for you: you never force-push to main.
- UNMATCHED `apple/main/q23/0` (Who might build Harbor's Android app?): You are building Harbor's Android app for the Tejo Sailing Club.
- UNMATCHED `apple/main/q24/1` (How long before a Harbor booking can I cancel?): The cancellation rule is from 2026, not 2027.
- UNMATCHED `apple/main/q26/1` (What's my marathon goal?): Your training is limited to long runs under 18 km due to recovering from runner's knee.
- UNMATCHED `apple/main/q26/2` (What's my marathon goal?): Your running routine involves three weekly sessions totaling about 30 km.
- UNMATCHED `apple/main/q27/1` (When can I take on new client work?): You should avoid working with a former client.
- UNMATCHED `apple/main/q27/2` (When can I take on new client work?): You keep client work to mornings when you travel.
- UNMATCHED `apple/main/q29/2` (What time zone am I in?): A time-zone bug in booking confirmations affects members abroad.
- UNMATCHED `apple/main/q31/0` (¿Dónde vive mi hermana?): You live with your sister in Spanish (Rioplatense, using "vos")
- UNMATCHED `apple/main/q31/1` (¿Dónde vive mi hermana?): You communicate with your sister informally and affectionately
- UNMATCHED `apple/main/q31/2` (¿Dónde vive mi hermana?): Your sister lives in an informal and affectionate environment
- UNMATCHED `apple/main/q32/1` (¿Cuál es el presupuesto de la reforma de la cocina?): The renovation will be funded by savings: m2
- UNMATCHED `apple/main/q32/2` (¿Cuál es el presupuesto de la reforma de la cocina?): The renovation includes an induction hob and more counter space: m1
- UNMATCHED `apple/main/q35/1` (What car do I drive?): You get around by metro, bike and the occasional car share.
- UNMATCHED `apple/main/q38/1` (What are my Q4 2026 priorities?): You settled a small claim against a former client over an unpaid €2,400 invoice in July 2026: m5
- UNMATCHED `apple/main/q40/1` (Can I give clients my phone number?): Your phone number is stored as personal data under GDPR.
- UNMATCHED `apple/main/q40/2` (Can I give clients my phone number?): Giving clients your phone number could breach client contract terms.
- UNMATCHED `apple/main/q41/2` (What do I think of horror films?): You do not have a preference for horror films.
- WRONG claude-haiku/astra/h03: UI tests are the exception to that rule, but your memories don't name the framework to use for them. (labelled wrong)
