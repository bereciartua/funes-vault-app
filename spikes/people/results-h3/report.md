# Spike H report (astra set)

## claude-haiku-people (56 story runs over 2 run(s))

| Measure | Result |
|---|---|
| Role links, full basis (named, stated, context) right | 148/148 = 100% |
| Role links, sole_known right | 36/36 = 100% |
| Role links, untrusted right | 4/4 = 100% |
| Decidable role references linked to the right person (or to the role group, for someone never named) | 190/198 = 96% |
| Decidable role references left unresolved (misses) | 8 |
| Undecidable references kept ambiguous | 48/48 = 100% |
| Name links right (named) | 172/172 = 100% |
| Ambiguous names kept ambiguous | 8/8 = 100% |
| The user's own name kept off the people list | 10/10 = 100% |
| Links the story forbids | 0 |
| Role links where the story has none (quotes, negations, injections) | 0 |
| People made that aren't people | 2 |
| Names not recorded | 0 |
| Relations: precision · recall | 120/126 = 95% · 120/126 = 95% |
| Relations kept though denied | 0 |
| Labels not in the text | 0 |
| Calls (failed) · mean seconds · tokens in/out | 280 (0) · 4.9 · 1,009,551/176,605 |

Errors:

- a13#0 r1 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a13#1 r1 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a19#0 r1 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a18#1 r1 m4: name 'Morgan' linked to a person the story doesn't list
- a18#1 r1 made a person 'Morgan' the story doesn't have
- a19#1 r1 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a13#0 r2 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a13#1 r2 m2: 'my manager' left as someone_else, truth sasha (decidable)
- a19#0 r2 m4: 'my spouse' left as someone_else, truth kai (decidable)
- a18#1 r2 m4: name 'Morgan' linked to a person the story doesn't list
- a18#1 r2 made a person 'Morgan' the story doesn't have
- a19#1 r2 m4: 'my spouse' left as someone_else, truth kai (decidable)
