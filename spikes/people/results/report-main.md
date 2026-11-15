# Spike H report (main set)

## claude-haiku (60 story runs over 2 run(s))

| Measure | Result |
|---|---|
| Role links, full basis (named, stated, context) right | 124/124 = 100% |
| Role links, sole_known right | 16/16 = 100% |
| Role links, untrusted right | 6/6 = 100% |
| Decidable role references linked to the right person (or to the role group, for someone never named) | 154/160 = 96% |
| Decidable role references left unresolved (misses) | 6 |
| Undecidable references kept ambiguous | 10/10 = 100% |
| Name links right (named) | 128/128 = 100% |
| Ambiguous names kept ambiguous | 2/2 = 100% |
| The user's own name kept off the people list | 6/6 = 100% |
| Links the story forbids | 0 |
| Role links where the story has none (quotes, negations, injections) | 0 |
| People made that aren't people | 0 |
| Names not recorded | 1 |
| Relations: precision · recall | 101/105 = 96% · 101/102 = 99% |
| Relations kept though denied | 0 |
| Labels not in the text | 0 |
| Calls (failed) · mean seconds · tokens in/out | 239 (0) · 3.9 · 744,811/101,065 |

Errors:

- s02#0 r1 m2: 'My sister' left as group, truth lucia (decidable)
- s02#0 r2 m2: 'My sister' left as group, truth lucia (decidable)
- s02#1 r2 m2: 'My sister' left as candidates, truth lucia (decidable)
- s04#0 r2 m1: 'My sister' left as group, truth maria (decidable)
- s12#0 r2 m3: name 'Ana' → None (ambiguous), truth anag
- s19#1 r2 m2: 'My brother' left as group, truth luis (decidable)
- s19#1 r2 m1: 'My only brother' left as group, truth luis (decidable)
- s19#1 r2 m1: name 'Luis' not recorded

## claude-opus (60 story runs over 2 run(s))

| Measure | Result |
|---|---|
| Role links, full basis (named, stated, context) right | 129/129 = 100% |
| Role links, sole_known right | 18/18 = 100% |
| Role links, untrusted right | 6/6 = 100% |
| Decidable role references linked to the right person (or to the role group, for someone never named) | 161/162 = 99% |
| Decidable role references left unresolved (misses) | 1 |
| Undecidable references kept ambiguous | 8/8 = 100% |
| Name links right (named) | 130/130 = 100% |
| Ambiguous names kept ambiguous | 2/2 = 100% |
| The user's own name kept off the people list | 6/6 = 100% |
| Links the story forbids | 0 |
| Role links where the story has none (quotes, negations, injections) | 0 |
| People made that aren't people | 0 |
| Names not recorded | 0 |
| Relations: precision · recall | 100/102 = 98% · 100/102 = 98% |
| Relations kept though denied | 0 |
| Labels not in the text | 0 |
| Calls (failed) · mean seconds · tokens in/out | 238 (0) · 4.3 · 733,584/62,795 |

Errors:

- s04#0 r1 m1: 'My sister' left as candidates, truth maria (decidable)

## codex-luna (60 story runs over 2 run(s))

| Measure | Result |
|---|---|
| Role links, full basis (named, stated, context) right | 118/118 = 100% |
| Role links, sole_known right | 19/19 = 100% |
| Role links, untrusted right | 6/6 = 100% |
| Decidable role references linked to the right person (or to the role group, for someone never named) | 151/160 = 94% |
| Decidable role references left unresolved (misses) | 9 |
| Undecidable references kept ambiguous | 10/10 = 100% |
| Name links right (named) | 123/123 = 100% |
| Ambiguous names kept ambiguous | 2/2 = 100% |
| The user's own name kept off the people list | 6/6 = 100% |
| Links the story forbids | 0 |
| Role links where the story has none (quotes, negations, injections) | 0 |
| People made that aren't people | 0 |
| Names not recorded | 3 |
| Relations: precision · recall | 99/108 = 92% · 99/102 = 97% |
| Relations kept though denied | 0 |
| Labels not in the text | 0 |
| Calls (failed) · mean seconds · tokens in/out | 236 (0) · 4.5 · 2,147,647/24,631 |

Errors:

- s02#0 r1 m2: 'My sister' left as group, truth lucia (decidable)
- s02#1 r1 m2: 'My sister' left as candidates, truth lucia (decidable)
- s04#0 r1 m1: 'My sister' left as group, truth maria (decidable)
- s06#0 r1 m4: name 'Ana' not recorded
- s12#0 r1 m3: name 'Ana' → None (ambiguous), truth anag
- s12#0 r1 m4: name 'Ana' → None (ambiguous), truth anas
- s16#0 r1 m1: 'My sister' left as group, truth irene (decidable)
- s02#1 r2 m2: 'My sister' left as group, truth lucia (decidable)
- s04#0 r2 m1: 'My sister' left as group, truth maria (decidable)
- s06#0 r2 m4: name 'Ana' not recorded
- s12#0 r2 m3: name 'Ana' → None (ambiguous), truth anag
- s12#0 r2 m4: name 'Ana' → None (ambiguous), truth anas
- s16#1 r2 m1: 'My sister' left as group, truth irene (decidable)
- s17#0 r2 m2: 'My coworker' left as candidates, truth raj (decidable)
- s26#0 r2 m3: 'My aunt' left as group, truth may (decidable)
- s26#0 r2 m3: name 'May' not recorded

## codex-terra (60 story runs over 2 run(s))

| Measure | Result |
|---|---|
| Role links, full basis (named, stated, context) right | 128/128 = 100% |
| Role links, sole_known right | 14/14 = 100% |
| Role links, untrusted right | 7/7 = 100% |
| Decidable role references linked to the right person (or to the role group, for someone never named) | 156/160 = 98% |
| Decidable role references left unresolved (misses) | 4 |
| Undecidable references kept ambiguous | 10/10 = 100% |
| Name links right (named) | 129/129 = 100% |
| Ambiguous names kept ambiguous | 2/2 = 100% |
| The user's own name kept off the people list | 6/6 = 100% |
| Links the story forbids | 0 |
| Role links where the story has none (quotes, negations, injections) | 0 |
| People made that aren't people | 0 |
| Names not recorded | 0 |
| Relations: precision · recall | 102/104 = 98% · 102/102 = 100% |
| Relations kept though denied | 0 |
| Labels not in the text | 0 |
| Calls (failed) · mean seconds · tokens in/out | 239 (0) · 6.2 · 2,026,942/34,603 |

Errors:

- s04#0 r1 m1: 'My sister' left as candidates, truth maria (decidable)
- s12#0 r1 m4: name 'Ana' → None (ambiguous), truth anas
- s02#0 r2 m2: 'My sister' left as group, truth lucia (decidable)
- s02#1 r2 m2: 'My sister' left as candidates, truth lucia (decidable)
- s16#1 r2 m3: 'My younger sister' left as candidates, truth sis2 (decidable)

