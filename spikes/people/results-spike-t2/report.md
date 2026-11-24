# Spike T round 2

Prompts 57cdfc7982fd; set workr; top 10 of each story's memories plus 40 fillers (BM25).

| engine | arm | decidable right / n | decidable wrong | undecidable not sure / n | undecidable wrong | negatives right / wrong / n |
|---|---|---|---|---|---|---|
| haiku | A | 23 / 28 | 0 | 26 / 28 | 2 | 27 / 0 / 28 |
| haiku | B | 28 / 28 | 0 | 27 / 28 | 1 | 24 / 2 / 28 |
| haiku | Bc-gold | 28 / 28 | 0 | 27 / 28 | 1 | 24 / 2 / 28 |
| haiku | Bc-live | 26 / 28 | 0 | 27 / 28 | 1 | 24 / 2 / 28 |
| haiku | C | 20 / 28 | 0 | 27 / 28 | 1 | 27 / 0 / 28 |
| terra | A | 25 / 28 | 0 | 12 / 28 | 16 | 27 / 0 / 28 |
| terra | B | 28 / 28 | 0 | 18 / 28 | 10 | 27 / 0 / 28 |
| terra | Bc-gold | 27 / 28 | 0 | 27 / 28 | 1 | 27 / 0 / 28 |
| terra | Bc-live | 25 / 28 | 0 | 27 / 28 | 1 | 27 / 0 / 28 |
| terra | C | 23 / 28 | 0 | 13 / 28 | 15 | 27 / 0 / 28 |

## How the check decided (arm B's answers)

- haiku gold dec: agrees 25, agrees_without_agent 1, unchecked 2
- haiku gold neg: no_answer 26, unchecked 2
- haiku gold und: agrees 1, no_answer 27
- haiku live dec: agrees 23, agrees_without_agent 1, cant_tell 2, unchecked 2
- haiku live neg: no_answer 26, unchecked 2
- haiku live und: agrees 1, no_answer 27
- terra gold dec: agrees 24, agrees_without_agent 3, cant_tell 1
- terra gold neg: no_answer 18, unchecked 6, unparsed 4
- terra gold und: agrees 1, cant_tell 9, no_answer 18
- terra live dec: agrees 22, agrees_without_agent 3, cant_tell 3
- terra live neg: no_answer 18, unchecked 6, unparsed 4
- terra live und: agrees 1, cant_tell 9, no_answer 18

## Latency (ms, p50 / p95)

- haiku A: 4341 / 6646 (84)
- haiku B: 5259 / 8224 (84)
- terra A: 4691 / 8226 (84)
- terra B: 6080 / 9867 (84)

## Wrong answers

### haiku A (2)
- r02 q3 (before): Where did I work before Alder Labs?
- r05 q3 (before): ¿Qué trabajo tuve antes de Sol Works?
### haiku B (3)
- r03 q5 (negative): ¿Qué guardé después de salir de Fern Press?
- r08 q3 (before): My job before Drift Games?
- r10 q7 (role_in_stint): What was my Silver Foods title in 2019?
### haiku Bc-gold (3)
- r03 q5 (negative): ¿Qué guardé después de salir de Fern Press?
- r08 q3 (before): My job before Drift Games?
- r10 q7 (role_in_stint): What was my Silver Foods title in 2019?
### haiku Bc-live (3)
- r03 q5 (negative): ¿Qué guardé después de salir de Fern Press?
- r08 q3 (before): My job before Drift Games?
- r10 q7 (role_in_stint): What was my Silver Foods title in 2019?
### haiku C (1)
- r05 q3 (before): ¿Qué trabajo tuve antes de Sol Works?
### terra A (16)
- r01 q3 (year): Where was I employed on 2 January 2014?
- r02 q7 (after): What came after my Alder Labs job?
- r03 q3 (year): ¿Dónde trabajaba el 10 de mayo de 2019?
- r03 q7 (before): What employer preceded Fern House on my CV?
- r04 q3 (year): Where was my day job on 15 January 2018?
- r04 q4 (year): Who employed me on 10 March 2023?
- r04 q7 (year): Which freelance business was active on 15 December 2024?
- r05 q3 (before): ¿Qué trabajo tuve antes de Sol Works?
- r06 q3 (year): Where did I work on 3 January 2018?
- r07 q3 (year): Who employed me on 6 January 2014?
- r07 q4 (year): ¿Qué negocio freelance tenía activo el 15 de junio de 2023?
- r08 q4 (year): Where did I work on 15 May 2016?
- r09 q3 (year): ¿Dónde estaba trabajando el 12 de marzo de 2017?
- r10 q4 (year): Which freelance business was I running on 5 March 2019?
- r11 q3 (after): ¿Dónde trabajé después de Alta Energia?
- r12 q3 (year): Who employed me on 4 January 2014?
### terra B (10)
- r01 q3 (year): Where was I employed on 2 January 2014?
- r02 q3 (before): Where did I work before Alder Labs?
- r03 q3 (year): ¿Dónde trabajaba el 10 de mayo de 2019?
- r04 q3 (year): Where was my day job on 15 January 2018?
- r04 q4 (year): Who employed me on 10 March 2023?
- r05 q4 (year): ¿Quién me empleaba el 20 de junio de 2016?
- r07 q3 (year): Who employed me on 6 January 2014?
- r09 q3 (year): ¿Dónde estaba trabajando el 12 de marzo de 2017?
- r10 q4 (year): Which freelance business was I running on 5 March 2019?
- r12 q3 (year): Who employed me on 4 January 2014?
### terra Bc-gold (1)
- r02 q3 (before): Where did I work before Alder Labs?
### terra Bc-live (1)
- r02 q3 (before): Where did I work before Alder Labs?
### terra C (15)
- r01 q3 (year): Where was I employed on 2 January 2014?
- r02 q7 (after): What came after my Alder Labs job?
- r03 q3 (year): ¿Dónde trabajaba el 10 de mayo de 2019?
- r03 q7 (before): What employer preceded Fern House on my CV?
- r04 q3 (year): Where was my day job on 15 January 2018?
- r04 q4 (year): Who employed me on 10 March 2023?
- r04 q7 (year): Which freelance business was active on 15 December 2024?
- r05 q3 (before): ¿Qué trabajo tuve antes de Sol Works?
- r06 q3 (year): Where did I work on 3 January 2018?
- r07 q3 (year): Who employed me on 6 January 2014?
- r07 q4 (year): ¿Qué negocio freelance tenía activo el 15 de junio de 2023?
- r08 q4 (year): Where did I work on 15 May 2016?
- r09 q3 (year): ¿Dónde estaba trabajando el 12 de marzo de 2017?
- r10 q4 (year): Which freelance business was I running on 5 March 2019?
- r12 q3 (year): Who employed me on 4 January 2014?
