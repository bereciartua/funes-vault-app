# The predicate registry (Spike H3)

`registry.json` defines every kind of fact Funes learns about the user. One implementation (`facts.py`) reads it for extraction, validation, role resolution, the timeline and timeline questions; no code names a predicate. This is ADR-0032 decision 2 and plan v6 §4.

## Top level
- `version`: bump on every change.
- `language`: words shared by every predicate.
  - `owners`: possessives that start a role phrase ("my", "mi", "the user's").
  - `status_cues.former` / `status_cues.current`: modifiers before a role word that select former or current holders ("my old boss", "my new partner").
  - `modifiers`: words allowed between the owner and the role word.
  - `date_cue_words`: modifiers that resolve on the timeline as of the memory's date ("my previous job"); only for predicates with the `timeline` use, otherwise they act as a former cue.
  - `operators`: words for "before", "after", "previous", "current" in queries (English and Spanish). A year in a query is the "year" operator.
  - `episode_first` / `episode_last`: words that pick the first or the latest episode when an anchor has several ("my first job at Acme", "after I returned to Acme").
  - `pair_before`, `pair_adverbs`: the "X is (also) my R" template.
  - `stop_names`: names that are also common words.
- `kinds`: per entity kind, how names match (`first_name`, `contains`, `exact`) and are normalised (`legal_suffix`).
- `call_groups`: each group is one extraction call per memory; `intro` completes "You read one memory … and ___".

## A predicate
| Field | Meaning |
|---|---|
| `id` | Stable id, `snake_case` |
| `object_kind` | `person`, `organization`, `place` or `thing` |
| `call_group` | Which extraction call reads it |
| `uses` | `recorded` (extracted and stored), `linked` (search admission, attributes), `timeline` ("before / after / in / current / previous" answers). Each use needs the ones before it |
| `definition` | The text the extraction prompt shows for this predicate |
| `exclusive` | At most one current at a time; lets a sole known holder of a role phrase resolve as certain |
| `succession` | A new fact probably ends the previous open one in the same slot (only for facts not already stated as ended, only on trusted text, only when that was the only open fact in the slot) |
| `slot` | The qualifier whose value separates parallel tracks for succession (e.g. a job's `kind`), or null |
| `gap_months` | A gap longer than this between successive facts is told instead of answered; null when gaps aren't meaningful |
| `qualifiers` | Typed attributes of a fact, each `{multi, describe, values?}`; `label` is the user's own word |
| `lexicon` | Role phrases in memories: `{cls, words, generic?, plural?, exclusive?}`. `generic` matches any label of the predicate ("my partner" matches a wife); `plural` means the whole group ("my parents"); `exclusive` makes that one label exclusive ("mom") |
| `placeholders` | Object names that may not appear in the text, with synonyms ("Self-employed": "freelance", "sole trader") |
| `query_cues` | Words that make a query about this predicate (with the lexicon words) |
| `phrases` | `attribute` (how an answer describes the fact) and `note_noun` ("Funes can't tell which ___ came before …") |

## The timeline rule (every predicate with the `timeline` use)
- A fact's episodes come from the start and end dates its memories state, at the precision written; a start after an end is a new episode (rejoined, back together).
- "Before X": the fact with a stated `followed_by` / `preceded_by` edge to X; otherwise the episode that ended latest at or before X's episode started. Current or overlapping episodes never qualify. Ties at the written precision, conflicting dates, a gap longer than `gap_months`, or an anchor with several episodes and no cue are told, never guessed. "After X" mirrors it.
- A timeline query needs a predicate's query cue (or lexicon word), an operator, and a named anchor that holds a fact of the same predicate.
