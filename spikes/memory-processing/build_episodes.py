#!/usr/bin/env python3
"""Builds Spike F's synthetic episode fixtures: fixtures/episodes.json.

Each episode is a long memory written the way agents write them (third person, one episode or entity, many details),
with the title and date a saved memory has. Everything is invented; none of it comes from a real vault.

Every fact has match keys and three labels:
- `keep`: "keep" (useful to an assistant later), "drop" (logistics or trivia: must be left out under variant C), or
  "either" (fine both ways).
- `timed`: the fact belongs to a time, so a piece stating it needs a time anchor (any of the episode's `when` regexes).
- `other`: about something other than the episode (a general preference, a lasting fact about the user or someone
  else). Variant D splits these out; under every variant they need no episode subject.
`claim` is the expected piece written as variant B would (subject and time named), for reading only: scoring is by
keys. A piece matches a fact when every regex in `keys` matches its title or body (case-insensitive). A piece about
the episode names its subject when any regex in the episode's `subject` (or the fact's own `subject`) matches.

Expected pieces per variant (score_f.py):
- A, A+ and B: one piece per keep or either fact (keep facts required for recall; drop facts may appear).
- C: keep facts required; drop facts must not appear.
- D: one piece per episode (holding its facts) plus one per `other` fact; recall over keep facts.
`mustNot` lists misreadings to catch in a piece's own words (all of `all`, none of `none`).
"""
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent


def F(fid, claim, keys, keep="keep", timed=False, other=False, subject=None):
    f = {"id": fid, "claim": claim, "keys": keys, "keep": keep, "timed": timed, "other": other}
    if subject:
        f["subject"] = subject
    return f


def M(label, all_, none=()):
    return {"label": label, "all": list(all_), "none": list(none)}


def E(id_, title, written, source, sensitivity, categories, subject, when, text, facts, must_not=(), lang="en"):
    facts = [dict(f, id=f"{id_}.{f['id']}") for f in facts]
    return {"id": id_, "title": title, "written": written, "source": source, "sensitivity": sensitivity,
            "categories": categories, "variant": "about_user", "lang": lang, "subject": subject, "when": when,
            "text": text.strip(), "facts": facts, "mustNot": list(must_not)}


EPISODES = [
    E("e01", "Halvorsen Robotics hiring process (Senior Firmware Engineer)", "2026-09-18", "agent_write", "internal",
      ["project_context"], [r"halvorsen"], [r"2026", r"september|sept\b|sep\b", r"october|november"],
      """
The user is going through the hiring process for the Senior Firmware Engineer position at Halvorsen Robotics, a warehouse-automation company based in Trondheim. The user found the opening through a referral from their former colleague Ingrid Sæther, who now leads the motion-control team there. The first step was a 30-minute screening call on 2 September 2026 with the recruiter, Tomas Berg. Tomas explained that the position is fully remote within European time zones, with one on-site week in Trondheim per quarter. He shared that the salary band is NOK 950,000–1,150,000 a year plus an annual bonus of up to 10%. The user asked what "FTE" meant in the job posting, and Tomas explained it stands for full-time equivalent. Tomas said the user could attach their resume as a PDF in the application portal or email it to him directly.

The second step, on 9 September 2026, was a technical interview with Ingrid and a senior engineer, Aksel Moe. They covered embedded Rust, real-time scheduling on ARM Cortex-M parts and a debugging exercise on a CAN bus trace. Aksel praised the user's enthusiasm and the way they talked through trade-offs out loud. The user felt weakest on the question about safety certification (IEC 61508), which they have no hands-on experience with, and noted it as something to read up on. The interview ran 15 minutes over because the video link dropped twice.

On 16 September 2026, the user had the final round, a video call with the VP of Engineering, Lene Haugland, who apologised for joining five minutes late. Lene described the firmware group as 14 engineers across three teams and said they expect to make a decision by the end of September. The user told Lene that their notice period with their current client is six weeks and that the earliest start date would be 2 November 2026. The user said that, compared with their freelance work, the main draw is working on physical robots, and the main concern is the quarterly travel to Trondheim, since they don't enjoy long flights. The user has not yet decided whether they would accept an offer.
""",
      [
          F("f01", "In September 2026 I was in the hiring process for the Senior Firmware Engineer position at Halvorsen Robotics.", [r"halvorsen", r"hiring process|in the (hiring )?process|going through|applying|applied"], timed=True),
          F("f02", "Halvorsen Robotics is a warehouse-automation company based in Trondheim.", [r"warehouse"]),
          F("f03", "My former colleague Ingrid Sæther, who leads Halvorsen Robotics' motion-control team, referred me for the Senior Firmware Engineer opening.", [r"ingrid|s[æa]ther", r"refer|motion"]),
          F("f04", "I had a screening call with Halvorsen Robotics' recruiter Tomas Berg on 2 September 2026.", [r"screening|tomas|berg"], keep="either", timed=True),
          F("f05", "The Senior Firmware Engineer position at Halvorsen Robotics is fully remote within European time zones, with one on-site week in Trondheim per quarter.", [r"remote|on-site|onsite"]),
          F("f06", "The salary band for Halvorsen Robotics' Senior Firmware Engineer position is NOK 950,000–1,150,000 a year plus a bonus of up to 10%.", [r"950"]),
          F("f07", "I asked what FTE means (full-time equivalent).", [r"\bFTE\b|full-time equivalent"], keep="drop"),
          F("f08", "I could attach my resume as a PDF or email it to the recruiter.", [r"resume|résumé|\bCV\b"], keep="drop"),
          F("f09", "On 9 September 2026 I had Halvorsen Robotics' technical interview with Ingrid Sæther and Aksel Moe, on embedded Rust, real-time scheduling on Cortex-M and a CAN bus trace.", [r"technical interview|embedded rust|cortex|\bCAN\b"], keep="either", timed=True),
          F("f10", "In Halvorsen Robotics' technical interview in September 2026, Aksel Moe praised my enthusiasm and how I talked through trade-offs.", [r"enthusias"], timed=True),
          F("f11", "I have no hands-on experience with safety certification (IEC 61508), my weakest topic in the Halvorsen Robotics interview, and want to read up on it.", [r"61508|safety certification"]),
          F("f12", "The interview ran 15 minutes over because the video link dropped.", [r"video link|dropped twice|15 minutes over|ran (15 minutes )?over"], keep="drop"),
          F("f13", "On 16 September 2026 I had the final round for Halvorsen Robotics with VP of Engineering Lene Haugland.", [r"lene|haugland|final round"], keep="either", timed=True),
          F("f14", "Lene apologised for joining five minutes late.", [r"late|apologi"], keep="drop"),
          F("f15", "Halvorsen Robotics' firmware group has 14 engineers across three teams.", [r"\b14\b|fourteen"], keep="either"),
          F("f16", "Halvorsen Robotics expected to decide on the Senior Firmware Engineer position by the end of September 2026.", [r"decision|decide", r"end of september|30 september|september 30|end of sept"], timed=True),
          F("f17", "My notice period with my current client is six weeks (as of September 2026).", [r"notice"], other=True),
          F("f18", "My earliest start date for Halvorsen Robotics would be 2 November 2026.", [r"2 november|november 2|nov(ember)? 2\b|start date"]),
          F("f19", "The main draw of the Halvorsen Robotics job for me is working on physical robots.", [r"physical robot|working on robots|real robots"]),
          F("f20", "My main concern about the Halvorsen Robotics job is the quarterly travel to Trondheim.", [r"concern|worr|downside|drawback"]),
          F("f21", "I don't enjoy long flights.", [r"long flights|flying long"], other=True),
          F("f22", "As of September 2026 I hadn't decided whether to accept an offer from Halvorsen Robotics.", [r"not (yet )?decided|undecided|hadn't decided|had not (yet )?decided|hasn't decided|haven't decided|have not (yet )?decided|not sure whether|unsure whether"], timed=True),
      ],
      [M("the offered job read as the user's current job", [r"\bI (work|am working) (at|for) halvorsen|\bI(?:'m| am) (a|the) senior firmware engineer at"]),
       M("the salary band read as the user's salary", [r"\bmy (salary|pay)\b"], [r"band|offer|role|position|would|halvorsen"])]),

    E("e02", "Confidential recruiter pitch: Head of Platform role (via Brightline Talent)", "2026-10-02", "agent_write",
      "sensitive", ["project_context", "finance"], [r"head of platform", r"brightline", r"whitlock"],
      [r"2026", r"october|oct\b", r"january|2027"],
      """
On 1 October 2026 the user took a call from Dana Whitlock, a recruiter at Brightline Talent, about a Head of Platform role at a client she could not name yet. Dana described the client only as a Series C payments company headquartered in Lisbon with about 400 employees, and asked the user to keep the details confidential until the client agrees to disclose its name. The role would lead three platform teams (about 22 engineers) covering infrastructure, developer tooling and internal APIs, reporting to the CTO. The opportunity offered a base salary of €145,000–€165,000, a 15% annual bonus target and equity that Dana called "meaningful" without giving a number. The role was fully remote within Portugal, with an office in Lisbon available but optional. The client wants someone to start in January 2027.

Dana said the hiring process would have four stages: a call with the CTO, a system design session, a leadership panel and a reference check. The user told Dana they are interested, but that they have not managed more than one team before, and that they would want the equity terms in writing before going further. Dana offered to send a one-page summary of the role by email and asked whether the user preferred calls in the morning or the afternoon; the user said afternoons. The user asked what "Series C" means for stability, and Dana explained it is the company's third institutional funding round. The user agreed to a follow-up call on 8 October 2026, after Dana confirms whether the client will reveal its name.
""",
      [
          F("f01", "On 1 October 2026 Brightline Talent recruiter Dana Whitlock pitched me a Head of Platform role at a client she couldn't name.", [r"dana|whitlock", r"pitch|took a call|called me|contacted|approached|reached out"], timed=True),
          F("f02", "The confidential client for the Head of Platform role Brightline Talent pitched is a Series C payments company in Lisbon with about 400 employees.", [r"series c|payments", r"lisbon|400"]),
          F("f03", "The details of the Head of Platform role Brightline Talent pitched are confidential until the client agrees to disclose its name.", [r"confidential|disclos|reveal", r"until|keep|agree|name"]),
          F("f04", "The Head of Platform role Brightline Talent pitched would lead three platform teams (about 22 engineers): infrastructure, developer tooling and internal APIs.", [r"three|\b3\b|22", r"teams?|engineers"]),
          F("f05", "The Head of Platform role Brightline Talent pitched would report to the CTO.", [r"report", r"\bCTO\b"]),
          F("f06", "The Head of Platform role Brightline Talent pitched offers a base salary of €145,000–€165,000.", [r"145"]),
          F("f07", "The Head of Platform role Brightline Talent pitched has a 15% annual bonus target.", [r"15 ?%|15 percent", r"bonus"]),
          F("f08", "The Head of Platform role Brightline Talent pitched includes equity the recruiter called meaningful, with no number given.", [r"equity", r"meaningful|no (number|figure)|unspecified|not specified|undisclosed"]),
          F("f09", "The Head of Platform role Brightline Talent pitched would be fully remote within Portugal, with an optional Lisbon office.", [r"remote"]),
          F("f10", "The client behind the Head of Platform role Brightline Talent pitched wants someone to start in January 2027.", [r"january 2027|jan(uary)? 2027|start in january"], timed=True),
          F("f11", "The Head of Platform hiring process would have four stages: a CTO call, system design, a leadership panel and a reference check.", [r"system design|leadership panel|reference check|four stages|four-stage|4 stages"], keep="either"),
          F("f12", "In October 2026 I told Brightline Talent I'm interested in the Head of Platform role.", [r"interest"], timed=True),
          F("f13", "I haven't managed more than one team.", [r"more than one team|multiple teams|several teams|one team"], other=True),
          F("f14", "I want the equity terms of the Head of Platform role in writing before going further.", [r"writing|written"]),
          F("f15", "Dana offered to email a one-page summary of the role.", [r"one-page|one page"], keep="drop"),
          F("f16", "I prefer calls in the afternoon.", [r"afternoon"], keep="either", other=True),
          F("f17", "I asked what Series C means; it's the third institutional funding round.", [r"third|funding round|institutional"], keep="drop"),
          F("f18", "I have a follow-up call with Brightline Talent about the Head of Platform role on 8 October 2026.", [r"follow[- ]up|8 october|october 8|oct(ober)? 8\b"], timed=True),
      ],
      [M("the pitched role's remote policy read as the user's job", [r"\bI (work|am working)\b.*remote|\bmy (job|role|work) is (fully )?remote"]),
       M("the pitched salary read as the user's salary", [r"\bmy (base )?salary\b|\bI (earn|make)\b"], [r"would|offer|role|pitch|head of platform"])]),

    E("e03", "Quillstone interview outcome", "2026-08-05", "agent_suggestion", "internal", ["project_context"],
      [r"quillstone"], [r"2026", r"july|jul\b", r"august|aug\b"],
      """
The user heard back from Quillstone yesterday: they were not selected for the Engineering Manager position on the Payments Reliability team, after reaching the final round. Quillstone is a London-based e-commerce infrastructure company; the user had applied in early July after seeing the role on LinkedIn. The final round was last Thursday, a two-hour panel with the Director of Engineering, Priyanka Raman, and two engineering managers. In the rejection email, Priyanka wrote that the panel was impressed by the user's incident-response examples but chose a candidate with more experience running performance reviews and hiring loops. She offered a 20-minute feedback call, which the user accepted for next Monday.

The user said they were disappointed but also relieved, because the role would have required three days a week in the London office, and the user does not want to relocate from Lisbon. The user wants to build experience with performance reviews before applying for another manager role, and is considering asking their current client to let them mentor two junior developers. The recruiter at Quillstone, Owen Pike, had been slow to reply throughout the process, often taking a week. The user wondered whether to send a thank-you note and decided to send a short one.
""",
      [
          F("f01", "On 4 August 2026 Quillstone told me I wasn't selected for the Engineering Manager position on its Payments Reliability team, after the final round.", [r"not (been )?selected|wasn't selected|was not selected|reject|didn't get|did not get|unsuccessful|turned down|not chosen|not get the"], timed=True),
          F("f02", "Quillstone is a London-based e-commerce infrastructure company.", [r"e-?commerce"]),
          F("f03", "I applied to Quillstone's Engineering Manager role in early July 2026 after seeing it on LinkedIn.", [r"linkedin"], keep="either", timed=True),
          F("f04", "Quillstone's final round, on 30 July 2026, was a two-hour panel with Director of Engineering Priyanka Raman and two engineering managers.", [r"panel"], keep="either", timed=True),
          F("f05", "Quillstone's panel was impressed by my incident-response examples (August 2026).", [r"incident"]),
          F("f06", "Quillstone chose a candidate with more experience running performance reviews and hiring loops.", [r"candidate|chose|went with|picked|selected (someone|another)"]),
          F("f07", "I have a 20-minute feedback call with Quillstone's Priyanka Raman on 10 August 2026.", [r"feedback (call|session|meeting)|20-minute|20 minute"], timed=True),
          F("f08", "I was disappointed but relieved not to get the Quillstone role.", [r"relieved|disappoint"], keep="either"),
          F("f09", "Quillstone's Engineering Manager role would have required three days a week in the London office.", [r"three days|3 days"]),
          F("f10", "I don't want to relocate from Lisbon.", [r"relocat"], other=True),
          F("f11", "I want to build experience with performance reviews before applying for another manager role.", [r"before (applying|I apply|I look)|another (engineering )?manager|next (engineering )?manager"], other=True),
          F("f12", "I'm considering asking my current client to let me mentor two junior developers.", [r"mentor"], other=True),
          F("f13", "Quillstone's recruiter Owen Pike was slow to reply, often taking a week.", [r"owen|pike|slow"], keep="either"),
          F("f14", "I decided to send Quillstone a short thank-you note.", [r"thank"], keep="drop"),
      ],
      [M("the rejection read as an offer", [r"\b(offered me|got) the (role|job|position)|\bI(?:'m| am) (an|the) engineering manager\b"], [r"not|didn't|never|n't"])]),

    E("e04", "Japan trip, April 2026", "2026-05-03", "agent_write", "low", ["personal_preferences"],
      [r"japan|tokyo|kyoto|osaka"], [r"2026", r"april|apr\b"],
      """
The user and their partner, Rui, spent two weeks in Japan from 11 to 25 April 2026: five nights in Tokyo, six in Kyoto and three in Osaka. It was their first trip to Asia. They flew TAP from Lisbon to Tokyo via Frankfurt; the connection in Frankfurt was tight and their luggage arrived a day late. In Kyoto they stayed at a small ryokan called Hanaori near Gion, which the user said was the highlight of the trip and where they would like to return. The user found Tokyo overwhelming because of the crowds, and said they prefer quieter cities when they travel. Rui is vegetarian, and finding vegetarian food in Osaka was harder than expected; shojin ryori temple restaurants in Kyoto were the easiest option. The user's favourite meal was at a tempura counter in Osaka called Tenkuu. The user got a Suica card at the airport and topped it up twice. They want to go back to Japan in autumn 2027 to see Hokkaido. The user said they would book the JR Pass earlier next time, since the price went up the week before they bought it. Rui twisted an ankle on the Fushimi Inari trail on 19 April, which was fine after a few days. Total spending was about €6,200 for both, slightly over their €5,500 budget.
""",
      [
          F("f01", "My partner Rui and I spent two weeks in Japan from 11 to 25 April 2026.", [r"japan", r"rui|partner|two weeks"], timed=True),
          F("f02", "On our April 2026 Japan trip we spent five nights in Tokyo, six in Kyoto and three in Osaka.", [r"five nights|5 nights|six nights|6 nights|three nights|3 nights"], keep="either", timed=True),
          F("f03", "The April 2026 Japan trip was my first trip to Asia.", [r"first", r"asia"], keep="either", timed=True),
          F("f04", "We flew TAP via Frankfurt; the connection was tight and our luggage arrived a day late.", [r"frankfurt|luggage|\bTAP\b"], keep="drop"),
          F("f05", "Ryokan Hanaori near Gion in Kyoto was the highlight of my April 2026 Japan trip; I'd like to return.", [r"hanaori|ryokan"]),
          F("f06", "I found Tokyo overwhelming because of the crowds (April 2026).", [r"tokyo", r"overwhelm|crowd"]),
          F("f07", "I prefer quieter cities when I travel.", [r"quiet"], other=True),
          F("f08", "My partner Rui is vegetarian.", [r"vegetarian", r"rui|partner"], other=True, subject=[r"rui"]),
          F("f09", "Vegetarian food was harder to find in Osaka than expected; shojin ryori in Kyoto was easiest.", [r"shojin|harder|hard to find|difficult"], keep="either"),
          F("f10", "My favourite meal in Japan was at Tenkuu, a tempura counter in Osaka.", [r"tenkuu|tempura"]),
          F("f11", "I got a Suica card at the airport and topped it up twice.", [r"suica"], keep="drop"),
          F("f12", "I want to go back to Japan in autumn 2027 to see Hokkaido.", [r"hokkaido"]),
          F("f13", "Next time in Japan I'd book the JR Pass earlier; the price went up just before I bought it.", [r"\bJR\b|rail pass"]),
          F("f14", "Rui twisted an ankle on the Fushimi Inari trail on 19 April; it was fine after a few days.", [r"ankle"], keep="drop"),
          F("f15", "Our April 2026 Japan trip cost about €6,200 for both, over our €5,500 budget.", [r"6[,. ]?200|5[,. ]?500|budget"], keep="either", timed=True),
      ],
      [M("the past trip read as upcoming", [r"\b(will|am going to|'m going to|plan(ning)? to) (go|travel|fly|spend|stay)\b"], [r"hokkaido|2027|back|return|again|next time"])]),

    E("e05", "Knee injury and physiotherapy (2026)", "2026-07-21", "agent_write", "sensitive", ["health"],
      [r"knee|menisc"], [r"2026", r"march|april|june|july|august|september|october|november"],
      """
The user injured their right knee on 14 March 2026 while playing five-a-side football: they twisted it on landing and felt a pop, followed by swelling that evening. They saw their GP, Dr. Helena Costa at the USF Alvalade health centre, two days later; she suspected a meniscus injury and referred them for an MRI. The MRI on 2 April 2026 at the Clínica Lumiar showed a grade 2 tear of the medial meniscus, with no ligament damage. The orthopaedic surgeon, Dr. Paulo Mendes, advised against surgery for now and prescribed eight weeks of physiotherapy, with a review in July. He told the user not to play football or run on hard surfaces until he clears them, and said cycling and swimming are fine. The user took ibuprofen for the first ten days but stopped because it upset their stomach; they now use only ice and paracetamol when it flares up. The user's health insurance (Médis) covered the MRI after a pre-authorisation that took four working days; the claim reference was sent by SMS.

Physiotherapy started on 8 April with Joana Reis at Fisio Campo de Ourique, twice a week. The programme focuses on quadriceps and hip strengthening, balance work and gradually adding load. The user finds the single-leg balance exercises the hardest and tends to skip them at home, which Joana flagged. By mid-June the user could walk for an hour without pain and climb stairs normally, but still felt discomfort when kneeling. The physio sessions are on Tuesdays and Fridays at 8:00, and the user once had to reschedule because of a client meeting. At the review on 20 July 2026, Dr. Mendes said the knee is healing well, cleared the user to start gentle jogging on grass or a treadmill from August, and said football should wait until at least October 2026. He recommended continuing the home exercises three times a week for another three months. The user wants to get back to football, but is considering switching to padel, which their friend Nuno plays, because it is easier on the knees. The user paid €4.50 for parking at the hospital.
""",
      [
          F("f01", "I injured my right knee on 14 March 2026 playing five-a-side football.", [r"14 march|march 14|five-a-side|playing football|while playing"], timed=True),
          F("f02", "My GP is Dr. Helena Costa at the USF Alvalade health centre.", [r"costa"], other=True),
          F("f03", "An MRI on 2 April 2026 showed a grade 2 tear of my right knee's medial meniscus, with no ligament damage.", [r"menisc", r"tear|grade"], timed=True),
          F("f04", "In April 2026 orthopaedic surgeon Dr. Paulo Mendes advised against surgery for my knee for now.", [r"surgery"], timed=True),
          F("f05", "Dr. Mendes prescribed eight weeks of physiotherapy for my knee.", [r"eight weeks|8 weeks|8-week|eight-week"], keep="either"),
          F("f06", "Since April 2026, until Dr. Mendes clears me, no football or running on hard surfaces for my knee.", [r"hard surface"], keep="either", timed=True),
          F("f07", "Cycling and swimming are fine for my knee injury.", [r"cycl|swim"]),
          F("f08", "Ibuprofen upsets my stomach, so I stopped taking it.", [r"ibuprofen"], other=True),
          F("f09", "I use ice and paracetamol when my knee flares up.", [r"paracetamol"]),
          F("f10", "My health insurer is Médis; it covered the knee MRI after a four-day pre-authorisation.", [r"m[ée]dis|insur"], keep="either"),
          F("f11", "The claim reference was sent by SMS.", [r"\bSMS\b|claim reference"], keep="drop"),
          F("f12", "Since 8 April 2026 I've had knee physiotherapy twice a week with Joana Reis at Fisio Campo de Ourique.", [r"joana|reis|campo de ourique"], timed=True),
          F("f13", "My knee physio programme focuses on quadriceps and hip strengthening, balance and adding load.", [r"quadriceps|quads|\bhip\b"], keep="either"),
          F("f14", "In my knee physio I find the single-leg balance exercises hardest and tend to skip them at home.", [r"single-leg|skip|hardest"]),
          F("f15", "By mid-June 2026 I could walk an hour without knee pain but kneeling was still uncomfortable.", [r"kneel"], keep="either", timed=True),
          F("f16", "Physio is Tuesdays and Fridays at 8:00; I once rescheduled for a client meeting.", [r"tuesday|friday|8:00|resched"], keep="drop"),
          F("f17", "On 20 July 2026 Dr. Mendes cleared my knee for gentle jogging on grass or a treadmill from August 2026.", [r"jog"], timed=True),
          F("f18", "After my knee injury, football should wait until at least October 2026.", [r"football", r"october"], timed=True),
          F("f19", "I should keep doing my knee home exercises three times a week until about October 2026.", [r"three times|3 times|3x|three months|3 months"], timed=True),
          F("f20", "I want to get back to football after my knee injury but I'm considering padel, which my friend Nuno plays.", [r"padel"]),
          F("f21", "I paid €4.50 for hospital parking.", [r"parking|4[.,]50"], keep="drop"),
      ],
      [M("ibuprofen as a recommendation", [r"ibuprofen"], [r"stop|upset|no longer|not|avoid|stomach|n't"])]),

    E("e06", "Tern side project status", "2026-06-12", "agent_write", "internal",
      ["project_context", "software_development"], [r"\btern\b"], [r"2026", r"january|march|june|september"],
      """
The user is building Tern, a personal budgeting app for iPhone and Mac, as a side project with their friend Sofia Antunes, who handles the design. They started it in January 2026 and want a public TestFlight beta by the end of September 2026. Tern imports bank exports as CSV and OFX files rather than connecting to banks directly, because the user does not want to store bank credentials or pay for an aggregator such as Plaid. The app is written in Swift with SwiftUI and SwiftData; the user tried Core Data first but switched in March because the migration code was getting too complex. Sync between devices uses CloudKit's private database. Sofia wants a dark, high-contrast look; the user prefers following the system appearance, and they agreed to support both. The user spends Sunday mornings on Tern, about four hours a week. The biggest open problem is categorising transactions automatically: the user tried simple keyword rules and found them too brittle, and is now testing an on-device classifier. Tern will be free with a one-time €9.99 unlock for multiple accounts; there will be no subscription, because the user dislikes subscription pricing for small apps. The repository is private on GitHub under Sofia's account for now. The user asked how to rename a SwiftData model property without losing data and was pointed to the migration plan documentation.
""",
      [
          F("f01", "I'm building Tern, a personal budgeting app for iPhone and Mac, as a side project.", [r"tern", r"budget"]),
          F("f02", "My friend Sofia Antunes handles the design of Tern.", [r"sofia|antunes", r"design"]),
          F("f03", "I started Tern in January 2026.", [r"january|started"], keep="either", timed=True),
          F("f04", "I want a public TestFlight beta of Tern by the end of September 2026.", [r"testflight|beta"], timed=True),
          F("f05", "Tern imports bank exports as CSV and OFX files instead of connecting to banks.", [r"\bCSV\b|\bOFX\b"]),
          F("f06", "For Tern I don't want to store bank credentials or pay for an aggregator such as Plaid.", [r"credential|plaid|aggregator"]),
          F("f07", "Tern is written in Swift with SwiftUI and SwiftData.", [r"swiftui|written in|built with"]),
          F("f08", "In March 2026 I switched Tern from Core Data to SwiftData because the migration code got too complex.", [r"core data"], timed=True),
          F("f09", "Tern syncs between devices with CloudKit's private database.", [r"cloudkit"]),
          F("f10", "Sofia wants a dark high-contrast look for Tern, I prefer the system appearance; Tern will support both.", [r"dark|contrast|system appearance"], keep="either"),
          F("f11", "I work on Tern on Sunday mornings, about four hours a week.", [r"sunday|four hours|4 hours"]),
          F("f12", "Tern's biggest open problem is categorising transactions; keyword rules were too brittle, so I'm testing an on-device classifier.", [r"categori|classif"]),
          F("f13", "Tern will be free with a one-time €9.99 unlock for multiple accounts.", [r"9[.,]99|one-time|unlock"]),
          F("f14", "I dislike subscription pricing for small apps.", [r"subscription"], other=True),
          F("f15", "Tern's repository is private on GitHub under Sofia's account.", [r"github|repositor"], keep="either"),
          F("f16", "I asked how to rename a SwiftData property without losing data.", [r"rename|migration plan"], keep="drop"),
      ],
      [M("Sofia's preference read as the user's", [r"\bI (prefer|want|like) (a )?dark"])]),

    E("e07", "Oakhurst Media contract terms", "2026-03-27", "agent_suggestion", "sensitive",
      ["finance", "legal", "project_context"], [r"oakhurst"], [r"2026", r"march|april|september"],
      """
The user negotiated a freelance contract with Oakhurst Media, a podcast network based in Dublin, to rebuild the iOS client of its listener app. The contract was signed on 26 March 2026 and runs from 6 April to 30 September 2026. The agreed day rate is €720, up from the €650 Oakhurst first offered; the user's own minimum for new clients is €700. The scope is four days a week, with Fridays kept free for the user's other clients. Payment terms are 30 days from invoice, invoiced monthly; the user had asked for 15 days and accepted 30 in exchange for the higher rate. The user's contact is Siobhán Kelly, the head of product; the engineering lead is Marek Novak. The contract includes an NDA that forbids naming Oakhurst's unreleased features publicly, and the user keeps the right to mention Oakhurst as a client in their portfolio. Intellectual property transfers to Oakhurst on payment. Either side can end the contract with 14 days' notice. Siobhán asked the user to send invoices to the accounts address as PDFs with the purchase order number, and the user set up a template for it. The user checked whether the contract had to be signed in blue ink and was told an electronic signature is fine. The user wants to turn this into a longer engagement if the first release goes well.
""",
      [
          F("f01", "In March 2026 I signed a freelance contract with Oakhurst Media, a Dublin podcast network, to rebuild its listener app's iOS client.", [r"oakhurst", r"ios|listener|podcast|rebuild"], timed=True),
          F("f02", "My Oakhurst Media contract runs from 6 April to 30 September 2026.", [r"30 september|september 30|6 april|april 6|sept(ember)? 30"], timed=True),
          F("f03", "My day rate with Oakhurst Media is €720.", [r"720"]),
          F("f04", "Oakhurst Media first offered €650 a day.", [r"650"], keep="either"),
          F("f05", "My minimum day rate for new clients is €700.", [r"\b700\b"], other=True),
          F("f06", "My Oakhurst Media contract is four days a week, with Fridays free for other clients.", [r"\bfour days|\b4 days|friday"]),
          F("f07", "Oakhurst Media pays 30 days from invoice, invoiced monthly.", [r"30 days|30-day|net ?30|thirty days"]),
          F("f08", "My contact at Oakhurst Media is Siobhán Kelly, head of product.", [r"siobh|kelly"]),
          F("f09", "Oakhurst Media's engineering lead is Marek Novak.", [r"marek|novak"]),
          F("f10", "My Oakhurst Media contract has an NDA: I can't name Oakhurst's unreleased features publicly.", [r"\bNDA\b|non-disclosure|unreleased"]),
          F("f11", "I can mention Oakhurst Media as a client in my portfolio.", [r"portfolio"]),
          F("f12", "Under my Oakhurst Media contract, intellectual property transfers to Oakhurst on payment.", [r"intellectual property|\bIP\b"]),
          F("f13", "Either side can end my Oakhurst Media contract with 14 days' notice.", [r"14 days|14-day|fourteen"]),
          F("f14", "Oakhurst Media invoices go to the accounts address as PDFs with the purchase order number.", [r"purchase order|\bPO\b|\bPDF"], keep="either"),
          F("f15", "An electronic signature was fine; no blue ink needed.", [r"\bink\b|electronic signature|e-signature"], keep="drop"),
          F("f16", "I want to turn the Oakhurst Media contract into a longer engagement if the first release goes well.", [r"longer|extend|long-term"]),
      ],
      [M("the first offer read as the rate", [r"\b650\b"], [r"first|offer|initial|up from|instead|originally|rather than|from"])]),

    E("e08", "New flat in Arroios", "2026-10-10", "agent_write", "sensitive",
      ["personal_preferences", "legal", "finance"], [r"arroios|morais soares"], [r"2026", r"october|november|oct\b|nov\b"],
      """
The user signed a lease on a two-bedroom flat on Rua Morais Soares in Arroios, Lisbon, on 8 October 2026, and moves in on 1 November 2026. The rent is €1,450 a month, with a two-month deposit; the lease runs for three years, and the rent can rise at most by the yearly inflation index. The landlord is Carlos Vieira, who lives in the building and prefers to be contacted on WhatsApp. The flat is on the fourth floor with a lift, and the second bedroom will be the user's office, which is why they chose it over a cheaper one-bedroom in Penha de França. The user's current flat in Graça has to be handed back by 15 November 2026; the user gave notice on 30 September. The kitchen has a gas hob, which the user dislikes because they prefer cooking on induction, and the landlord agreed they can replace it at their own cost. Internet will be MEO fibre; the technician visit is booked for 3 November between 9:00 and 13:00. The user asked whether the building allows cats, because of their cat Miso, and the lease allows one pet. The user needs to update their address with the tax authority (Finanças) and their bank after the move. The estate agent's fee was paid by the landlord. The user measured the living room as 4.2 by 5.1 metres to plan where the sofa goes.
""",
      [
          F("f01", "On 8 October 2026 I signed a lease on a two-bedroom flat on Rua Morais Soares in Arroios, Lisbon.", [r"\bsign"], timed=True),
          F("f02", "I move into the Arroios flat on 1 November 2026.", [r"1 november|november 1\b|1st of november|nov(ember)? 1\b|1 nov\b"], timed=True),
          F("f03", "The rent for my Arroios flat is €1,450 a month.", [r"1[,. ]?450"]),
          F("f04", "The Arroios flat has a two-month deposit.", [r"deposit"], keep="either"),
          F("f05", "My Arroios lease runs three years; the rent can rise at most by the yearly inflation index.", [r"three years|3 years|three-year|3-year|inflation"]),
          F("f06", "My Arroios landlord, Carlos Vieira, lives in the building and prefers WhatsApp.", [r"vieira|carlos"]),
          F("f07", "The Arroios flat is on the fourth floor, with a lift.", [r"fourth floor|4th floor|\blift\b|elevator"], keep="either"),
          F("f08", "The second bedroom of my Arroios flat will be my office; I chose it over a cheaper one-bedroom in Penha de França.", [r"office"]),
          F("f09", "I hand back my current flat in Graça by 15 November 2026 (notice given 30 September).", [r"gra[çc]a"], timed=True, subject=[r"gra[çc]a"]),
          F("f10", "I prefer cooking on induction.", [r"induction"], other=True),
          F("f11", "My Arroios landlord agreed I can replace the gas hob at my own cost.", [r"replac"]),
          F("f12", "Internet at the Arroios flat will be MEO fibre.", [r"\bMEO\b|fibre|fiber"], keep="either"),
          F("f13", "The internet technician visit is 3 November, 9:00–13:00.", [r"technician|9:00|13:00"], keep="drop"),
          F("f14", "My Arroios lease allows one pet, so my cat Miso can come.", [r"\bpets?\b|\bcats?\b|miso"]),
          F("f15", "After moving to Arroios in November 2026 I need to update my address with Finanças and my bank.", [r"finan[çc]as|tax|address"], timed=True),
          F("f16", "The estate agent's fee was paid by the landlord.", [r"agent|\bfee\b"], keep="drop"),
          F("f17", "The Arroios living room measures 4.2 by 5.1 metres.", [r"4[.,]2|5[.,]1"], keep="either"),
      ]),

    E("e09", "NordicSwift 2026 talk", "2026-09-28", "agent_write", "internal",
      ["project_context", "software_development"], [r"nordic ?swift|oslo|without tears"], [r"2026", r"september|sept\b", r"october"],
      """
The user gave a talk titled "Offline-first sync without tears" at NordicSwift 2026 in Oslo on 24 September 2026. It was their first conference talk in English; before, they had only spoken at local meetups in Lisbon. The talk was 30 minutes plus Q&A, about conflict resolution with CRDTs in a SwiftData app, using Tern as the example. About 250 people attended. The user was nervous beforehand and rehearsed five times with their partner, which they said helped a lot. The organisers covered the flight and two hotel nights; the user paid for an extra night to see the city. The slides are on Speaker Deck, and the recording should be on YouTube in October. The feedback forms gave the talk 4.6 out of 5; several people said the live demo was the best part, and two said the CRDT section was too fast. The user met Karin Lund from the Swift Server Workgroup, who invited them to write a guest post for the Swift.org blog. The user wants to submit the same talk, with a slower CRDT section, to two more conferences in 2027, and would rather not do live demos again because the venue Wi-Fi nearly failed. The user had to ask the organisers for a USB-C to HDMI adapter.
""",
      [
          F("f01", "On 24 September 2026 I gave the talk \"Offline-first sync without tears\" at NordicSwift 2026 in Oslo.", [r"\bgave|presented|spoke|delivered", r"talk"], timed=True),
          F("f02", "My NordicSwift 2026 talk was my first conference talk in English; before, only Lisbon meetups.", [r"first (conference )?talk|first time|meetup"]),
          F("f03", "My NordicSwift 2026 talk covered CRDT conflict resolution in a SwiftData app, with Tern as the example.", [r"tern|conflict resolution"], keep="either"),
          F("f04", "About 250 people attended my NordicSwift 2026 talk.", [r"250"], keep="either"),
          F("f05", "Rehearsing my NordicSwift talk five times with my partner helped a lot with nerves.", [r"rehears"]),
          F("f06", "NordicSwift covered my flight and two hotel nights; I paid for an extra night.", [r"hotel|flight|extra night"], keep="drop"),
          F("f07", "My NordicSwift 2026 slides are on Speaker Deck; the recording should be on YouTube in October 2026.", [r"speaker ?deck|youtube|recording"], keep="either"),
          F("f08", "My NordicSwift 2026 talk was rated 4.6 out of 5.", [r"4[.,]6"]),
          F("f09", "At NordicSwift 2026 people said my live demo was the best part.", [r"demo", r"best|liked|highlight|favou?rite"]),
          F("f10", "At NordicSwift 2026 two people said my CRDT section was too fast.", [r"too fast"]),
          F("f11", "At NordicSwift 2026 I met Karin Lund (Swift Server Workgroup), who invited me to write a Swift.org guest post.", [r"karin|lund|guest post|swift\.org"]),
          F("f12", "I want to submit my NordicSwift talk, with a slower CRDT section, to two more conferences in 2027.", [r"submit|two more|2027"]),
          F("f13", "I'd rather not do live demos in talks again: the Wi-Fi at NordicSwift nearly failed.", [r"wi-?fi|(no|not|avoid)\b.*live demos?"]),
          F("f14", "I had to ask for a USB-C to HDMI adapter.", [r"\bUSB|HDMI|adapter"], keep="drop"),
      ],
      [M("the past talk read as upcoming", [r"\b(will give|am giving|'m giving|will present|will speak)\b"], [r"2027|submit|again|more"])]),

    E("e10", "Boda de Lucía (junio de 2027)", "2026-07-30", "agent_write", "low", ["personal_preferences"],
      [r"luc[ií]a", r"boda|casamiento"], [r"2027", r"2026", r"junio|marzo|fin de a[ñn]o"],
      """
La hermana del usuario, Lucía, se casa con Tomás Ferreyra el 12 de junio de 2027 en una estancia cerca de San Antonio de Areco, en la provincia de Buenos Aires. Lucía le pidió al usuario que sea el padrino de la boda y que diga unas palabras durante la cena; el usuario aceptó, aunque le pone nervioso hablar en público. La ceremonia será civil, a las 17:00, seguida de una cena para unas 120 personas. El usuario piensa viajar desde Lisboa con su pareja, Rui, y quedarse tres semanas en Argentina para visitar también a sus padres, que viven en Rosario. Lucía pidió que los invitados no lleven regalos y que, si quieren, aporten a un fondo para la luna de miel en Japón. El usuario quiere que su regalo sea pagar una noche del viaje de luna de miel. Tomás es veterinario y conoció a Lucía en la facultad. El código de vestimenta es formal de verano. El usuario preguntó qué significa "estancia" para explicárselo a Rui, y le dijeron que es una finca de campo. La organizadora de la boda es Marina Ocampo, que pidió confirmar asistencia antes del 1 de marzo de 2027 en un formulario en línea. El usuario todavía no compró los pasajes; quiere comprarlos antes de fin de año para que salgan más baratos.
""",
      [
          F("f01", "Mi hermana Lucía se casa con Tomás Ferreyra el 12 de junio de 2027.", [r"cas[ao]|boda|matrimonio", r"tom[aá]s|ferreyra|12 de junio"], timed=True),
          F("f02", "La boda de Lucía es en una estancia cerca de San Antonio de Areco.", [r"areco"], keep="either"),
          F("f03", "Soy el padrino de la boda de mi hermana Lucía y diré unas palabras en la cena.", [r"padrino"]),
          F("f04", "Me pone nervioso hablar en público.", [r"hablar en p[uú]blico"], other=True),
          F("f05", "La boda de Lucía será civil, a las 17:00, con una cena para unas 120 personas.", [r"civil|17:00|120"], keep="either"),
          F("f06", "Para la boda de Lucía pienso viajar desde Lisboa con Rui y quedarme tres semanas en Argentina.", [r"tres semanas|3 semanas"]),
          F("f07", "Mis padres viven en Rosario.", [r"padres", r"rosario"], other=True),
          F("f08", "Lucía pidió no llevar regalos a su boda y, si se quiere, aportar a un fondo para su luna de miel en Japón.", [r"fondo|sin regalos|no (lleven|llevar) regalos"]),
          F("f09", "Mi regalo para la boda de Lucía será pagar una noche de su luna de miel.", [r"\bnoche\b"]),
          F("f10", "Tomás Ferreyra, el novio de Lucía, es veterinario; se conocieron en la facultad.", [r"veterinari"], keep="either"),
          F("f11", "El código de vestimenta de la boda de Lucía es formal de verano.", [r"vestimenta|formal"], keep="either"),
          F("f12", "Pregunté qué significa \"estancia\": es una finca de campo.", [r"finca|significa"], keep="drop"),
          F("f13", "Tengo que confirmar asistencia a la boda de Lucía antes del 1 de marzo de 2027 (organizadora: Marina Ocampo).", [r"marzo|confirm|ocampo"], timed=True),
          F("f14", "Todavía no compré los pasajes para la boda de Lucía; quiero comprarlos antes de fin de 2026.", [r"pasajes|vuelos|billetes"], timed=True),
      ],
      [M("the sister's wedding read as the user's", [r"\bme caso\b|\bmi boda\b|\bmy wedding\b"])], lang="es"),

    # Harder: the entity is named only in the title (e11), or once at the start of a long two-chunk body (e12), and
    # then it's "the company", "the role": closer to the summaries that lost their context on a real vault.
    E("e11", "Interview loop at Verdant Grid (Staff Data Engineer)", "2026-10-14", "agent_write", "internal",
      ["project_context"], [r"verdant"], [r"2026", r"october|oct\b"],
      """
The user completed the interview loop for the Staff Data Engineer role last week. The company builds forecasting software for electricity grids and has about 120 employees, most of them in Copenhagen. The loop had four interviews, on Tuesday and Thursday. In the system design interview, the interviewer, Mette, asked the user to design a pipeline for smart-meter readings, and praised the user's enthusiasm and their questions about data quality. The hiring manager, Jonas, said the role is fully remote with a yearly team week in Copenhagen, and that the team works in Python and dbt on Snowflake. The user was weaker in the live SQL exercise and ran out of time on the last window-function question. The salary range they gave was DKK 85,000–95,000 a month. The recruiter asked whether the user needed visa sponsorship (they don't, as an EU citizen) and whether they could share their resume as a PDF, which they did the same day. The user asked what "FTE" meant on the contract summary; it means full-time equivalent. They expect to hear back by Friday next week. The user likes that the product is about the energy transition, but is unsure about the pay, which is below their current freelance income. They would negotiate for 100,000 a month if an offer comes.
""",
      [
          F("f01", "In the week of 5 October 2026 I completed the interview loop for the Staff Data Engineer role at Verdant Grid.", [r"completed|finished|went through"], timed=True),
          F("f02", "Verdant Grid builds forecasting software for electricity grids.", [r"forecast"]),
          F("f03", "Verdant Grid has about 120 employees, most of them in Copenhagen.", [r"\b120\b"], keep="either"),
          F("f04", "Verdant Grid's interview loop had four interviews, on 6 and 8 October 2026.", [r"four interviews|4 interviews|tuesday|thursday"], keep="either", timed=True),
          F("f05", "In Verdant Grid's system design interview I designed a pipeline for smart-meter readings.", [r"smart[- ]meter"], keep="either"),
          F("f06", "In Verdant Grid's interviews in October 2026, Mette praised my enthusiasm and my questions about data quality.", [r"enthusias|data quality"], timed=True),
          F("f07", "Verdant Grid's Staff Data Engineer role is fully remote, with a yearly team week in Copenhagen.", [r"remote"]),
          F("f08", "Verdant Grid's data team works in Python and dbt on Snowflake.", [r"\bdbt\b|snowflake"]),
          F("f09", "I was weaker in Verdant Grid's live SQL exercise and ran out of time on a window-function question.", [r"\bSQL\b|window[- ]function"]),
          F("f10", "Verdant Grid's salary range for the Staff Data Engineer role is DKK 85,000–95,000 a month.", [r"85[,. ]?000"]),
          F("f11", "I don't need visa sponsorship: I'm an EU citizen.", [r"visa|sponsor|EU citizen"], other=True),
          F("f12", "I shared my resume as a PDF.", [r"resume|résumé|\bCV\b"], keep="drop"),
          F("f13", "I asked what FTE means (full-time equivalent).", [r"\bFTE\b|full-time equivalent"], keep="drop"),
          F("f14", "I expect to hear back from Verdant Grid by 23 October 2026.", [r"hear back|hear from|23 october|october 23|decision"], timed=True),
          F("f15", "I like that Verdant Grid's product is about the energy transition.", [r"energy transition"]),
          F("f16", "Verdant Grid's pay is below my current freelance income, so I'm unsure about it.", [r"below|less than|lower than|unsure"]),
          F("f17", "If Verdant Grid makes an offer, I'd negotiate for DKK 100,000 a month.", [r"100[,. ]?000"]),
      ],
      [M("the offered role read as the user's job", [r"\bmy (job|role|work) is (fully )?remote|\bI work (fully )?remote"]),
       M("the salary range read as the user's salary", [r"\bmy (salary|pay)\b"], [r"range|offer|role|would|verdant|below"])]),

    E("e12", "Recruiter call about a CTO role", "2026-09-02", "agent_write", "sensitive", ["project_context", "finance"],
      [r"lumen"], [r"2026", r"september|sept?\b", r"march"],
      """
Yesterday the user had a call with Marta Sousa, an independent recruiter, about a CTO position at Lumen Health, a 35-person Porto startup that makes appointment software for dental clinics. Marta asked the user to keep the conversation private, because the current CTO hasn't announced that he is leaving. The founders want someone who can still write code for the first year and grow the team from 6 to 15 engineers. The role pays €110,000 a year plus 1.5% equity vesting over four years, with a one-year cliff. It's hybrid, two days a week in the Porto office, which would mean commuting by train from Lisbon or moving. The company raised a €6M seed round in March and has about 20 months of runway. The stack is Kotlin on the backend and React on the web. There is no iOS app yet, and the founders would like the new CTO to start one.

Marta explained that the process would be a conversation with the two founders, a half-day with the team and a reference call. The user said the equity sounded low for a CTO and asked whether there was room to negotiate; Marta thought 2% might be possible. The user is interested in the iOS work and in being a CTO, but is worried about the commute and about the runway. Marta asked if the user had a portfolio site, and the user sent her the link. She mentioned that she mostly places fintech roles and that this one was an exception. The user wants to talk it over with their partner before deciding whether to continue, and told Marta they would reply by the end of next week. The call was meant to take 30 minutes and ran to an hour. Afterwards the user asked what a one-year cliff means, and it was explained that no equity vests until the first anniversary. They also noted that the founders had previously worked together at a hospital software company, which the user saw as a good sign for the product, and that the job ad they had seen earlier listed the role as fully remote, which Marta said was out of date. The user plans to look up the founders on LinkedIn before replying. Marta said the founders would like an answer before the end of September, because they want the new CTO to start in January 2027. The role comes with a €3,000 yearly training budget, which the user would spend on conferences. The office is near São Bento station, about ten minutes' walk from the platform, so the train commute from Lisbon would be about three hours each way door to door.
""",
      [
          F("f01", "On 1 September 2026 recruiter Marta Sousa pitched me a CTO position at Lumen Health.", [r"marta|sousa", r"call|spoke|talked|pitch|contact"], timed=True),
          F("f02", "Lumen Health is a 35-person Porto startup making appointment software for dental clinics.", [r"dental|appointment software"]),
          F("f03", "The Lumen Health CTO opening is private: the current CTO hasn't announced he is leaving (September 2026).", [r"private|confidential|announc"], timed=True),
          F("f04", "Lumen Health's founders want a CTO who still writes code for the first year and grows the team from 6 to 15 engineers.", [r"\b15\b|write code|still code|coding"]),
          F("f05", "The Lumen Health CTO role pays €110,000 a year.", [r"110"]),
          F("f06", "The Lumen Health CTO role includes 1.5% equity vesting over four years with a one-year cliff.", [r"1[.,]5 ?%"]),
          F("f07", "The Lumen Health CTO role is hybrid, two days a week in the Porto office.", [r"hybrid|two days|2 days"]),
          F("f08", "Lumen Health's hybrid role would mean commuting by train from Lisbon or moving to Porto.", [r"\btrain\b"], keep="either"),
          F("f09", "Lumen Health raised a €6M seed round in March 2026.", [r"\bseed\b|€ ?6 ?m"], timed=True),
          F("f10", "As of September 2026 Lumen Health had about 20 months of runway.", [r"20 months|twenty months"], timed=True),
          F("f11", "Lumen Health's stack is Kotlin on the backend and React on the web.", [r"kotlin|react"], keep="either"),
          F("f12", "Lumen Health has no iOS app yet; the founders want the new CTO to start one.", [r"no ios|ios app yet|start (one|an ios|the ios)|build (an|the) ios"]),
          F("f13", "Lumen Health's process: a conversation with the founders, a half-day with the team and a reference call.", [r"half-day|half day|reference call"], keep="either"),
          F("f14", "I told Marta the Lumen Health equity was low for a CTO; she thought 2% might be possible.", [r"\b2 ?%|negotiat"]),
          F("f15", "I'm interested in the iOS work and in being CTO at Lumen Health.", [r"interest"]),
          F("f16", "I'm worried about the Lumen Health commute and runway.", [r"worr|concern"]),
          F("f17", "I sent Marta my portfolio link.", [r"portfolio"], keep="drop"),
          F("f18", "Marta mostly places fintech roles.", [r"fintech"], keep="drop"),
          F("f19", "I want to talk to my partner before deciding whether to continue with Lumen Health.", [r"partner"]),
          F("f20", "I told Marta I'd reply about Lumen Health by about 11 September 2026.", [r"reply|respond|get back to"], timed=True),
          F("f21", "The call ran to an hour instead of 30 minutes.", [r"an hour|30 minutes|30-minute|ran (long|over)"], keep="drop"),
          F("f22", "I asked what a one-year cliff means: no equity vests until the first anniversary.", [r"first anniversary|no equity vests|cliff means"], keep="drop"),
          F("f23", "Lumen Health's founders previously worked together at a hospital software company, a good sign to me.", [r"hospital"], keep="either"),
          F("f25", "Lumen Health's founders want the new CTO to start in January 2027.", [r"january 2027|jan(uary)? 2027"], timed=True),
          F("f26", "The Lumen Health CTO role comes with a €3,000 yearly training budget.", [r"3[,. ]?000|training budget"]),
          F("f27", "Lumen Health's office is near São Bento station; the train commute from Lisbon would be about three hours each way.", [r"s[ãa]o bento|three hours"], keep="either"),
          F("f24", "The Lumen Health job ad listing the role as fully remote was out of date.", [r"out of date|outdated|\bad\b|job ad"], keep="either"),
      ],
      [M("the pitched salary read as the user's", [r"\bmy (salary|pay)\b|\bI (earn|make)\b"], [r"would|offer|role|cto|lumen"]),
       M("the user read as a CTO now", [r"\bI(?:'m| am) (the |a )?CTO\b"], [r"would|role|position|offer|becom|being"]),
       M("the outdated remote listing read as true", [r"fully remote"], [r"out of date|outdated|\bad\b|listed|listing|not"])]),
]


def main():
    note = ("Synthetic Spike F fixtures: long agent-written memories about one episode or entity each. Every person, "
            "company, place and number is invented. See build_episodes.py for the labels and matching rules.")
    out = {"format": "funes.fixture.episodes.v1", "note": note, "episodes": EPISODES}
    (HERE / "fixtures" / "episodes.json").write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n")
    n = sum(len(e["facts"]) for e in EPISODES)
    by = {k: sum(f["keep"] == k for e in EPISODES for f in e["facts"]) for k in ("keep", "either", "drop")}
    print(f"{len(EPISODES)} episodes, {n} facts {by}, other {sum(f['other'] for e in EPISODES for f in e['facts'])}")
    for e in EPISODES:
        print(f"  {e['id']}: {len(e['text'])} chars, {len(e['facts'])} facts")


if __name__ == "__main__":
    main()
