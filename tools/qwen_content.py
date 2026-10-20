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
import hashlib
import json
import os
import re
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = os.environ.get("OLLAMA_URL", "http://localhost:11434") + "/api/chat"
MODEL = os.environ.get("QWEN_MODEL", "manzi-14b")
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


def ask(system, user, max_words):
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        "stream": False,
        "think": False,
        "format": SCHEMA,
        "options": {"temperature": 0.3, "num_ctx": 4096, "num_predict": 400},
    }).encode()
    req = urllib.request.Request(API, body, {"Content-Type": "application/json"})
    for attempt in range(3):
        with urllib.request.urlopen(req, timeout=600) as r:
            content = json.loads(r.read())["message"]["content"]
        try:
            text = " ".join(json.loads(content)["text"].split())
        except (ValueError, KeyError):
            continue
        if text and len(text.split()) <= max_words and "#" not in text and "*" not in text:
            return text
    raise RuntimeError(f"Qwen gave no usable answer for: {user[:80]}")


class Cache:
    def __init__(self, force):
        self.force = force
        self.data = {} if force or not os.path.exists(CACHE_PATH) else load(CACHE_PATH)

    def get(self, system, user, max_words):
        key = hashlib.sha1(f"{MODEL}\n{system}\n{user}".encode()).hexdigest()
        if key not in self.data:
            self.data[key] = ask(system, user, max_words)
            save(CACHE_PATH, self.data)
        return self.data[key]


def build_curriculum(cache):
    src = load(os.path.join(ROOT, "content", "curriculum.src.json"))
    jobs = [(level, lesson, step) for level in src["levels"] for lesson in level["lessons"]
            for step in lesson["steps"] if "brief" in step]
    start = time.time()
    for n, (level, lesson, step) in enumerate(jobs, 1):
        prompt = (f"Course level: {level['title']} ({level['subtitle']}). Lesson: {lesson['title']}. "
                  f"Screen title: {step.get('title', '')}.\nBrief: {step['brief']}")
        step["body"] = cache.get(LESSON_SYSTEM, prompt, 90)
        del step["brief"]
        sys.stderr.write(f"\rcurriculum {n}/{len(jobs)}  {time.time() - start:.0f}s")
    sys.stderr.write("\n")
    src.pop("_doc", None)
    save(os.path.join(ROOT, "assets", "data", "curriculum.json"), src)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    build_curriculum(Cache(args.force))


if __name__ == "__main__":
    main()
