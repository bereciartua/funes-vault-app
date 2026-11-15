# Spike H report (main set)

## claude-haiku (60 story runs over 2 run(s))

| Measure | Result |
|---|---|
| Role links, full basis (named, stated, context) right | 126/126 = 100% |
| Role links, sole_known right | 16/16 = 100% |
| Role links, untrusted right | 6/6 = 100% |
| Decidable role references linked to the right person (or to the role group, for someone never named) | 156/160 = 98% |
| Decidable role references left unresolved (misses) | 4 |
| Undecidable references kept ambiguous | 10/10 = 100% |
| Name links right (named) | 129/129 = 100% |
| Ambiguous names kept ambiguous | 2/2 = 100% |
| The user's own name kept off the people list | 6/6 = 100% |
| Links the story forbids | 0 |
| Role links where the story has none (quotes, negations, injections) | 0 |
| People made that aren't people | 1 |
| Names not recorded | 0 |
| Relations: precision · recall | 102/106 = 96% · 102/102 = 100% |
| Relations kept though denied | 0 |
| Labels not in the text | 0 |
| Calls (failed) · mean seconds · tokens in/out | 238 (0) · 3.9 · 758,080/108,522 |

Errors:

- s02#0 r1 m2: 'My sister' left as group, truth lucia (decidable)
- s02#1 r1 m2: 'My sister' left as candidates, truth lucia (decidable)
- s12#0 r1 m4: name 'Ana' → None (ambiguous), truth anas
- s02#1 r2 m2: 'My sister' left as candidates, truth lucia (decidable)
- s04#0 r2 m1: 'My sister' left as candidates, truth maria (decidable)
- s16#1 r2 m1: name 'Spotify' linked to a person the story doesn't list
- s16#1 r2 made a person 'Spotify' the story doesn't have
