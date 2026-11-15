# Spike H report (canary set)

## claude-haiku-people-h3b-canary (16 story runs over 1 run(s))

| Measure | Result |
|---|---|
| Role links, full basis (named, stated, context) right | 49/49 = 100% |
| Role links, sole_known right | 3/3 = 100% |
| Role links, untrusted right | 4/4 = 100% |
| Decidable role references linked to the right person (or to the role group, for someone never named) | 56/58 = 97% |
| Decidable role references left unresolved (misses) | 2 |
| Undecidable references kept ambiguous | 2/2 = 100% |
| Name links right (named) | 78/78 = 100% |
| Ambiguous names kept ambiguous | – |
| The user's own name kept off the people list | – |
| Links the story forbids | 0 |
| Role links where the story has none (quotes, negations, injections) | 0 |
| People made that aren't people | 0 |
| Names not recorded | 1 |
| Relations: precision · recall | 46/46 = 100% · 46/46 = 100% |
| Relations kept though denied | 0 |
| Labels not in the text | 0 |
| Calls (failed) · mean seconds · tokens in/out | 73 (0) · 4.5 · 278,363/45,926 |

Errors:

- c04#0 r1 c04_m4: name 'Quinn' → None (ambiguous), truth c04_quinn
- c04#0 r1 c04_m4: name 'Riley' → None (ambiguous), truth c04_riley
- c04#1 r1 c04_m4: name 'Quinn' → None (ambiguous), truth c04_quinn
- c04#1 r1 c04_m4: name 'Riley' → None (ambiguous), truth c04_riley
- c07#0 r1 c07_m5: 'my boyfriend' left as someone_else, truth c07_sam (decidable)
- c07#1 r1 c07_m5: 'my boyfriend' left as someone_else, truth c07_sam (decidable)
- c08#0 r1 c08_m4: name 'Petra' not recorded
