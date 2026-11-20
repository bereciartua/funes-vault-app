# 13d gate: Spike G with the feature on (haiku)

P plain (13b), F learned facts (attributes on); Spike G's scorer and labels; answerable if either arm sent the answer's memory. Latency isn't gated here.

| Arm | Set | Correct claims | Right "no answer" | Answered (answerable) | Wrong | Unmatched |
|---|---|---|---|---|---|---|
| P | main | 47/47 (100%) | 6/6 (100%) | 35/36 (97%) | 0 | 0 |
| F | main | 47/47 (100%) | 6/6 (100%) | 36/36 (100%) | 0 | 0 |
| P | astra | 17/17 (100%) | 7/7 (100%) | 12/13 (92%) | 0 | 0 |
| F | astra | 19/19 (100%) | 7/7 (100%) | 12/13 (92%) | 0 | 0 |

## Gate (F, both sets)

- PASS: complete
- PASS: correct claims ≥ 95%
- PASS: right "no answer" ≥ 90%
- PASS: answered ≥ 80% of answerable
- PASS: no new wrong claims
- PASS: no claim left unlabelled (both arms)

## To review

- nothing
