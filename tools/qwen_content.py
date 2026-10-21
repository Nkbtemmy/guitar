#!/usr/bin/env python3
"""Expand curriculum briefs into lesson text with the local Qwen model (manzi-14b via Ollama).

  python3 tools/qwen_content.py            # fill anything missing, reuse the cache
  python3 tools/qwen_content.py --force    # ignore the cache and regenerate everything

Reads   content/curriculum.src.json
Writes  assets/data/curriculum.json
Cache   tools/.qwen_cache.json (keyed by prompt hash, so editing a brief regenerates only that step)

Musical facts (shapes, notes, songs) and chord tips are authored by hand; Qwen only turns briefs
into prose. Review its output: when a body is wrong, replace that step's "brief" with a hand-written
"body" in the source file.
"""
import argparse
import json
import os
import re
import sys
import time

import qwen

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE_PATH = os.path.join(ROOT, "tools", ".qwen_cache.json")

LESSON_SYSTEM = (
    "You write the text for one screen of a guitar course for complete beginners. "
    "Write 2 to 4 short sentences, at most 75 words, in a warm, encouraging, second-person voice. "
    "Plain text only: no markdown, no headings, no bullet points, no emojis. "
    "Use only the facts in the brief. Never add chord shapes, fret numbers, string numbers or song names "
    "that are not in the brief. Keep every string number, fret number and finger number exactly as given."
)

SCHEMA = {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}


def load(path):
    with open(path) as f:
        return json.load(f)


def save(path, data):
    """Indented JSON with innermost arrays kept on one line, e.g. "notes": [[6, 0], [5, 0]]."""
    text = json.dumps(data, indent=2, ensure_ascii=False)
    leaf = re.compile(r"\[\s*([^\[\]{}]*?)\s*\]", re.S)
    text = leaf.sub(lambda m: "[" + re.sub(r",\s+", ", ", m.group(1)) + "]", text)
    text = re.sub(r"\[\s*((?:\[[^\[\]]*\],?\s*)+)\]",
                  lambda m: "[" + re.sub(r"\],\s+", "], ", m.group(1).strip()) + "]", text)
    with open(path, "w") as f:
        f.write(text + "\n")


def ask(cache, system, user, max_words):
    key = qwen.Cache.key(system, user)
    if cache.get(key) is None:
        for _ in range(3):
            try:
                text = " ".join(qwen.chat_json(system, user, SCHEMA, max_tokens=400)["text"].split())
            except (ValueError, KeyError):
                continue
            if text and len(text.split()) <= max_words and "#" not in text and "*" not in text:
                cache.put(key, text)
                break
        else:
            raise RuntimeError(f"Qwen gave no usable answer for: {user[:80]}")
    return cache.get(key)


def build_curriculum(cache):
    src = load(os.path.join(ROOT, "content", "curriculum.src.json"))
    jobs = [(level, lesson, step) for level in src["levels"] for lesson in level["lessons"]
            for step in lesson["steps"] if "brief" in step]
    start = time.time()
    for n, (level, lesson, step) in enumerate(jobs, 1):
        prompt = (f"Course level: {level['title']} ({level['subtitle']}). Lesson: {lesson['title']}. "
                  f"Screen title: {step.get('title', '')}.\nBrief: {step['brief']}")
        step["body"] = ask(cache, LESSON_SYSTEM, prompt, 90)
        del step["brief"]
        sys.stderr.write(f"\rcurriculum {n}/{len(jobs)}  {time.time() - start:.0f}s")
    sys.stderr.write("\n")
    src.pop("_doc", None)
    save(os.path.join(ROOT, "assets", "data", "curriculum.json"), src)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    build_curriculum(qwen.Cache(CACHE_PATH, args.force))


if __name__ == "__main__":
    main()
