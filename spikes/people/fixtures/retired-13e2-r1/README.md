# Retired: 13e.2's first timeline gate set (r1)

GPT-6-Astra wrote this set after the gate's code freeze (22 November 2026). On it neither engine passed: too many marked wrong
answers (Haiku 3, GPT-5.6-Terra 4), owed checks skipped (20, 11), inferred claims unmarked (8, 6), and Haiku's
undecidable "not sure" at 83% (results in `results-13e2/retired-r1/`). The fix round changed the time model and the answer checks, and this set had been read
while diagnosing them (rehearsals replaying its cached responses), so it was retired and Astra wrote a fresh set from
scratch. Kept as the record; nothing discovers it (the gate, the judges and the checks read `fixtures/gate-13e2/`).
