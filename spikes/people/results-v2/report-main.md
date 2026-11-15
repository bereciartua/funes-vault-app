# Spike H report (main set)

## claude-haiku (60 story runs over 2 run(s))

| Measure | Result |
|---|---|
| Role links, full basis (named, stated, context) right | 128/128 = 100% |
| Role links, sole_known right | 18/18 = 100% |
| Role links, untrusted right | 6/6 = 100% |
| Decidable role references linked to the right person | 152/160 = 95% |
| Decidable role references left unresolved (misses) | 4 |
| Undecidable references kept ambiguous | 10/10 = 100% |
| Name links right (named) | 130/130 = 100% |
| Ambiguous names kept ambiguous | 2/2 = 100% |
| The user's own name kept off the people list | 6/6 = 100% |
| Links the story forbids | 0 |
| Role links where the story has none (quotes, negations, injections) | 0 |
| People made that aren't people | 3 |
| Names not recorded | 0 |
| Relations: precision · recall | 102/109 = 94% · 102/102 = 100% |
| Relations kept though denied | 0 |
| Labels not in the text | 0 |
| Calls (failed) · mean seconds · tokens in/out | 240 (0) · 3.6 · 671,707/114,608 |

Errors:

- s02#0 r1 m2: 'My sister' left as context, truth lucia (decidable)
- s23#0 r1 m1: name 'Pancho' linked to a person the story doesn't list
- s23#0 r1 made a person 'Pancho' the story doesn't have
- s02#0 r2 m2: 'My sister' left as context, truth lucia (decidable)
- s04#0 r2 m1: 'My sister' left as candidates, truth maria (decidable)
- s08#0 r2 m2: 'my dad' left as group, truth ernesto (decidable)
- s19#1 r2 m2: name 'My brother' linked to a person the story doesn't list
- s19#1 r2 made a person 'My brother' the story doesn't have
- s23#0 r2 m3: name 'Notion' linked to a person the story doesn't list
- s23#0 r2 made a person 'Notion' the story doesn't have

## claude-opus (60 story runs over 2 run(s))

| Measure | Result |
|---|---|
| Role links, full basis (named, stated, context) right | 134/134 = 100% |
| Role links, sole_known right | 16/16 = 100% |
| Role links, untrusted right | 6/6 = 100% |
| Decidable role references linked to the right person | 156/161 = 97% |
| Decidable role references left unresolved (misses) | 1 |
| Undecidable references kept ambiguous | 9/9 = 100% |
| Name links right (named) | 130/130 = 100% |
| Ambiguous names kept ambiguous | 2/2 = 100% |
| The user's own name kept off the people list | 6/6 = 100% |
| Links the story forbids | 0 |
| Role links where the story has none (quotes, negations, injections) | 0 |
| People made that aren't people | 0 |
| Names not recorded | 0 |
| Relations: precision · recall | 100/106 = 94% · 100/102 = 98% |
| Relations kept though denied | 0 |
| Labels not in the text | 0 |
| Calls (failed) · mean seconds · tokens in/out | 241 (0) · 3.9 · 667,952/56,815 |

Errors:

- s04#0 r2 m1: 'My sister' left as candidates, truth maria (decidable)

## codex-luna (60 story runs over 2 run(s))

| Measure | Result |
|---|---|
| Role links, full basis (named, stated, context) right | 118/118 = 100% |
| Role links, sole_known right | 18/18 = 100% |
| Role links, untrusted right | 7/7 = 100% |
| Decidable role references linked to the right person | 143/160 = 89% |
| Decidable role references left unresolved (misses) | 13 |
| Undecidable references kept ambiguous | 10/10 = 100% |
| Name links right (named) | 124/124 = 100% |
| Ambiguous names kept ambiguous | 2/2 = 100% |
| The user's own name kept off the people list | 6/6 = 100% |
| Links the story forbids | 0 |
| Role links where the story has none (quotes, negations, injections) | 0 |
| People made that aren't people | 5 |
| Names not recorded | 2 |
| Relations: precision · recall | 100/118 = 85% · 100/102 = 98% |
| Relations kept though denied | 0 |
| Labels not in the text | 0 |
| Calls (failed) · mean seconds · tokens in/out | 242 (0) · 3.8 · 1,930,379/23,059 |

Errors:

- s02#0 r1 m2: 'My sister' left as context, truth lucia (decidable)
- s02#0 r1 m2: name 'Rosario' linked to a person the story doesn't list
- s02#0 r1 m4: name 'Rosario' linked to a person the story doesn't list
- s02#0 r1 made a person 'Rosario' the story doesn't have
- s02#0 r1 made a person 'Rosario' the story doesn't have
- s03#1 r1 m1: 'My sister' left as context, truth sara (decidable)
- s04#0 r1 m1: 'My sister' left as context, truth maria (decidable)
- s06#0 r1 m4: name 'Ana' not recorded
- s09#0 r1 m2: name 'Miso' linked to a person the story doesn't list
- s09#0 r1 made a person 'Miso' the story doesn't have
- s12#0 r1 m3: name 'Ana' → None (ambiguous), truth anag
- s12#0 r1 m4: name 'Ana' → None (ambiguous), truth anas
- s16#1 r1 m1: 'My sister' left as context, truth irene (decidable)
- s16#0 r1 m1: 'My sister' left as context, truth irene (decidable)
- s17#0 r1 m2: 'My coworker' left as context, truth raj (decidable)
- s02#0 r2 m2: 'My sister' left as context, truth lucia (decidable)
- s02#0 r2 m2: name 'Rosario' linked to a person the story doesn't list
- s02#0 r2 made a person 'Rosario' the story doesn't have
- s02#1 r2 m2: 'My sister' left as candidates, truth lucia (decidable)
- s03#0 r2 m1: 'My sister' left as candidates, truth sara (decidable)
- s03#0 r2 m3: 'My sister' left as candidates, truth sara (decidable)
- s04#0 r2 m1: 'My sister' left as context, truth maria (decidable)
- s06#0 r2 m4: name 'Ana' not recorded
- s09#0 r2 m2: name 'Miso' linked to a person the story doesn't list
- s09#0 r2 made a person 'Miso' the story doesn't have
- s12#0 r2 m3: name 'Ana' → None (ambiguous), truth anag
- s12#0 r2 m4: name 'Ana' → None (ambiguous), truth anas
- s17#0 r2 m2: 'My coworker' left as context, truth raj (decidable)
- s19#0 r2 m2: 'My brother' left as context, truth luis (decidable)

## codex-terra (60 story runs over 2 run(s))

| Measure | Result |
|---|---|
| Role links, full basis (named, stated, context) right | 131/131 = 100% |
| Role links, sole_known right | 14/14 = 100% |
| Role links, untrusted right | 6/6 = 100% |
| Decidable role references linked to the right person | 151/160 = 94% |
| Decidable role references left unresolved (misses) | 5 |
| Undecidable references kept ambiguous | 10/10 = 100% |
| Name links right (named) | 128/128 = 100% |
| Ambiguous names kept ambiguous | 2/2 = 100% |
| The user's own name kept off the people list | 6/6 = 100% |
| Links the story forbids | 0 |
| Role links where the story has none (quotes, negations, injections) | 0 |
| People made that aren't people | 0 |
| Names not recorded | 0 |
| Relations: precision · recall | 102/110 = 93% · 102/102 = 100% |
| Relations kept though denied | 0 |
| Labels not in the text | 0 |
| Calls (failed) · mean seconds · tokens in/out | 241 (0) · 5.6 · 1,755,474/33,966 |

Errors:

- s04#0 r1 m1: 'My sister' left as candidates, truth maria (decidable)
- s03#1 r2 m3: 'My sister' left as candidates, truth sara (decidable)
- s03#1 r2 m1: 'My sister' left as context, truth sara (decidable)
- s04#0 r2 m1: 'My sister' left as context, truth maria (decidable)
- s12#0 r2 m3: name 'Ana' → None (ambiguous), truth anag
- s12#0 r2 m4: name 'Ana' → None (ambiguous), truth anas
- s16#1 r2 m3: 'My younger sister' left as candidates, truth sis2 (decidable)

