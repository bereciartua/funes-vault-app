# Spike H report (astra set)

## claude-haiku (56 story runs over 2 run(s))

| Measure | Result |
|---|---|
| Role links, full basis (named, stated, context) right | 153/153 = 100% |
| Role links, sole_known right | 31/31 = 100% |
| Role links, untrusted right | 4/4 = 100% |
| Decidable role references linked to the right person (or to the role group, for someone never named) | 190/198 = 96% |
| Decidable role references left unresolved (misses) | 8 |
| Undecidable references kept ambiguous | 48/48 = 100% |
| Name links right (named) | 170/170 = 100% |
| Ambiguous names kept ambiguous | 7/8 = 88% |
| The user's own name kept off the people list | 10/10 = 100% |
| Links the story forbids | 0 |
| Role links where the story has none (quotes, negations, injections) | 0 |
| People made that aren't people | 2 |
| Names not recorded | 4 |
| Relations: precision · recall | 118/125 = 94% · 118/126 = 94% |
| Relations kept though denied | 0 |
| Labels not in the text | 0 |
| Calls (failed) · mean seconds · tokens in/out | 281 (0) · 3.9 · 877,575/145,537 |

Errors:

- a11#0 r1 m2: name 'Ren' not recorded
- a13#0 r1 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a13#1 r1 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a19#0 r1 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a18#1 r1 m4: name 'Morgan' linked to a person the story doesn't list
- a18#1 r1 made a person 'Morgan' the story doesn't have
- a19#1 r1 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a11#0 r2 m2: name 'Ren' not recorded
- a13#0 r2 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a13#1 r2 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a15#1 r2 m2: ambiguous 'Alex' → Alex
- a19#0 r2 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a19#0 r2 m2: name 'Kai' not recorded
- a18#1 r2 m4: name 'Morgan' linked to a person the story doesn't list
- a18#1 r2 made a person 'Morgan' the story doesn't have
- a19#1 r2 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a19#1 r2 m2: name 'Kai' not recorded

## claude-opus (56 story runs over 2 run(s))

| Measure | Result |
|---|---|
| Role links, full basis (named, stated, context) right | 150/150 = 100% |
| Role links, sole_known right | 32/32 = 100% |
| Role links, untrusted right | 4/4 = 100% |
| Decidable role references linked to the right person (or to the role group, for someone never named) | 188/198 = 95% |
| Decidable role references left unresolved (misses) | 10 |
| Undecidable references kept ambiguous | 48/48 = 100% |
| Name links right (named) | 172/172 = 100% |
| Ambiguous names kept ambiguous | 5/8 = 62% |
| The user's own name kept off the people list | 10/10 = 100% |
| Links the story forbids | 0 |
| Role links where the story has none (quotes, negations, injections) | 0 |
| People made that aren't people | 2 |
| Names not recorded | 0 |
| Relations: precision · recall | 117/125 = 94% · 117/126 = 93% |
| Relations kept though denied | 0 |
| Labels not in the text | 0 |
| Calls (failed) · mean seconds · tokens in/out | 280 (0) · 4.4 · 866,728/68,254 |

Errors:

- a13#0 r1 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a13#1 r1 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a15#1 r1 m2: ambiguous 'Alex' → Alex
- a15#1 r1 m4: ambiguous 'Alex' → Alex
- a18#1 r1 m4: name 'Morgan' linked to a person the story doesn't list
- a18#1 r1 made a person 'Morgan' the story doesn't have
- a19#0 r1 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a19#1 r1 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a13#0 r2 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a13#1 r2 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a15#1 r2 m2: ambiguous 'Alex' → Alex
- a19#0 r2 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a18#1 r2 m4: name 'Morgan' linked to a person the story doesn't list
- a18#1 r2 made a person 'Morgan' the story doesn't have
- a19#1 r2 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a19#1 r2 m3: 'My partner' left as group, truth rowan (decidable)
- a19#1 r2 m1: 'my only partner' left as group, truth rowan (decidable)

## codex-luna (56 story runs over 2 run(s))

| Measure | Result |
|---|---|
| Role links, full basis (named, stated, context) right | 156/156 = 100% |
| Role links, sole_known right | 25/25 = 100% |
| Role links, untrusted right | 4/4 = 100% |
| Decidable role references linked to the right person (or to the role group, for someone never named) | 187/198 = 94% |
| Decidable role references left unresolved (misses) | 11 |
| Undecidable references kept ambiguous | 48/48 = 100% |
| Name links right (named) | 169/169 = 100% |
| Ambiguous names kept ambiguous | 4/5 = 80% |
| The user's own name kept off the people list | 10/10 = 100% |
| Links the story forbids | 0 |
| Role links where the story has none (quotes, negations, injections) | 0 |
| People made that aren't people | 4 |
| Names not recorded | 5 |
| Relations: precision · recall | 117/125 = 94% · 117/126 = 93% |
| Relations kept though denied | 0 |
| Labels not in the text | 0 |
| Calls (failed) · mean seconds · tokens in/out | 290 (0) · 4.2 · 2,504,036/32,111 |

Errors:

- a04#1 r1 m2: 'My friend' left as candidates, truth luz (decidable)
- a13#0 r1 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a13#1 r1 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a15#0 r1 m3: name 'Alex' → None (ambiguous), truth alex_kim
- a15#0 r1 m4: name 'Alex' not recorded
- a15#1 r1 m4: name 'Alex' not recorded
- a18#0 r1 m4: name 'Morgan' linked to a person the story doesn't list
- a18#0 r1 made a person 'Morgan' the story doesn't have
- a19#0 r1 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a18#1 r1 m4: name 'Morgan' linked to a person the story doesn't list
- a18#1 r1 made a person 'Morgan' the story doesn't have
- a19#1 r1 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a11#0 r2 m2: name 'Ren' not recorded
- a11#1 r2 m3: 'My mother-in-law' left as group, truth hana (decidable)
- a11#1 r2 m2: 'my mother-in-law' left as group, truth hana (decidable)
- a13#0 r2 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a13#1 r2 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a15#0 r2 m3: name 'Alex' → None (ambiguous), truth alex_kim
- a15#1 r2 m2: ambiguous 'Alex' → Alex
- a15#1 r2 m4: name 'Alex' not recorded
- a18#0 r2 m4: name 'Morgan' linked to a person the story doesn't list
- a18#0 r2 made a person 'Morgan' the story doesn't have
- a19#0 r2 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a18#1 r2 m4: name 'Morgan' linked to a person the story doesn't list
- a18#1 r2 made a person 'Morgan' the story doesn't have
- a19#1 r2 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a19#1 r2 m2: name 'Kai' not recorded

## codex-terra (56 story runs over 2 run(s))

| Measure | Result |
|---|---|
| Role links, full basis (named, stated, context) right | 150/152 = 99% |
| Role links, sole_known right | 30/30 = 100% |
| Role links, untrusted right | 4/4 = 100% |
| Decidable role references linked to the right person (or to the role group, for someone never named) | 185/198 = 93% |
| Decidable role references left unresolved (misses) | 12 |
| Undecidable references kept ambiguous | 47/48 = 98% |
| Name links right (named) | 171/171 = 100% |
| Ambiguous names kept ambiguous | 5/8 = 62% |
| The user's own name kept off the people list | 10/10 = 100% |
| Links the story forbids | 0 |
| Role links where the story has none (quotes, negations, injections) | 0 |
| People made that aren't people | 0 |
| Names not recorded | 0 |
| Relations: precision · recall | 118/122 = 97% · 118/126 = 94% |
| Relations kept though denied | 0 |
| Labels not in the text | 0 |
| Calls (failed) · mean seconds · tokens in/out | 279 (0) · 6.2 · 2,211,522/42,868 |

Errors:

- a02#0 r1 m3: 'My brother' → Pavel (context), truth brother_b
- a04#0 r1 m2: 'My friend' left as group, truth luz (decidable)
- a04#1 r1 m2: 'My friend' left as group, truth luz (decidable)
- a09#0 r1 m1: 'my only therapist' → Jo (stated_unique), truth ren
- a13#0 r1 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a13#1 r1 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a15#0 r1 m3: name 'Alex' → None (ambiguous), truth alex_kim
- a15#1 r1 m2: ambiguous 'Alex' → Alex
- a19#0 r1 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a19#1 r1 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a04#0 r2 m2: 'My friend' left as group, truth luz (decidable)
- a04#1 r2 m2: 'My friend' left as group, truth luz (decidable)
- a13#0 r2 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a13#1 r2 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a15#1 r2 m2: ambiguous 'Alex' → Alex
- a15#1 r2 m4: ambiguous 'Alex' → Alex
- a19#0 r2 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a19#1 r2 m4: 'my spouse' left as someone_else, truth kai (decidable)

