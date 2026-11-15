# Spike H report (canary set)

## claude-haiku-people-canary (32 story runs over 2 run(s))

| Measure | Result |
|---|---|
| Role links, full basis (named, stated, context) right | 99/99 = 100% |
| Role links, sole_known right | 5/5 = 100% |
| Role links, untrusted right | 8/8 = 100% |
| Decidable role references linked to the right person (or to the role group, for someone never named) | 112/116 = 97% |
| Decidable role references left unresolved (misses) | 4 |
| Undecidable references kept ambiguous | 4/4 = 100% |
| Name links right (named) | 157/157 = 100% |
| Ambiguous names kept ambiguous | – |
| The user's own name kept off the people list | – |
| Links the story forbids | 0 |
| Role links where the story has none (quotes, negations, injections) | 0 |
| People made that aren't people | 0 |
| Names not recorded | 1 |
| Relations: precision · recall | 92/93 = 99% · 92/92 = 100% |
| Relations kept though denied | 0 |
| Labels not in the text | 0 |
| Calls (failed) · mean seconds · tokens in/out | 148 (0) · 4.5 · 572,131/91,773 |

Errors:

- c04#0 r1 c04_m4: name 'Quinn' → None (ambiguous), truth c04_quinn
- c04#0 r1 c04_m4: name 'Riley' → None (ambiguous), truth c04_riley
- c04#0 r1 c04_m2: name 'Quinn' not recorded
- c04#1 r1 c04_m4: name 'Quinn' → None (ambiguous), truth c04_quinn
- c04#1 r1 c04_m4: name 'Riley' → None (ambiguous), truth c04_riley
- c07#0 r1 c07_m5: 'my boyfriend' left as someone_else, truth c07_sam (decidable)
- c07#1 r1 c07_m5: 'my boyfriend' left as someone_else, truth c07_sam (decidable)
- c04#0 r2 c04_m4: name 'Quinn' → None (ambiguous), truth c04_quinn
- c04#0 r2 c04_m4: name 'Riley' → None (ambiguous), truth c04_riley
- c07#0 r2 c07_m5: 'my boyfriend' left as someone_else, truth c07_sam (decidable)
- c07#1 r2 c07_m5: 'my boyfriend' left as someone_else, truth c07_sam (decidable)
