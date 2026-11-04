"""Code validation of model output: memory processing §1 (secret scanner), §5.4 (extraction) and §9.4 (tidy-up)."""
import re
import unicodedata

from prompts import CATEGORY_DEFAULT, CATEGORY_KEYS, KINDS, SENSITIVITIES

# --- §1 secret scanner (a port of FunesProtocol's SecretScanner patterns) ---------------------------------
SECRET_PATTERNS = [
    ("private_key", re.compile(r"-----BEGIN (RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY-----", re.I)),
    ("aws_access_key", re.compile(r"\b(AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("openai_style_key", re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b")),
    ("github_token", re.compile(r"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{22,}\b")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")),
    ("assigned_secret", re.compile(
        r"\b(api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|password)\b\s*[:=]\s*[\"']?"
        r"(?:[^\"'\s]{12,}|(?!1password\b)(?=[^\"'\s]*[A-Za-z])(?=[^\"'\s]*[0-9])[^\"'\s]{8,})", re.I)),
    ("slack_token", re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,}\b")),
    ("stripe_key", re.compile(r"\b(sk|rk)_(live|test)_[A-Za-z0-9]{16,}\b")),
    ("google_api_key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b")),
    ("funes_or_ekb_key", re.compile(r"\b(fns|ekb)_(mcp|mcpr)_v1_[0-9a-f]{64}\b")),
]
CARD = re.compile(r"\b(?:\d[ -]?){12,18}\d\b")


def _luhn(digits):
    total, alt = 0, False
    for d in reversed(digits):
        n = int(d)
        if alt:
            n = n * 2 - 9 if n > 4 else n * 2
        total += n
        alt = not alt
    return total % 10 == 0


def scan_secrets(*texts):
    found = []
    for t in texts:
        for name, rx in SECRET_PATTERNS:
            if rx.search(t or ""):
                found.append(name)
        for m in CARD.finditer(t or ""):
            digits = re.sub(r"\D", "", m.group())
            if 13 <= len(digits) <= 19 and _luhn(digits):
                found.append("credit_card")
    return sorted(set(found))


# --- §5.4 extraction ---------------------------------------------------------------------------------------
def normalize(s):
    s = unicodedata.normalize("NFKC", s or "")
    s = s.replace("’", "'").replace("‘", "'").replace("“", '"').replace("”", '"')
    s = s.replace("–", "-").replace("—", "-").replace("−", "-")
    return re.sub(r"\s+", " ", s).strip().lower()


def quote_ok(quote, source_norm):
    q = normalize(quote).strip(" \"'.,;:…")
    q = q.rstrip(".").strip()
    return bool(q) and q in source_norm


STOP = set("""a an the and or but so of to in on at for with from by as is are was were be been being am i me my mine we us
our you your they them their he she his her it its this that these those there here do does did have has had
having not no nor only also just very really now then than too can could would should will shall may might must
about into over under after before again more most some any each every all both few other such own same up down out
off what which who whom when where why how if because while during until again further once user user's i'm i've
i'd i'll it's don't doesn't didn't isn't aren't wasn't weren't won't can't cannot yes one get gets got go goes
going keep keeps like likes prefer prefers want wants use uses using make makes made per via""".split())


def _stem(w):
    for suf in ("'s", "ing", "ed", "es", "s"):
        if len(w) > 4 and w.endswith(suf):
            return w[: -len(suf)]
    return w


def content_words(text):
    words = re.findall(r"[0-9]+(?:[.,:][0-9]+)*|[^\W\d_]+(?:'[^\W\d_]+)?", normalize(text))
    return {_stem(w) for w in words if w not in STOP and len(w) > 1}


def support_check(body, evidence, source):
    """Content words in the body that aren't in its evidence (§5.4 support): returns (not_in_evidence, not_in_input)."""
    ev = set().union(*[content_words(q) for q in evidence]) if evidence else set()
    src = content_words(source)
    novel = content_words(body) - ev
    return sorted(novel), sorted(novel - src)


SENS_RANK = {s: i for i, s in enumerate(SENSITIVITIES)}


def max_sens(*levels):
    levels = [l for l in levels if l in SENS_RANK]
    return max(levels, key=SENS_RANK.get) if levels else "low"


def validate_pieces(pieces, source_text, hint_sensitivity=None, declared=None, evidence_mode="strict"):
    """Returns (kept, dropped). Each kept piece gets 'validation' notes; floors applied to sensitivity."""
    src = normalize(source_text)
    kept, dropped, seen = [], [], set()
    for p in pieces or []:
        p = dict(p)
        # Quotes lose the prompt's delimiter tags; empty quotes are ignored (Apple on-device returns both).
        ev = [re.sub(r"</?(note|context)>", "", q).strip() for q in p.get("evidence") or [] if isinstance(q, str)]
        ev = [q for q in ev if q]
        p["evidence"] = ev
        oks = [quote_ok(q, src) for q in ev]
        reasons = []
        if not ev or (evidence_mode == "strict" and not all(oks)) or (evidence_mode == "lenient" and not any(oks)):
            reasons.append("evidence")
        body, title = (p.get("body") or "").strip(), (p.get("title") or "").strip()
        if not body:
            reasons.append("empty")
        if scan_secrets(title, body, *ev):
            reasons.append("secret")
        if reasons:
            p["dropReasons"] = reasons
            dropped.append(p)
            continue
        cats = [c for c in p.get("categoryKeys") or [] if c in CATEGORY_KEYS][:3] or ["personal_preferences"]
        p["categoryKeys"] = cats
        p["kind"] = p.get("kind") if p.get("kind") in KINDS else "fact"
        p["modelSensitivity"] = p.get("sensitivity")
        p["sensitivity"] = max_sens(p.get("sensitivity"), *[CATEGORY_DEFAULT[c] for c in cats], hint_sensitivity, declared)
        p["title"] = title[:80]
        p["body"] = body[:2000]
        novel_ev, novel_src = support_check(body, ev, source_text)
        p["support"] = {"notInEvidence": novel_ev, "notInInput": novel_src}
        key = normalize(body)
        if key in seen:
            p["dropReasons"] = ["duplicate_piece"]
            dropped.append(p)
            continue
        seen.add(key)
        kept.append(p)
    return kept, dropped


# --- §9.4 tidy-up ------------------------------------------------------------------------------------------
def validate_actions(actions, cluster):
    """Returns (kept, blocked) with a reason per blocked action. Confidence thresholds are applied when scoring."""
    mems = {m["id"]: m for m in cluster["memories"]}
    used, archived, survivors, kept, blocked = set(), set(), set(), [], []

    def block(a, why):
        a = dict(a)
        a["blockReason"] = why
        blocked.append(a)

    for a in actions or []:
        t = a.get("type")
        if t in ("update", "split"):
            ids = [a.get("target")]
        elif t == "archive":
            ids = [a.get("target"), a.get("survivor")]
        elif t == "merge":
            ids = list(dict.fromkeys(a.get("sources") or []))
        elif t == "conflict":
            ids = list(dict.fromkeys(a.get("ids") or []))
        else:
            block(a, "unknown_type")
            continue
        if any(i not in mems for i in ids):
            block(a, "unknown_id")
            continue
        if t == "archive" and a.get("target") == a.get("survivor"):
            block(a, "survivor_archived")
            continue
        if t == "merge" and len(ids) < 2:
            block(a, "merge_needs_two")
            continue
        if t == "conflict" and len(ids) != 2:
            block(a, "conflict_needs_two")
            continue
        changed = ids if t in ("merge",) else [a.get("target")] if t != "conflict" else []
        if any(i in used for i in changed):
            block(a, "memory_in_two_actions")
            continue
        if t == "archive" and (a.get("survivor") in archived or a.get("target") in survivors):
            block(a, "survivor_archived")
            continue
        if t == "merge":
            sens = {mems[i]["sensitivity"] for i in ids}
            cats = {tuple(sorted(mems[i]["categories"])) for i in ids}
            if len(sens) > 1:
                block(a, "merge_mixed_sensitivity")
                continue
            if len(cats) > 1:
                block(a, "merge_mixed_categories")
                continue
        if scan_secrets(a.get("title", ""), a.get("body", "")):
            block(a, "secret")
            continue
        if t in ("update", "merge") and not (a.get("body") or "").strip():
            block(a, "empty_body")
            continue
        used.update(changed)
        if t == "archive":
            archived.add(a.get("target"))
            survivors.add(a.get("survivor"))
        kept.append(a)
    return kept, blocked
