# Retired: 13e.2's second timeline gate set (r2)

GPT-6-Astra wrote this set fresh after r1 was retired (23 November 2026). On it neither engine passed: decidable right
was 27 of 61 (44%) for both, Haiku skipped 3 owed checks, and the read had 26 wrong facts (results in
`results-13e2/retired-r2/`). Almost all of them had one cause: shared fillers led the read to record a trusted, undated
job at an organization named "work", and that row was in nearly every timeline answer's prompt, so most decidable
questions became "can't tell which job you had". Fix round 3 dropped workplace words as organization names and fixed two
smaller time-model cases. The set was then read while diagnosing and rehearsing them (a live read seeded with its
recorded calls, live answers, judging), so it was retired and Astra wrote a fresh set from scratch. Kept as the record;
nothing discovers it (the gate, the judges and the checks read `fixtures/gate-13e2/`).
