# Spike F spot-check

30 random pieces (6 each from variants A, A+, B, C3 and D, all four extractors), with what the blind reader (codex) understood and the grader's verdict. The original memories are in `fixtures/episodes.json`. Fill in the last column: agree or disagree with the verdict.

### 1. e11 (Interview loop at Verdant Grid (Staff Data Engineer)) — variant A, claude-haiku

> Negotiation target if offered: If I get an offer, I would negotiate for 100,000 DKK a month.

- Reader: about **Unspecified role or offer negotiation**; when **unclear**; current unclear; asks: Which role or offer does this negotiation target concern?
- Grader: **missing_context** (subject); lasting: True. The role or company is omitted; the original ties this conditional negotiation target to Verdant Grid’s Staff Data Engineer role.
- Your verdict: 

### 2. e07 (Oakhurst Media contract terms) — variant A, codex-sol

> Oakhurst portfolio permission: I retain the right to mention Oakhurst Media as a client in my portfolio.

- Reader: about **Oakhurst Media portfolio permission**; when **lasting**; current yes; asks: –
- Grader: **pass** ; lasting: True. The lasting portfolio permission is accurately understood.
- Your verdict: 

### 3. e12 (Recruiter call about a CTO role) — variant A, codex-terra

> Positive view of founders' background: I see Lumen Health's founders having previously worked together at a hospital software company as a good sign for the product.

- Reader: about **Lumen Health’s founders**; when **unclear**; current unclear; asks: –
- Grader: **pass** ; lasting: True. The founders, their prior collaboration, and the user's positive view are clear.
- Your verdict: 

### 4. e10 (Boda de Lucía (junio de 2027)) — variant A, claude-haiku

> Cena de boda para unas 120 personas: La cena posterior a la ceremonia de la boda será para unas 120 personas.

- Reader: about **The user's wedding reception**; when **future; date unclear**; current unclear; asks: Has the wedding dinner happened, or is the plan still current?
- Grader: **missing_context** (subject, time); lasting: False. The reading calls it the user's reception without establishing that it is Lucía and Tomás's wedding dinner, and omits the wedding date.
- Your verdict: 

### 5. e11 (Interview loop at Verdant Grid (Staff Data Engineer)) — variant A, claude-opus

> Expecting interview result by Friday next week: I expect to hear back about the Staff Data Engineer role by Friday next week.

- Reader: about **The user’s Staff Data Engineer application**; when **Unclear; relative date in the original note**; current unclear; asks: Which Friday did you mean, and have you heard back?
- Grader: **missing_context** (time); lasting: True. “Friday next week” has no anchor date in the piece.
- Your verdict: 

### 6. e04 (Japan trip, April 2026) — variant A, codex-terra

> Favourite meal at Tenkuu: My favourite meal was at a tempura counter in Osaka called Tenkuu.

- Reader: about **The user's favourite meal at Tenkuu in Osaka**; when **unclear**; current unclear; asks: When did you eat there, and is it still your favourite meal?
- Grader: **missing_context** (time); lasting: True. The reading leaves unclear which trip the meal was part of; the original places it on the April 2026 Japan trip.
- Your verdict: 

### 7. e12 (Recruiter call about a CTO role) — variant A+, codex-terra

> Hybrid Porto requirement: The Lumen Health CTO role is hybrid, with two days a week in the Porto office.

- Reader: about **Lumen Health CTO role**; when **unclear**; current unclear; asks: Is this still the current arrangement?
- Grader: **missing_context** (time, status); lasting: False. The arrangement is accurately stated but not identified as a requirement for the prospective CTO role.
- Your verdict: 

### 8. e07 (Oakhurst Media contract terms) — variant A+, codex-terra

> Oakhurst initial rate offer: Oakhurst Media initially offered me a day rate of €650.

- Reader: about **The user's negotiations with Oakhurst Media**; when **unclear**; current unclear; asks: Is the Oakhurst opportunity or negotiation still active?
- Grader: **pass** ; lasting: False. Correctly reads this as an initial offer, not the agreed rate; the negotiation was in the past.
- Your verdict: 

### 9. e02 (Confidential recruiter pitch: Head of Platform role (via Brightline Talent)) — variant A+, codex-sol

> Head of Platform base salary: The Head of Platform opportunity offered a base salary of €145,000–€165,000.

- Reader: about **The Head of Platform opportunity**; when **unclear**; current unclear; asks: Is this offer still active, and does the salary range remain accurate?
- Grader: **missing_context** (time); lasting: True. The reading correctly describes the salary range but does not date the opportunity terms.
- Your verdict: 

### 10. e01 (Halvorsen Robotics hiring process (Senior Firmware Engineer)) — variant A+, claude-haiku

> Halvorsen role requires one on-site week per quarter: The Senior Firmware Engineer position at Halvorsen Robotics requires one on-site week in Trondheim per quarter.

- Reader: about **Senior Firmware Engineer position at Halvorsen Robotics**; when **unclear**; current unclear; asks: Is this position description still current?
- Grader: **missing_context** (time); lasting: True. Correct requirement and role, but leaves unclear when this role description applied.
- Your verdict: 

### 11. e08 (New flat in Arroios) — variant A+, claude-haiku

> Graça flat handback deadline: I have to hand back my current flat in Graça by 15 November 2026.

- Reader: about **The user's current flat in Graça**; when **15 November 2026**; current yes; asks: –
- Grader: **pass** ; lasting: True. 
- Your verdict: 

### 12. e11 (Interview loop at Verdant Grid (Staff Data Engineer)) — variant A+, claude-haiku

> Verdant Grid role is fully remote: The Staff Data Engineer role at Verdant Grid is fully remote.

- Reader: about **Staff Data Engineer role at Verdant Grid**; when **unclear**; current unclear; asks: –
- Grader: **missing_context** (time, status); lasting: True. It does not preserve that this was a prospective role discussed during the interview process.
- Your verdict: 

### 13. e05 (Knee injury and physiotherapy (2026)) — variant B, codex-sol

> Cycling permitted during knee recovery: Dr. Paulo Mendes said cycling is fine while I recover from my right knee injury.

- Reader: about **The user’s right knee injury and Dr. Paulo Mendes**; when **unclear**; current unclear; asks: Are you still recovering, and does this guidance still apply?
- Grader: **missing_context** (time); lasting: True. The reading captures the cycling guidance but omits when it was given.
- Your verdict: 

### 14. e09 (NordicSwift 2026 talk) — variant B, claude-haiku

> NordicSwift organisers covered flight and hotel: The NordicSwift 2026 organisers covered my flight and two hotel nights in Oslo.

- Reader: about **The user's attendance at NordicSwift 2026 in Oslo.**; when **2026**; current no; asks: –
- Grader: **pass** ; lasting: False. 
- Your verdict: 

### 15. e06 (Tern side project status) — variant B, codex-terra

> Tern weekly work schedule: I spend Sunday mornings working on Tern, about four hours per week.

- Reader: about **The user’s weekly work on Tern**; when **lasting**; current yes; asks: –
- Grader: **pass** ; lasting: True. Accurately captures the recurring schedule; lasting is appropriate.
- Your verdict: 

### 16. e01 (Halvorsen Robotics hiring process (Senior Firmware Engineer)) — variant B, claude-haiku

> Halvorsen role concern: quarterly travel to Trondheim: My main concern about the Senior Firmware Engineer role at Halvorsen Robotics, as of 18 September 2026, is the quarterly travel to Trondheim.

- Reader: about **Senior Firmware Engineer role at Halvorsen Robotics**; when **18 September 2026**; current unclear; asks: Is quarterly travel to Trondheim still your main concern about this role?
- Grader: **pass** ; lasting: True. Correct concern and role; dated as of 18 September 2026.
- Your verdict: 

### 17. e10 (Boda de Lucía (junio de 2027)) — variant B, codex-terra

> Viaje a la boda con Rui: Planeo viajar desde Lisboa a Argentina con mi pareja, Rui, para la boda de Lucía en junio de 2027.

- Reader: about **The user's planned trip with Rui to Lucía's wedding**; when **June 2027**; current yes; asks: –
- Grader: **pass** ; lasting: True. Correctly captures the planned Lisbon-to-Argentina trip with Rui for Lucía’s June 2027 wedding.
- Your verdict: 

### 18. e07 (Oakhurst Media contract terms) — variant B, codex-sol

> Oakhurst Media day rate: The agreed day rate for my Oakhurst Media freelance contract is €720, up from Oakhurst Media’s initial offer of €650.

- Reader: about **The user's Oakhurst Media freelance contract**; when **unclear**; current unclear; asks: Is the contract or rate still current?
- Grader: **missing_context** (time); lasting: True. The rate and initial offer are clear, but the reading leaves the contract period unspecified.
- Your verdict: 

### 19. e12 (Recruiter call about a CTO role) — variant C3, claude-haiku

> Lumen Health has about 20 months of runway: Lumen Health has about 20 months of runway.

- Reader: about **Lumen Health**; when **unclear**; current yes; asks: Is this still accurate, and as of what date was the runway estimate made?
- Grader: **pass** ; lasting: True. 
- Your verdict: 

### 20. e11 (Interview loop at Verdant Grid (Staff Data Engineer)) — variant C3, claude-opus

> Verdant Grid decision expected by 23 Oct 2026: I expect to hear back from Verdant Grid about the Staff Data Engineer role by Friday 23 October 2026.

- Reader: about **The user's application for the Staff Data Engineer role at Verdant Grid**; when **23 October 2026**; current unclear; asks: Have you heard back from Verdant Grid?
- Grader: **pass** ; lasting: True. Correctly frames the date as when the user expected to hear back, not as a confirmed outcome.
- Your verdict: 

### 21. e01 (Halvorsen Robotics hiring process (Senior Firmware Engineer)) — variant C3, claude-opus

> Halvorsen Robotics role: main draw is physical robots: Compared with my freelance work, the main draw of the Senior Firmware Engineer role at Halvorsen Robotics (September 2026) is working on physical robots.

- Reader: about **Senior Firmware Engineer role at Halvorsen Robotics**; when **September 2026**; current unclear; asks: Is this still your main reason for considering the role?
- Grader: **pass** ; lasting: True. Correctly captures the role's appeal as the user's September 2026 view, without asserting it remains current.
- Your verdict: 

### 22. e08 (New flat in Arroios) — variant C3, claude-opus

> Arroios landlord: Carlos Vieira: My landlord for the Arroios flat is Carlos Vieira, who lives in the same building.

- Reader: about **The user's Arroios landlord, Carlos Vieira**; when **unclear**; current unclear; asks: Is Carlos still your landlord?
- Grader: **pass** ; lasting: True. Correctly identifies Carlos as landlord and notes he lives in the building.
- Your verdict: 

### 23. e08 (New flat in Arroios) — variant C3, claude-opus

> Cat named Miso: I have a cat named Miso.

- Reader: about **The user’s cat, Miso**; when **lasting**; current yes; asks: –
- Grader: **pass** ; lasting: True. Correctly captures the user's cat and its name as a lasting fact.
- Your verdict: 

### 24. e06 (Tern side project status) — variant C3, codex-terra

> Tern appearance preference: I prefer Tern to follow the system appearance.

- Reader: about **The user's appearance preference for Tern**; when **lasting**; current yes; asks: –
- Grader: **pass** ; lasting: True. Preference correctly identified as lasting.
- Your verdict: 

### 25. e11 (Interview loop at Verdant Grid (Staff Data Engineer)) — variant D, claude-opus

> Verdant Grid Staff Data Engineer interview loop (October 2026): I completed the interview loop for the Staff Data Engineer role at Verdant Grid in the week of 5 October 2026: four interviews, on Tuesday 6 and Thursday 8 October 2026. Verdant Grid builds forecasting software for electricity grids and has about 120 employees, mostly in Copenhagen. In the system design interview, Mette had me design a pipeline for smart-meter readings and praised my enthusiasm and my questions about data quality. The hiring manager, Jonas, said the role is fully remote with a yearly team week in Copenhagen, and the team uses Python and dbt on Snowflake. I was weaker in the live SQL exercise and ran out of time on the last window-function question. The salary range given was DKK 85,000–95,000 a month. I sent my resume as a PDF to the recruiter the same day. As of 14 October 2026 I expected to hear back by Friday 23 October 2026. I like that Verdant Grid's product is about the energy transition but am unsure about the pay; if an offer comes I would negotiate for DKK 100,000 a month.

- Reader: about **The user's Staff Data Engineer interview process at Verdant Grid**; when **October 2026**; current unclear; asks: Did Verdant Grid get back to you, and has the role or compensation discussion moved forward?
- Grader: **pass** ; lasting: True. Accurately summarizes the completed process, dated expectation, and conditional negotiation plan.
- Your verdict: 

### 26. e08 (New flat in Arroios) — variant D, codex-sol

> Pet provision in Arroios flat lease: The lease for my Rua Morais Soares flat in Arroios allows one pet, and I asked whether the building permits cats because of my cat Miso.

- Reader: about **User's Rua Morais Soares flat in Arroios and cat Miso**; when **unclear**; current unclear; asks: Has the building confirmed whether cats are permitted?
- Grader: **missing_context** (time); lasting: True. The lease allowance and question about Miso are right, but the reading leaves unclear this is the new-flat lease.
- Your verdict: 

### 27. e05 (Knee injury and physiotherapy (2026)) — variant D, codex-terra

> Hospital parking payment: I paid €4.50 for parking at the hospital.

- Reader: about **User's hospital parking**; when **unclear**; current no; asks: –
- Grader: **missing_context** (time); lasting: False. The completed parking payment is not placed in time.
- Your verdict: 

### 28. e05 (Knee injury and physiotherapy (2026)) — variant D, claude-haiku

> Paid €4.50 for hospital parking (July 2026): On or around 21 July 2026, I paid €4.50 for parking at a hospital.

- Reader: about **User**; when **21 July 2026**; current no; asks: –
- Grader: **misread** (time); lasting: False. The reading places the parking payment around 21 July, but the original does not date it.
- Your verdict: 

### 29. e09 (NordicSwift 2026 talk) — variant D, claude-opus

> Karin Lund invited me to write a Swift.org guest post: At NordicSwift 2026 in September 2026 I met Karin Lund from the Swift Server Workgroup. She invited me to write a guest post for the Swift.org blog.

- Reader: about **The user and Karin Lund**; when **September 2026**; current yes; asks: –
- Grader: **pass** ; lasting: True. Meeting and invitation are correctly described and dated to September 2026.
- Your verdict: 

### 30. e06 (Tern side project status) — variant D, claude-haiku

> Tern tech stack: Swift, SwiftUI, SwiftData, CloudKit sync: Tern is written in Swift with SwiftUI and SwiftData. I tried Core Data first but switched to SwiftData in March 2026 because the migration code was getting too complex. Sync between devices uses CloudKit's private database.

- Reader: about **Tern, the user’s app/project**; when **March 2026 onward**; current yes; asks: –
- Grader: **pass** ; lasting: True. Correct stack, historical migration and reason, and sync method.
- Your verdict: 

