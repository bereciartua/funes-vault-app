# Spike H report (astra set)

## claude-haiku (56 story runs over 2 run(s))

| Measure | Result |
|---|---|
| Role links, full basis (named, stated, context) right | 143/145 = 99% |
| Role links, sole_known right | 26/26 = 100% |
| Role links, untrusted right | – |
| Decidable role references linked to the right person | 169/184 = 92% |
| Decidable role references left unresolved (misses) | 13 |
| Undecidable references kept ambiguous | 48/48 = 100% |
| Name links right (named) | 169/169 = 100% |
| Ambiguous names kept ambiguous | 4/8 = 50% |
| The user's own name kept off the people list | 10/10 = 100% |
| Links the story forbids | 2 |
| Role links where the story has none (quotes, negations, injections) | 0 |
| People made that aren't people | 4 |
| Names not recorded | 5 |
| Relations: precision · recall | 120/137 = 88% · 120/126 = 95% |
| Relations kept though denied | 0 |
| Labels not in the text | 0 |
| Calls (failed) · mean seconds · tokens in/out | 283 (0) · 4.0 · 797,793/163,638 |

Errors:

- a07#0 r1 m4: 'My boss' left as candidates, truth omar (decidable)
- a11#0 r1 m2: name 'Ren' not recorded
- a13#0 r1 m2: 'my manager' → Yuki (stated_unique), truth sasha
- a13#0 r1 m2: linked to yuki, which the story forbids (stated_unique)
- a13#1 r1 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a14#0 r1 m2: name 'Idris' not recorded
- a15#1 r1 m2: ambiguous 'Alex' → Alex
- a15#1 r1 m4: ambiguous 'Alex' → Alex
- a17#0 r1 m1: 'Noa Bergman's friend' left as candidates, truth elena (decidable)
- a17#0 r1 m1: 'Noa Bergman's friend' left as candidates, truth mateo (decidable)
- a18#0 r1 m4: name 'Morgan' linked to a person the story doesn't list
- a18#0 r1 made a person 'Morgan' the story doesn't have
- a18#1 r1 m4: name 'Morgan' linked to a person the story doesn't list
- a18#1 r1 made a person 'Morgan' the story doesn't have
- a19#0 r1 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a19#0 r1 m2: name 'Kai' not recorded
- a19#1 r1 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a04#1 r2 m1: 'My friend' left as candidates, truth devon (decidable)
- a04#1 r2 m1: 'my friend' left as candidates, truth luz (decidable)
- a11#0 r2 m2: name 'Ren' not recorded
- a13#0 r2 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a13#1 r2 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a15#1 r2 m2: ambiguous 'Alex' → Alex
- a15#1 r2 m4: ambiguous 'Alex' → Alex
- a18#0 r2 m4: name 'Morgan' linked to a person the story doesn't list
- a18#0 r2 made a person 'Morgan' the story doesn't have
- a17#0 r2 m1: 'Noa Bergman's friend' left as candidates, truth elena (decidable)
- a17#0 r2 m1: 'Noa Bergman's friend' left as candidates, truth mateo (decidable)
- a18#1 r2 m4: name 'Morgan' linked to a person the story doesn't list
- a18#1 r2 made a person 'Morgan' the story doesn't have
- a19#0 r2 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a19#0 r2 m2: name 'Kai' not recorded
- a19#1 r2 m4: 'my spouse' → Rowan (stated_unique), truth kai
- a19#1 r2 m4: linked to rowan, which the story forbids (stated_unique)

## claude-opus (56 story runs over 2 run(s))

| Measure | Result |
|---|---|
| Role links, full basis (named, stated, context) right | 148/148 = 100% |
| Role links, sole_known right | 24/24 = 100% |
| Role links, untrusted right | 4/4 = 100% |
| Decidable role references linked to the right person | 176/184 = 96% |
| Decidable role references left unresolved (misses) | 8 |
| Undecidable references kept ambiguous | 48/48 = 100% |
| Name links right (named) | 172/172 = 100% |
| Ambiguous names kept ambiguous | 4/8 = 50% |
| The user's own name kept off the people list | 10/10 = 100% |
| Links the story forbids | 0 |
| Role links where the story has none (quotes, negations, injections) | 0 |
| People made that aren't people | 4 |
| Names not recorded | 0 |
| Relations: precision · recall | 119/131 = 91% · 119/126 = 94% |
| Relations kept though denied | 0 |
| Labels not in the text | 0 |
| Calls (failed) · mean seconds · tokens in/out | 274 (0) · 3.9 · 765,190/62,473 |

Errors:

- a13#0 r1 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a13#1 r1 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a15#1 r1 m2: ambiguous 'Alex' → Alex
- a15#1 r1 m4: ambiguous 'Alex' → Alex
- a18#0 r1 m4: name 'Morgan' linked to a person the story doesn't list
- a18#0 r1 made a person 'Morgan' the story doesn't have
- a18#1 r1 m4: name 'Morgan' linked to a person the story doesn't list
- a18#1 r1 made a person 'Morgan' the story doesn't have
- a19#0 r1 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a19#1 r1 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a13#0 r2 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a13#1 r2 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a15#1 r2 m2: ambiguous 'Alex' → Alex
- a15#1 r2 m4: ambiguous 'Alex' → Alex
- a18#0 r2 m4: name 'Morgan' linked to a person the story doesn't list
- a18#0 r2 made a person 'Morgan' the story doesn't have
- a18#1 r2 m4: name 'Morgan' linked to a person the story doesn't list
- a18#1 r2 made a person 'Morgan' the story doesn't have
- a19#0 r2 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a19#1 r2 m4: 'my spouse' left as someone_else, truth kai (decidable)

## codex-luna (56 story runs over 2 run(s))

| Measure | Result |
|---|---|
| Role links, full basis (named, stated, context) right | 141/143 = 99% |
| Role links, sole_known right | 17/17 = 100% |
| Role links, untrusted right | – |
| Decidable role references linked to the right person | 158/184 = 86% |
| Decidable role references left unresolved (misses) | 24 |
| Undecidable references kept ambiguous | 48/48 = 100% |
| Name links right (named) | 171/171 = 100% |
| Ambiguous names kept ambiguous | 4/8 = 50% |
| The user's own name kept off the people list | 10/10 = 100% |
| Links the story forbids | 3 |
| Role links where the story has none (quotes, negations, injections) | 0 |
| People made that aren't people | 6 |
| Names not recorded | 0 |
| Relations: precision · recall | 117/136 = 86% · 117/126 = 93% |
| Relations kept though denied | 0 |
| Labels not in the text | 0 |
| Calls (failed) · mean seconds · tokens in/out | 288 (0) · 3.9 · 2,273,578/29,566 |

Errors:

- a01#0 r1 m1: 'my sister' left as candidates, truth inez (decidable)
- a01#0 r1 m1: 'my sister' left as candidates, truth mara (decidable)
- a01#1 r1 m1: 'my sister' left as candidates, truth inez (decidable)
- a01#1 r1 m1: 'my sister' left as candidates, truth mara (decidable)
- a04#1 r1 m2: 'My friend' left as context, truth luz (decidable)
- a11#1 r1 m3: 'My mother-in-law' left as group, truth hana (decidable)
- a13#0 r1 m2: 'my manager' → Yuki (stated_unique), truth sasha
- a13#0 r1 m2: linked to yuki, which the story forbids (stated_unique)
- a13#1 r1 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a15#0 r1 m3: name 'Alex' → None (ambiguous), truth alex_kim
- a15#1 r1 m2: ambiguous 'Alex' → Alex
- a15#1 r1 m4: ambiguous 'Alex' → Alex
- a17#0 r1 m1: 'Noa Bergman's friend' left as candidates, truth elena (decidable)
- a17#0 r1 m1: 'Noa Bergman's friend' left as candidates, truth mateo (decidable)
- a18#1 r1 m4: name 'Morgan' linked to a person the story doesn't list
- a18#1 r1 m2: name 'Bruno' linked to a person the story doesn't list
- a18#1 r1 m2: name 'Morgan' linked to a person the story doesn't list
- a18#1 r1 made a person 'Morgan' the story doesn't have
- a18#1 r1 made a person 'Bruno' the story doesn't have
- a18#1 r1 made a person 'Morgan' the story doesn't have
- a18#0 r1 m4: name 'Morgan' linked to a person the story doesn't list
- a18#0 r1 m4: name 'Bruno' linked to a person the story doesn't list
- a18#0 r1 made a person 'Morgan' the story doesn't have
- a18#0 r1 made a person 'Bruno' the story doesn't have
- a19#0 r1 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a19#1 r1 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a20#0 r1 m1: 'my friend' left as candidates, truth uma (decidable)
- a20#0 r1 m1: 'my friend' left as candidates, truth davi (decidable)
- a03#1 r2 m2: 'my sister' left as candidates, truth lea (decidable)
- a03#1 r2 m1: 'My only sister' left as candidates, truth lea (decidable)
- a04#1 r2 m1: 'My friend' left as context, truth devon (decidable)
- a04#1 r2 m1: 'my friend' left as candidates, truth luz (decidable)
- a11#1 r2 m3: 'My mother-in-law' left as sole_known, truth hana (decidable)
- a11#1 r2 m2: 'my mother-in-law' left as sole_known, truth hana (decidable)
- a13#0 r2 m2: 'my manager' → Yuki (stated_unique), truth sasha
- a13#0 r2 m2: linked to yuki, which the story forbids (stated_unique)
- a13#1 r2 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a15#0 r2 m3: name 'Alex' → None (ambiguous), truth alex_kim
- a15#1 r2 m2: ambiguous 'Alex' → Alex
- a15#1 r2 m4: ambiguous 'Alex' → Alex
- a17#0 r2 m1: 'Noa Bergman's friend' left as candidates, truth elena (decidable)
- a17#0 r2 m1: 'Noa Bergman's friend' left as candidates, truth mateo (decidable)
- a18#0 r2 m4: name 'Morgan' linked to a person the story doesn't list
- a18#0 r2 made a person 'Morgan' the story doesn't have
- a18#1 r2 m4: name 'Morgan' linked to a person the story doesn't list
- a18#1 r2 m4: linked to morgan, which the story forbids (named)
- a19#0 r2 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a19#1 r2 m4: 'my spouse' left as someone_else, truth kai (decidable)

## codex-terra (56 story runs over 2 run(s))

| Measure | Result |
|---|---|
| Role links, full basis (named, stated, context) right | 145/149 = 97% |
| Role links, sole_known right | 24/24 = 100% |
| Role links, untrusted right | – |
| Decidable role references linked to the right person | 169/184 = 92% |
| Decidable role references left unresolved (misses) | 13 |
| Undecidable references kept ambiguous | 46/48 = 96% |
| Name links right (named) | 170/170 = 100% |
| Ambiguous names kept ambiguous | 4/8 = 50% |
| The user's own name kept off the people list | 10/10 = 100% |
| Links the story forbids | 4 |
| Role links where the story has none (quotes, negations, injections) | 0 |
| People made that aren't people | 3 |
| Names not recorded | 0 |
| Relations: precision · recall | 118/128 = 92% · 118/126 = 94% |
| Relations kept though denied | 0 |
| Labels not in the text | 0 |
| Calls (failed) · mean seconds · tokens in/out | 283 (0) · 6.2 · 2,073,340/45,765 |

Errors:

- a04#0 r1 m2: 'My friend' left as context, truth luz (decidable)
- a13#0 r1 m2: 'my manager' → Yuki (stated_unique), truth sasha
- a13#0 r1 m2: linked to yuki, which the story forbids (stated_unique)
- a13#1 r1 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a15#1 r1 m2: ambiguous 'Alex' → Alex
- a15#1 r1 m4: ambiguous 'Alex' → Alex
- a17#0 r1 m1: 'Noa Bergman's friend' left as candidates, truth elena (decidable)
- a17#0 r1 m1: 'Noa Bergman's friend' left as candidates, truth mateo (decidable)
- a18#0 r1 m2: name 'Bruno' linked to a person the story doesn't list
- a18#0 r1 made a person 'Bruno' the story doesn't have
- a18#1 r1 m2: name 'Bruno' linked to a person the story doesn't list
- a18#1 r1 made a person 'Bruno' the story doesn't have
- a19#0 r1 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a19#1 r1 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a02#0 r2 m3: 'My brother' → Pavel (context), truth brother_b
- a02#0 r2 m5: 'My younger brother' → Pavel (context), truth brother_c
- a02#0 r2 m5: linked to pavel, which the story forbids (context)
- a04#1 r2 m2: 'My friend' left as context, truth luz (decidable)
- a13#0 r2 m2: 'my manager' → Yuki (stated_unique), truth sasha
- a13#0 r2 m2: linked to yuki, which the story forbids (stated_unique)
- a13#1 r2 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a15#1 r2 m2: ambiguous 'Alex' → Alex
- a15#1 r2 m4: ambiguous 'Alex' → Alex
- a15#1 r2 m1: 'my colleague' left as group, truth alex_reed (decidable)
- a15#1 r2 m1: name 'Alex Kim' → None (ambiguous), truth alex_kim
- a15#1 r2 m1: name 'Alex Reed' → None (ambiguous), truth alex_reed
- a18#0 r2 m2: name 'Bruno' linked to a person the story doesn't list
- a18#0 r2 made a person 'Bruno' the story doesn't have
- a17#0 r2 m1: 'Noa Bergman's friend' left as candidates, truth elena (decidable)
- a17#0 r2 m1: 'Noa Bergman's friend' left as candidates, truth mateo (decidable)
- a18#1 r2 m4: name 'Morgan' linked to a person the story doesn't list
- a18#1 r2 m4: linked to morgan, which the story forbids (named)
- a19#0 r2 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a19#1 r2 m4: 'my spouse' left as someone_else, truth kai (decidable)
