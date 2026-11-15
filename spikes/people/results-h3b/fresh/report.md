# Spike H report (mixed set)

## claude-haiku-separate-h3b (16 story runs over 1 run(s))

| Measure | Result |
|---|---|
| Role links, full basis (named, stated, context) right | 35/35 = 100% |
| Role links, sole_known right | 6/6 = 100% |
| Role links, untrusted right | 7/7 = 100% |
| Decidable role references linked to the right person (or to the role group, for someone never named) | 49/50 = 98% |
| Decidable role references left unresolved (misses) | 1 |
| Undecidable references kept ambiguous | 2/2 = 100% |
| Name links right (named) | 48/48 = 100% |
| Ambiguous names kept ambiguous | 1/1 = 100% |
| The user's own name kept off the people list | 3/4 = 75% |
| Links the story forbids | 0 |
| Role links where the story has none (quotes, negations, injections) | 0 |
| People made that aren't people | 0 |
| Names not recorded | 0 |
| Relations: precision · recall | 41/45 = 91% · 41/44 = 93% |
| Relations kept though denied | 0 |
| Labels not in the text | 0 |
| Calls (failed) · mean seconds · tokens in/out | 177 (0) · 5.3 · 610,885/123,347 |

Errors:

- x08#0 r1 m3: 'my manager' left as someone_else, truth p2 (decidable)
