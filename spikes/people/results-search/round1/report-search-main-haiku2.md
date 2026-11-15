# Spike H search ranks (main set, links from haiku2)

Boost: {'full': 0.3, 'weak': 0.21, 'cand': 0.09}; others: −0.1

## people (20 queries, 19 with a person matched)

- Best target in the top 3: without people 16/17, with people 16/17
- Best target in the top 8 (what the answer reads): without 17/17, with 17/17
- Better with people: 2, worse: 0
- Decoys (someone else's similar fact, 9 in 6 queries) ranked above the best target: without 0, with 0; in the top 3: without 3, with 0
- Person-only queries, memories about the person in the top 5: without 9/10, with 10/10

| Query | Person matched | Best target rank: without → with |
|---|---|---|
| s01 What does Lucía drink? | Lucía (full, name) | 1 → 1 |
| s02 What is Jordan allergic to? | Jordan (full, name) | 1 → 1 |
| s03 What should I get my mum? | group:parent/ (full, role:parent), group:parent/mother (full, role:parent) | 1 → 1 |
| s04 When is my sister coming to Lisbon? | Lucía (weak, role:sibling) | 1 → 1 |
| s05 When is Lucía visiting? | Lucía (full, name) | 1 → 1 |
| s06 ¿Qué le llevo a Lucía? | Lucía (full, name) | 5 → 5 |
| s07 Where should I take Jordan for dinner? | Jordan (full, name) | 3 → 3 |
| s08 Who is my Nordwind contact now? | none | 1 → 1 |
| s09 How does Priya like updates? | Priya Raman (full, name), Priya (full, name) | 1 → 1 |
| s10 What does Ana drink? | Ana (full, name) | 1 → 1 |
| s11 How does Marta want invoices? | Marta (full, name) | 1 → 1 |
| s12 What wine did Tomás recommend? | Tomás (full, name) | 2 → 1 |
| s13 What does my partner want for our anniversary? | Jordan (full, role:partner) | 1 → 1 |
| s14 What gift ideas do I have for my sister's kids? | Lucía (weak, role:sibling) | 3 → 2 |
| s15 Jordan | Jordan (full, name) | 5/5 → 5/5 about them in the top 5 |
| s16 Lucía | Lucía (full, name) | 4/5 → 5/5 about them in the top 5 |
| s17 How does my manager want status updates? | Priya Raman (full, role:manager) | 1 → 1 |
| s18 What's Erik's coffee order? | Erik Halvorsen (full, name) | 1 → 1 |
| s19 How should I explain video calls to my dad? | group:parent/ (full, role:parent), group:parent/father (full, role:parent) | 1 → 1 |
| s20 What's Lucía's favourite colour? | Lucía (full, name) | – → – |

## spike-g (42 queries, 5 with a person matched)

- Best target in the top 3: without people 32/34, with people 32/34
- Best target in the top 8 (what the answer reads): without 33/34, with 34/34
- Better with people: 1, worse: 0

| Query | Person matched | Best target rank: without → with |
|---|---|---|
| q03 What does Jordan do for work? | Jordan (full, name) | 1 → 1 |
| q05 What is Erik Halvorsen's title? | Erik Halvorsen (full, name) | 1 → 1 |
| q30 ¿Cuándo es el cumpleaños de Lucía? | Lucía (full, name) | 4 → 4 |
| q31 ¿Dónde vive mi hermana? | Lucía (weak, role:sibling) | – → 6 |
| q36 What's Jordan's favourite colour? | Jordan (full, name) | – → – |

## bench (30 queries, 2 with a person matched)

- Best target in the top 3: without people 25/30, with people 25/30
- Best target in the top 8 (what the answer reads): without 30/30, with 30/30
- Better with people: 1, worse: 0

| Query | Person matched | Best target rank: without → with |
|---|---|---|
| bq16 What should I get Jordan for their birthday? | Jordan (full, name) | 2 → 2 |
| bq20 Help me write a message to my mum about my next visit | group:parent/ (full, role:parent), group:parent/mother (full, role:parent) | 3 → 2 |
