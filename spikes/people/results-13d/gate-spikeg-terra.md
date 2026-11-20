# 13d gate: Spike G with the feature on (terra)

P plain (13b), F learned facts (attributes on); Spike G's scorer and labels; answerable if either arm sent the answer's memory. Latency isn't gated here.

| Arm | Set | Correct claims | Right "no answer" | Answered (answerable) | Wrong | Unmatched |
|---|---|---|---|---|---|---|
| P | main | 37/37 (100%) | 6/6 (100%) | 35/36 (97%) | 0 | 0 |
| F | main | 38/38 (100%) | 6/6 (100%) | 36/36 (100%) | 0 | 0 |
| P | astra | 14/14 (100%) | 7/7 (100%) | 13/13 (100%) | 0 | 0 |
| F | astra | 15/15 (100%) | 7/7 (100%) | 13/13 (100%) | 0 | 0 |

## Gate (F, both sets)

- PASS: complete
- PASS: correct claims ≥ 95%
- PASS: right "no answer" ≥ 90%
- PASS: answered ≥ 80% of answerable
- PASS: no new wrong claims
- PASS: no claim left unlabelled (both arms)

## To review

- nothing
