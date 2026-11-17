# Phase 13a.2: the Swift pipeline live on the mixed fixture (16 November 2026)

The first live run of the Swift pipeline (`FactsExtractor` through `ModelRouter`) on a spike fixture, with the author's
go-ahead: `spikes/people/fixtures/stories-mixed.json`, every story in every order (16 plays), both call groups, Claude
Haiku through `claude -p` at low effort, as the spike's fresh H3b run (`results-h3b/fresh/claude-haiku-separate-h3b`).
One run each, so differences within a few references are run-to-run variation as much as anything.

    FUNES_FACTS_HARNESS_LIVE=1 sh scripts/facts_harness.sh mixed "live=claude:haiku;executable=$(which claude)"

## score.py (people)

| Measure | Spike, fresh H3b run | Swift, live |
|---|---|---|
| Role links, full basis (named, stated, context) right | 35/35 = 100% | 31/31 = 100% |
| Role links, sole_known right | 6/6 = 100% | 7/9 = 78% |
| Role links, untrusted right | 7/7 = 100% | 7/7 = 100% |
| Decidable role references linked to the right person (or to the role group, for someone never named) | 49/50 = 98% | 46/50 = 92% |
| Decidable role references left unresolved (misses) | 1 | 3 |
| Undecidable references kept ambiguous | 2/2 = 100% | 1/2 = 50% |
| Name links right (named) | 48/48 = 100% | 47/47 = 100% |
| Ambiguous names kept ambiguous | 1/1 = 100% | 1/1 = 100% |
| The user's own name kept off the people list | 3/4 = 75% | 4/4 = 100% |
| Links the story forbids | 0 | 2 |
| Role links where the story has none (quotes, negations, injections) | 0 | 0 |
| People made that aren't people | 0 | 0 |
| Names not recorded | 0 | 1 |
| Relations: precision · recall | 41/45 = 91% · 41/44 = 93% | 42/45 = 93% · 42/44 = 95% |
| Relations kept though denied | 0 | 0 |
| Labels not in the text | 0 | 0 |
| Calls (failed) · mean seconds · tokens in/out | 177 (0) · 5.3 · 610,885/123,347 | 230 (0) · 2.0 · 746,626/167,712 |

Swift errors:

- x08#0 r1 m3: 'my manager' left as someone_else, truth p2 (decidable)
- x08#0 r1 m6: 'My new manager' left as candidates, truth p5 (decidable)
- x09#0 r1 m1: 'My manager' → Karim Rook (sole_known), truth p1
- x09#0 r1 m3: 'My manager' → Karim Rook (sole_known), truth p3
- x09#0 r1 m1: name 'Elise Vale' not recorded
- x09#0 r1 m1: linked to p2, which the story forbids (sole_known)
- x09#0 r1 m3: linked to p2, which the story forbids (sole_known)
- x09#1 r1 m1: 'My manager' left as candidates, truth p1 (decidable)

## score_facts.py stories (the Python time model on each run's state)

| | Spike, fresh H3b run | Swift, live |
|---|---|---|
| Per play | quiet 16, right 20, right_gap 5, told 4, told_decidable 3 | quiet 16, right 17, right_gap 4, told 4, told_decidable 7 |
| Per distinct question (of 30) | quiet 10, right 13, right_gap 2, told 2, told_decidable 1, varies 2 | quiet 10, right 12, right_gap 2, told 2, told_decidable 3, varies 1 |
| Organizations | employers 47/47; 0 clients or vendors misfiled | employers 47/47; 0 clients or vendors misfiled |

The Swift time model on the Swift run (`swift_judged` in each line): right 12, right_gap 2, told 2, told_decidable 3,
no intent 11 (13a.1's grammar fails closed), told_no_intent 2, quiet 16; **0 wrong, 0 negative triggers**.

## What the run shows

- **Full-basis links 31/31 right, relation recall 95%, names 47/47, 0 people that aren't people, 0 misfiled
  organizations.**
- **Two wrong `sole_known` links (x09#0), from a re-read erasing a good reading.** Swift's first reading of m1 recorded
  "Elise Vale" as the manager. A later reconciliation re-read returned quotes that didn't match the text, validation
  dropped the person and the fact, and since a re-read replaces that memory version's whole reading in its call group,
  Elise was gone; "My manager" then resolved to the one manager left, Karim Rook, at `sole_known`. The spike's re-asks
  applied only the roles (or only the names), so a worse re-read never erased what the first one found.
- **More calls: 230 against 177.** 13a.1 invalidates a model decision whenever a fact of its predicate changes, so the
  harness's reconciliation re-asks memories the spike didn't (x09#0 re-read m1 twice and m2 twice; the spike, none).
- Both point at reconciliation's scope, which the queue step owns: a reconciliation call should change only what it
  was asked about (roles, or names), as in the spike.
