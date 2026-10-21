#!/usr/bin/env python3
"""Plan the lesson and level-intro videos and write their narration with local Qwen (manzi-14b).

  python3 tools/video_script.py                       # every video; cached calls are reused
  python3 tools/video_script.py --only lesson-L03-2   # one video (repeatable)
  python3 tools/video_script.py --force               # ignore the cache

Reads   assets/data/curriculum.json, chords.json, chord_tips.json
Writes  content/videos/<id>.json   (one script per video, rendered by tools/video_render.py)

Scene structure and every musical fact (finger placement, notes, patterns, songs, tips) come
from the course data. Qwen writes the spoken narration and on-screen key points. Each Qwen line
passes two checks before it is used:
  1. a deterministic check: every string/fret/finger number and digit it mentions must appear
     in the scene's facts;
  2. a second Qwen call acting as fact-checker.
Failures are retried with the problem fed back, then fall back to reviewed course text.
"""
import argparse
import json
import os
import re
import sys
import time

import qwen

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "assets", "data")
OUT = os.path.join(ROOT, "content", "videos")
CACHE_PATH = os.path.join(ROOT, "tools", ".qwen_video_cache.json")

NARRATOR = (
    "You write voice-over narration for a short animated guitar lesson video for complete beginners. "
    "The narrator speaks directly to the learner in warm, clear, natural spoken English. "
    "Use only the facts provided. Never invent chord shapes, string, fret or finger numbers, notes, "
    "song names, history or techniques. Write numbers as digits. "
    "No markdown, no emojis, no stage directions, no greetings to an audience."
)
CHECKER = (
    "You are a strict fact-checker for guitar lesson narration. Compare the narration with the facts. "
    "General encouragement and paraphrasing are fine."
)
NARRATION_SCHEMA = {
    "type": "object",
    "properties": {"narration": {"type": "string"}, "points": {"type": "array", "items": {"type": "string"}}},
    "required": ["narration", "points"],
}
CHECK_SCHEMA = {"type": "object", "properties": {"ok": {"type": "boolean"}, "problem": {"type": "string"}},
                "required": ["ok", "problem"]}

NUMBER_WORDS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
                "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "first": 1, "second": 2, "third": 3}
STATS = {"scenes": 0, "qwen_lines": 0, "retries": 0, "fallbacks": 0}


def load(name):
    with open(os.path.join(DATA, name)) as f:
        return json.load(f)


# ---------------------------------------------------------------------------- fact checking

def _normalize(text):
    t = text.lower()
    for word, n in NUMBER_WORDS.items():
        t = re.sub(r"\b%s\b" % word, str(n), t)
    return t


def claims(text):
    """('string', 5)-style claims ('strings 4, 3 and 2' -> string 4/3/2, number words included) plus
    other digits of 3 or more ('3 times', '80 beats'); 1 and 2 are too common in speech to police."""
    t = _normalize(text)
    found = set()
    for m in re.finditer(r"\b(string|fret|finger)s?\s+((?:\d+(?:\s*(?:,|and|or|to|-)\s*)?)+)", t):
        for n in re.findall(r"\d+", m.group(2)):
            found.add((m.group(1), int(n)))
    numbers = {int(n) for n in re.findall(r"\b\d+\b", text) if int(n) >= 3}
    return found, numbers


def unsupported(text, facts):
    """Claims in [text] that the facts don't back up (empty list = fine)."""
    said, said_numbers = claims(text)
    known, known_numbers = claims(facts)
    bad = ["%s %d" % c for c in sorted(said - known)]
    bad += [str(n) for n in sorted(said_numbers - known_numbers - {n for _, n in said})]
    return bad


DANGLING = {"and", "or", "so", "the", "to", "with", "of", "on", "at", "for", "a", "an", "your", "from", "into", "then", "but"}


def _words(text):
    return re.findall(r"[a-z0-9']+", text.lower())


def point_problem(p, narration=""):
    """Why an on-screen key point reads badly (cut off mid-phrase), or '' if it's fine."""
    words = p.split()
    if not words or len(words) > 6:
        return "Key points must be 1 to 6 words."
    if re.search(r"[,;:\u2014\u2013-]$", p) or "\u2014" in p or "\u2013" in p:
        return "Key points must be complete phrases without dashes or trailing punctuation."
    if words[-1].lower() in DANGLING or re.search(r"\bstrings \d+$", p):
        return "Key point '%s' is cut off; rewrite it as a complete short phrase." % p
    # A copy of the first few words of a longer narration sentence is a cut-off sentence.
    pw = _words(p)
    for sentence in sentences(narration):
        sw = _words(sentence)
        if len(sw) > len(pw) and sw[:len(pw)] == pw:
            return "Key point '%s' just cuts a sentence short; summarise the idea as a complete phrase of at most 6 words." % p
    return ""


def speech_ok(text, max_words):
    words = text.split()
    return 0 < len(words) <= max_words and not re.search(r"[#*_`\[\]{}<>]", text)


def narrate(cache, video_title, purpose, facts, spec, max_words, fallback, points=None, max_points=4):
    """Qwen narration (+ optional key points) that passed both checks, else [fallback]."""
    STATS["scenes"] += 1
    want_points = points == "qwen"
    prompt = ("Video: %s\nScene: %s\nFacts:\n%s\n\nWrite %s Keep it under %d words.%s"
              % (video_title, purpose, facts, spec, max_words,
                 " Also give %d to %d on-screen key points of at most 6 words each." % (2, max_points)
                 if want_points else " Return an empty list for points."))
    feedback = ""
    for attempt in range(3):
        key = qwen.Cache.key(NARRATOR, prompt + feedback)
        result = cache.get(key)
        if result is None:
            try:
                out = qwen.chat_json(NARRATOR, prompt + feedback, NARRATION_SCHEMA, max_tokens=350)
            except (ValueError, KeyError):
                out = {"narration": "", "points": []}
            narration = " ".join(str(out.get("narration", "")).split())
            pts = [" ".join(str(p).split()).rstrip(".") for p in out.get("points", [])][:max_points]
            problem = _format_problem(narration, pts, want_points, max_words, max_points)
            if not problem:
                bad = unsupported(narration + " " + " ".join(pts), facts)
                if bad:
                    problem = "These details are not in the facts: %s." % ", ".join(bad)
                else:
                    try:
                        check = qwen.chat_json(CHECKER, "FACTS:\n%s\n\nNARRATION:\n%s\nKEY POINTS: %s\n\nDoes the narration "
                                           "or any key point contradict the facts or add a musical detail (string, fret "
                                           "or finger numbers, notes, chord names, techniques) that is not in the facts?"
                                           " Answer ok=true if it is accurate." % (facts, narration, "; ".join(pts)),
                                           CHECK_SCHEMA, temperature=0.0, max_tokens=150)
                    except (ValueError, KeyError):
                        check = {"ok": False, "problem": "The check could not be completed."}
                    if not check.get("ok", False):
                        problem = str(check.get("problem", "inaccurate")).strip() or "inaccurate"
            result = {"narration": narration, "points": pts, "problem": problem}
            cache.put(key, result)
        elif not result["problem"]:
            # Format rules may have tightened since this answer was cached.
            result = dict(result, problem=_format_problem(result["narration"], result["points"], want_points, max_words, max_points))
        if not result["problem"]:
            STATS["qwen_lines"] += 1
            return result["narration"], (result["points"] if want_points else (points or []))
        STATS["retries"] += 1
        feedback = "\nA previous attempt was rejected: %s Fix that." % result["problem"]
    STATS["fallbacks"] += 1
    # Reviewed text is spoken; no bullets are better than bullets that cut sentences short.
    return fallback, (points if isinstance(points, list) else [])


POINTS_SCHEMA = {"type": "object", "properties": {"points": {"type": "array", "items": {"type": "string"}}}, "required": ["points"]}


def summary_points(cache, video_title, facts, narration):
    """A points-only request for screens whose narration call couldn't produce clean bullets.
    Each point is checked on its own; the screen needs at least 2 good ones."""
    prompt = ("Video: %s\nFacts:\n%s\nNarration: %s\n\nGive 3 on-screen key points for this screen. Each must be a "
              "complete phrase of at most 6 words that summarises an idea, for example 'Finger 2: string 5, fret 2', "
              "'Strum from string 4' or 'Press just behind the fret'. Do not copy the start of a sentence. No dashes."
              % (video_title, facts, narration))
    feedback = ""
    for attempt in range(3):
        key = qwen.Cache.key(NARRATOR, "POINTS", prompt + feedback)
        out = cache.get(key)
        if out is None:
            try:
                out = qwen.chat_json(NARRATOR, prompt + feedback, POINTS_SCHEMA, max_tokens=150)
            except (ValueError, KeyError):
                out = {"points": []}
            cache.put(key, out)
        good, problems = [], []
        for p in out.get("points", [])[:4]:
            p = " ".join(str(p).split()).rstrip(".")
            problem = point_problem(p, narration) or ("not in the facts: %s" % ", ".join(unsupported(p, facts))
                                                       if unsupported(p, facts) else "")
            (problems if problem else good).append(problem or p)
        if len(good) >= 2:
            STATS["qwen_lines"] += 1
            return good
        STATS["retries"] += 1
        feedback = "\nA previous attempt was rejected: %s" % " ".join(problems[:2])
    return []


def _format_problem(narration, pts, want_points, max_words, max_points):
    if not speech_ok(narration, max_words):
        return "It must be plain spoken text under %d words." % max_words
    if want_points:
        if not 2 <= len(pts) <= max_points:
            return "Give 2 to %d key points." % max_points
        for p in pts:
            problem = point_problem(p, narration)
            if problem:
                return problem
    return ""


def sentences(text):
    return [s.strip() for s in re.split(r"(?<=[.!?])\s+(?=[A-Z0-9])", text) if s.strip()]


# ---------------------------------------------------------------------------- course facts

class Course:
    def __init__(self):
        self.curriculum = load("curriculum.json")
        self.chords = {c["id"]: c for c in load("chords.json")["chords"]}
        self.tips = load("chord_tips.json")
        self.songs = {s["id"]: s for s in self.curriculum["songs"]}

    def symbol(self, cid):
        return self.chords[cid].get("symbol", cid)

    def placement(self, cid):
        """Spoken, data-derived finger placement for a chord."""
        c = self.chords[cid]
        lines = []
        barre = c.get("barre")
        if barre:
            lines.append("Lay finger 1 flat across fret %d, from string %d to string %d." % (barre["fret"], barre["from"], barre["to"]))
        fingers = []
        for i, (fret, finger) in enumerate(zip(c["frets"], c["fingers"])):
            if fret > 0 and not (barre and finger == 1 and fret == barre["fret"]):
                fingers.append((finger, 6 - i, fret))
        for finger, string, fret in sorted(fingers):
            lines.append("Finger %d goes on string %d, fret %d." % (finger, string, fret))
        muted = [6 - i for i, f in enumerate(c["frets"]) if f < 0]
        if muted:
            lines.append("Don't play string%s %s." % ("s" if len(muted) > 1 else "", _join(muted)))
        return lines

    def chord_facts(self, cid):
        c = self.chords[cid]
        played = [6 - i for i, f in enumerate(c["frets"]) if f >= 0]
        return ("Chord: %s (%s). %s Strum from string %d. Strings played: %s. Tip: %s"
                % (c["name"], self.symbol(cid), " ".join(self.placement(cid)), played[0], _join(played), self.tips[cid]))


def _join(items):
    items = [str(i) for i in items]
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + " and " + items[-1]


def spoken_pattern(pattern):
    names = {"D-": "down", "DU": "down-up", "-U": "up", "--": "rest", "DD": "down-down", "U-": "up", "UU": "up-up", "-D": "down"}
    return ", ".join(names.get(pattern[i:i + 2], "down") for i in range(0, len(pattern), 2))


NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
TUNING = {6: 40, 5: 45, 4: 50, 3: 55, 2: 59, 1: 64}


def note_label(string, fret):
    name = NOTE_NAMES[(TUNING[string] + fret) % 12]
    return "string %d %s (%s)" % (string, "open" if fret == 0 else "fret %d" % fret, name)


# ---------------------------------------------------------------------------- video plans

def lesson_video(course, cache, level, level_index, lesson):
    title = lesson["title"]
    vid = "lesson-" + lesson["id"]
    scenes = []
    line, _ = narrate(cache, title, "Opening title card of the lesson.",
                      "Lesson: %s. This lesson covers only: %s. It is part of level %d of 12, '%s'."
                      % (title, lesson["summary"], level_index, level["title"]),
                      "1 or 2 sentences that welcome the learner and say what this lesson teaches. "
                      "Mention nothing beyond this lesson.", 35,
                      "%s. %s" % (title, lesson["summary"]))
    scenes.append({"type": "title", "title": title, "subtitle": lesson["summary"], "lines": sentences(line)})

    shown_chords, key_points, chords_used, listens = set(), [], [], False
    for step in lesson["steps"]:
        kind = step["type"]
        if kind == "info":
            facts = "Screen title: %s. Text: %s" % (step["title"], step["body"])
            narration, pts = narrate(cache, title, "Teaching scene about '%s'." % step["title"], facts,
                                     "2 to 4 spoken sentences that teach this clearly.", 70, step["body"], points="qwen")
            if not pts:
                pts = summary_points(cache, title, facts, narration)
            scenes.append({"type": "points", "heading": step["title"], "points": pts, "lines": sentences(narration),
                           "chord": step.get("chord")})
            key_points += pts
            if step.get("chord") and step["chord"] not in shown_chords:
                scenes.append(chord_scene(course, cache, title, step["chord"]))
                shown_chords.add(step["chord"])
                chords_used.append(step["chord"])
        elif kind == "chord":
            listens = True
            if step["chord"] not in shown_chords:
                scenes.append(chord_scene(course, cache, title, step["chord"]))
                shown_chords.add(step["chord"])
                chords_used.append(step["chord"])
        elif kind == "change":
            listens = True
            names = [course.chords[c]["name"] for c in step["chords"]]
            facts = "Practise changing between %s. %s" % (_join(names), step.get("body", ""))
            line, _ = narrate(cache, title, "Chord-change demo: the chords are played one after another.", facts,
                              "1 or 2 sentences introducing this chord change.", 35,
                              "Now let's switch between %s. Listen first." % _join(names))
            scenes.append({"type": "change", "chords": step["chords"], "lines": sentences(line)})
        elif kind == "notes":
            listens = True
            notes = step["notes"][:8]
            facts = "Exercise: %s. %s Notes, in order: %s." % (step["title"], step.get("body", ""),
                                                               "; ".join(note_label(s, f) for s, f in notes))
            line, _ = narrate(cache, title, "Melody demo: the notes light up on the tab and fretboard as they play.",
                              facts, "1 or 2 sentences introducing this exercise.", 35,
                              "%s. Watch the tab and listen to each note." % step["title"])
            scenes.append({"type": "notes", "title": step["title"], "notes": notes, "lines": sentences(line)})
        elif kind == "strum":
            listens = True
            facts = ("Strumming pattern for one bar: %s. Tempo %d beats per minute, %d beats per bar. Chords: %s. %s"
                     % (spoken_pattern(step["pattern"]), step["bpm"], step.get("beatsPerBar", 4),
                        _join(course.symbol(c) for c in step["chords"]), step.get("body", "")))
            line, _ = narrate(cache, title, "Strumming demo with a metronome; the pattern lights up as it plays.", facts,
                              "1 or 2 sentences introducing the pattern.", 40,
                              "Here's the pattern: %s. Listen and watch the arrows." % spoken_pattern(step["pattern"]))
            scenes.append({"type": "strum", "pattern": step["pattern"], "bpm": step["bpm"],
                           "beatsPerBar": step.get("beatsPerBar", 4), "chords": step["chords"], "lines": sentences(line)})
        elif kind == "song":
            listens = True
            song = course.songs[step["song"]]
            chords = list(dict.fromkeys(b for l in song["lines"] for b in l["bars"]))
            facts = ("Song: %s (%s). Chords: %s. Time: %d beats per bar at %d beats per minute. First line: %s"
                     % (song["title"], song["credit"], _join(course.symbol(c) for c in chords), song["beatsPerBar"],
                        song["bpm"], song["lines"][0]["lyrics"] or "instrumental"))
            line, _ = narrate(cache, title, "Song preview: the chord chart plays and each bar lights up.", facts,
                              "1 or 2 sentences introducing the song.", 35,
                              "Let's play %s. It uses %s." % (song["title"], _join(course.symbol(c) for c in chords)))
            scenes.append({"type": "song", "song": song["id"], "lines": sentences(line)})
        elif kind == "tune":
            listens = True
            facts = "%s Standard tuning from string 6 to string 1: E, A, D, G, B, E." % step.get("body", "")
            line, _ = narrate(cache, title, "Tuning scene: each open string is played as a reference.", facts,
                              "1 or 2 sentences about tuning each string.", 35,
                              "Tune one string at a time. Here is how each open string should sound.")
            scenes.append({"type": "tuner", "lines": sentences(line)})

    facts = "Lesson: %s (%s). Key points: %s. Chords covered: %s.%s" % (
        title, lesson["summary"], "; ".join(key_points) or "none", _join([course.symbol(c) for c in chords_used]) if chords_used else "none",
        " Next, the app listens through the microphone while the learner plays." if listens else "")
    line, _ = narrate(cache, title, "Closing recap.", facts,
                      "1 or 2 sentences wrapping up%s." % (" and inviting the learner to play while the app listens" if listens else ""),
                      30, "Great work on %s.%s" % (title, " Now it's your turn: the app is listening." if listens else ""))
    scenes.append({"type": "recap", "points": recap_points(course, key_points, scenes), "lines": sentences(line)})
    return {"id": vid, "kind": "lesson", "title": title, "subtitle": lesson["summary"], "levelId": level["id"],
            "levelIndex": level_index, "levelTitle": level["title"], "lessonId": lesson["id"], "scenes": scenes}


def recap_points(course, key_points, scenes):
    """Checklist for the recap: verified key points from this video, else facts from its scenes."""
    pts = list(dict.fromkeys(p for p in key_points if not point_problem(p)))[:3]
    for s in scenes:
        if len(pts) >= 3:
            break
        if s["type"] == "chord":
            pts.append("%s chord shape" % course.symbol(s["chord"]))
        elif s["type"] == "change":
            pts.append("Change %s" % " to ".join(course.symbol(c) for c in s["chords"][:2]))
        elif s["type"] == "strum":
            pts.append("Pattern: %s" % s["pattern"].replace("-", " "))
        elif s["type"] == "song":
            song = course.songs[s["song"]]
            pts.append("Play %s" % song["title"])
            pts.append("Wait mode, then play along")
        elif s["type"] == "notes":
            pts.append(" ".join(s["title"].split()[:5]))
        elif s["type"] == "tuner":
            pts.append("Tune all six strings")
    return list(dict.fromkeys(pts))[:3]


def chord_scene(course, cache, title, cid):
    c = course.chords[cid]
    intro, _ = narrate(cache, title, "Chord scene: the chord diagram and tab appear, then each finger is placed.",
                       course.chord_facts(cid), "1 short sentence introducing this chord, before the finger placement is read out.",
                       22, "Let's build %s." % c["name"])
    lines = sentences(intro) + course.placement(cid) + ["Here's how it sounds: strummed, then string by string."]
    return {"type": "chord", "chord": cid, "lines": lines, "tip": course.tips[cid],
            "placementFrom": len(sentences(intro)), "placementCount": len(course.placement(cid))}


def intro_video(course, cache, level, level_index):
    title = "Level %d: %s" % (level_index, level["title"])
    lessons = level["lessons"]
    scenes = []
    facts = "Level %d of 12 in a guitar course from zero to hero: %s (%s). Lessons: %s." % (
        level_index, level["title"], level["subtitle"], "; ".join("%s: %s" % (l["title"], l["summary"]) for l in lessons))
    line, _ = narrate(cache, title, "Opening title card of the level.", facts,
                      "1 or 2 exciting sentences introducing this level.", 35, "%s. %s." % (title, level["subtitle"]))
    scenes.append({"type": "title", "title": title, "subtitle": level["subtitle"], "lines": sentences(line)})

    line, pts = narrate(cache, title, "Overview scene listing the lessons in this level.", facts,
                        "2 or 3 sentences describing what the learner will be able to do after this level.", 60,
                        "In this level: %s." % _join([l["title"] for l in lessons]), points=[l["title"] for l in lessons][:6])
    scenes.append({"type": "points", "heading": "In this level", "points": pts, "lines": sentences(line)})

    chords = []
    for l in lessons:
        for s in l["steps"]:
            cid = s.get("chord") if s["type"] in ("chord", "info") else None
            if cid and cid not in chords:
                chords.append(cid)
    if chords:
        chords = chords[:6]
        facts_c = "Chords introduced in this level: %s." % _join(course.chords[c]["name"] for c in chords)
        line, _ = narrate(cache, title, "Preview of the chords in this level, each one strummed.", facts_c,
                          "1 sentence introducing these chords.", 25, "Here are the chords you'll learn.")
        scenes.append({"type": "chordgrid", "chords": chords, "lines": sentences(line)})

    songs = [course.songs[s["song"]] for l in lessons for s in l["steps"] if s["type"] == "song"]
    if songs:
        facts_s = "Songs in this level: %s." % "; ".join("%s (%s)" % (s["title"], s["credit"]) for s in songs)
        line, _ = narrate(cache, title, "Scene listing the songs in this level.", facts_s, "1 sentence about the songs.", 25,
                          "You'll play %s." % _join([s["title"] for s in songs]), points=[s["title"] for s in songs])
        scenes.append({"type": "points", "heading": "Songs you'll play", "points": [s["title"] for s in songs],
                       "lines": sentences(line)})

    line, _ = narrate(cache, title, "Closing card.", facts, "1 short sentence inviting the learner to start the first lesson, "
                      "'%s'." % lessons[0]["title"], 20, "Let's start with %s." % lessons[0]["title"])
    scenes.append({"type": "recap", "points": [], "lines": sentences(line)})
    return {"id": "intro-" + level["id"], "kind": "intro", "title": title, "subtitle": level["subtitle"],
            "levelId": level["id"], "levelIndex": level_index, "levelTitle": level["title"], "scenes": scenes}


def plans(course, cache, only):
    for i, level in enumerate(course.curriculum["levels"], 1):
        if not only or "intro-" + level["id"] in only:
            yield lambda level=level, i=i: intro_video(course, cache, level, i)
        for lesson in level["lessons"]:
            if not only or "lesson-" + lesson["id"] in only:
                yield lambda level=level, i=i, lesson=lesson: lesson_video(course, cache, level, i, lesson)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", action="append", default=[])
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    course = Course()
    cache = qwen.Cache(CACHE_PATH, args.force)
    jobs = list(plans(course, cache, set(args.only)))
    start = time.time()
    for n, job in enumerate(jobs, 1):
        video = job()
        with open(os.path.join(OUT, video["id"] + ".json"), "w") as f:
            json.dump(video, f, indent=1, ensure_ascii=False)
        sys.stderr.write("\r%d/%d videos  %ds  %s" % (n, len(jobs), time.time() - start, json.dumps(STATS)))
    sys.stderr.write("\n")


if __name__ == "__main__":
    main()
