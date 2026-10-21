#!/usr/bin/env python3
"""Render lesson videos from content/videos/*.json (written by tools/video_script.py).

  tools/.venv/bin/python tools/video_render.py                 # everything that changed
  tools/.venv/bin/python tools/video_render.py --only lesson-L03-2 --force
  tools/.venv/bin/python tools/video_render.py --jobs 6 --voice Samantha

Writes assets/videos/<id>.mp4, <id>.jpg (poster) and index.json.
Needs ffmpeg, dart and macOS `say`. Python deps: Pillow, numpy (tools/.venv).

Narration comes from macOS text-to-speech. Apple licenses its system voices for personal,
non-commercial use; for a public release, re-render with a voice you have rights to.
"""
import argparse
import hashlib
import json
import math
import os
import re
import subprocess
import sys
import time
import wave
from concurrent.futures import ProcessPoolExecutor
from functools import lru_cache

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "content", "videos")
OUT = os.path.join(ROOT, "assets", "videos")
WORK = os.path.join(ROOT, "tools", ".video_cache")
DATA = os.path.join(ROOT, "assets", "data")
RENDERER_VERSION = "2"

W, H, S, FPS, SR = 1280, 720, 2, 24, 44100
# Brand palette, kept in step with lib/ui/theme.dart: chocolate on white.
BG, SURFACE, SURFACE_HIGH = (255, 255, 255), (245, 239, 232), (234, 223, 211)
ACCENT, SUCCESS, MISS, MUTED = (74, 37, 17), (46, 158, 91), (200, 67, 63), (124, 107, 95)
TEXT, TEXT_SOFT, ON_ACCENT = (31, 27, 24), (61, 51, 44), (255, 255, 255)
LINE, BOARD, FRET, STRING = (150, 136, 124), (235, 220, 201), (180, 160, 140), (140, 120, 104)
LOGO = os.path.join(ROOT, "assets", "brand", "3.0x", "logo_mark.png")
FONT = "/System/Library/Fonts/Avenir Next.ttc"
WEIGHTS = {"bold": 0, "demi": 2, "medium": 5, "regular": 7, "heavy": 8}
TUNING = {6: 40, 5: 45, 4: 50, 3: 55, 2: 59, 1: 64}
LETTERS = {6: "E", 5: "A", 4: "D", 3: "G", 2: "B", 1: "e"}
NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

CHORDS = {c["id"]: c for c in json.load(open(os.path.join(DATA, "chords.json")))["chords"]}
CURRICULUM = json.load(open(os.path.join(DATA, "curriculum.json")))
SONGS = {s["id"]: s for s in CURRICULUM["songs"]}


def symbol(cid):
    return CHORDS[cid].get("symbol", cid)


def chord_midi(cid):
    return [TUNING[6 - i] + f for i, f in enumerate(CHORDS[cid]["frets"]) if f >= 0]


# ------------------------------------------------------------------------------------ speech

QUALITY = [("maj7", "major seven"), ("m7", "minor seven"), ("sus2", "sus two"), ("sus4", "sus four"),
           ("add9", "add nine"), ("m", "minor"), ("7", "seven"), ("5", "five")]


def spoken(text):
    """Text for the speech engine: chord symbols become words ('F#m' -> 'F sharp minor')."""
    def chord_word(m):
        root, acc, qual = m.group(1), m.group(2) or "", m.group(3) or ""
        words = [root] + (["sharp"] if acc == "#" else ["flat"] if acc == "b" else [])
        words += [w for q, w in QUALITY if q == qual]
        return " ".join(words)
    text = re.sub(r"(?<![A-Za-z])([A-G])(#|b)?(maj7|m7|sus2|sus4|add9|m|7|5)?(?![A-Za-z0-9#])",
                  lambda m: chord_word(m) if (m.group(2) or m.group(3)) else m.group(0), text)
    return text.replace("BPM", "beats per minute").replace("3/4", "three four").replace("—", ", ")


def tts(text, voice, rate):
    os.makedirs(os.path.join(WORK, "tts"), exist_ok=True)
    path = os.path.join(WORK, "tts", hashlib.sha1(("%s|%d|%s" % (voice, rate, text)).encode()).hexdigest() + ".wav")
    if not os.path.exists(path):
        subprocess.run(["say", "-v", voice, "-r", str(rate), "-o", path, "--file-format=WAVE",
                        "--data-format=LEI16@%d" % SR, spoken(text)], check=True)
    with wave.open(path) as w:
        return path, w.getnframes() / w.getframerate()


def read_wav(path):
    with wave.open(path) as w:
        data = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
        return data if w.getnchannels() == 1 else data.reshape(-1, w.getnchannels()).mean(axis=1)


# ------------------------------------------------------------------------------------ drawing

@lru_cache(maxsize=None)
def font(weight, size):
    return ImageFont.truetype(FONT, int(size * S), index=WEIGHTS[weight])


class Canvas:
    """Draws in 1x coordinates on a 2x image (downscaled later for smooth edges)."""

    def __init__(self, base):
        self.img = base.copy()
        self.d = ImageDraw.Draw(self.img, "RGBA")

    def rect(self, x, y, w, h, fill=None, r=0, outline=None, width=0):
        box = [x * S, y * S, (x + w) * S, (y + h) * S]
        self.d.rounded_rectangle(box, radius=r * S, fill=fill, outline=outline, width=int(width * S))

    def circle(self, cx, cy, r, fill=None, outline=None, width=0):
        self.d.ellipse([(cx - r) * S, (cy - r) * S, (cx + r) * S, (cy + r) * S], fill=fill, outline=outline, width=int(width * S))

    def line(self, x1, y1, x2, y2, fill, width):
        self.d.line([x1 * S, y1 * S, x2 * S, y2 * S], fill=fill, width=max(1, int(width * S)))

    def text(self, x, y, s, f, fill, anchor="la"):
        self.d.text((x * S, y * S), s, font=f, fill=fill, anchor=anchor)

    def measure(self, s, f):
        return self.d.textlength(s, font=f) / S

    def wrap(self, s, f, width):
        lines, cur = [], ""
        for word in s.split():
            trial = (cur + " " + word).strip()
            if self.measure(trial, f) <= width or not cur:
                cur = trial
            else:
                lines.append(cur)
                cur = word
        return lines + ([cur] if cur else [])

    def paragraph(self, x, y, s, f, fill, width, leading=1.25, anchor="la", max_lines=None):
        lines = self.wrap(s, f, width)[:max_lines]
        size = f.size / S
        for i, ln in enumerate(lines):
            self.text(x, y + i * size * leading, ln, f, fill, anchor)
        return len(lines) * size * leading

    def done(self):
        return self.img.resize((W, H), Image.LANCZOS)


@lru_cache(maxsize=1)
def background():
    yy, xx = np.mgrid[0:H * S, 0:W * S].astype(np.float32)
    glow = np.exp(-(((xx - W * S * 0.85) / (W * S * 0.55)) ** 2 + ((yy + H * S * 0.1) / (H * S * 0.7)) ** 2))
    img = np.empty((H * S, W * S, 3), np.float32)
    for c in range(3):
        img[..., c] = BG[c] + (ACCENT[c] - BG[c]) * 0.035 * glow
    return Image.fromarray(img.clip(0, 255).astype(np.uint8))


def base_fret(frets):
    fretted = [f for f in frets if f > 0]
    if not fretted or max(fretted) <= 4:
        return 1
    return min(fretted)


def placement_elements(cid):
    """Diagram elements in the same order video_script.py reads the placement out."""
    c = CHORDS[cid]
    barre = c.get("barre")
    out = []
    if barre:
        out.append(("barre", barre))
    fingers = sorted((finger, 6 - i, fret) for i, (fret, finger) in enumerate(zip(c["frets"], c["fingers"]))
                     if fret > 0 and not (barre and finger == 1 and fret == barre["fret"]))
    out += [("finger", f) for f in fingers]
    if any(f < 0 for f in c["frets"]):
        out.append(("muted", None))
    return out


def placement_labels(cid):
    """Short on-screen labels, one per placement element (the narrator says the long form)."""
    out = []
    for kind, data in placement_elements(cid):
        if kind == "barre":
            out.append("Barre: fret %d, strings %d to %d" % (data["fret"], data["from"], data["to"]))
        elif kind == "finger":
            out.append("Finger %d: string %d, fret %d" % data)
        else:
            muted = [6 - i for i, f in enumerate(CHORDS[cid]["frets"]) if f < 0]
            out.append("Don't play string%s %s" % ("s" if len(muted) > 1 else "", ", ".join(map(str, muted))))
    return out


def draw_chord(cv, cid, x, y, w, shown=None, glow=None, name=True):
    """Box diagram. [shown] = how many placement elements are visible (None = all);
    [glow] = 'all' or a string number to highlight as it sounds."""
    c = CHORDS[cid]
    if name:
        cv.text(x + w / 2, y, symbol(cid), font("heavy", w * 0.17), TEXT, "ma")
        y += w * 0.25
    h = w * 1.2
    frets = c["frets"]
    base = base_fret(frets)
    top, left, right = y + h * 0.14, x + w * 0.17, x + w * 0.94
    grid_w, grid_h = right - left, h * 0.82
    dx, dy = grid_w / 5, grid_h / 4
    sx = lambda i: left + i * dx
    for i in range(6):
        string = 6 - i
        lit = glow == "all" or glow == string
        cv.line(sx(i), top, sx(i), top + grid_h, ACCENT if lit and frets[i] >= 0 else LINE, w * (0.022 if lit else 0.012))
    for f in range(5):
        cv.line(left, top + f * dy, right, top + f * dy, LINE, w * 0.012)
    if base == 1:
        cv.rect(left - 1, top - h * 0.03, grid_w + 2, h * 0.03, fill=TEXT)
    else:
        cv.text(left - w * 0.1, top + dy / 2, "%dfr" % base, font("demi", w * 0.09), MUTED, "mm")
    elements = placement_elements(cid)
    visible = elements if shown is None else elements[:shown]
    r = dx * 0.38
    for kind, data in visible:
        if kind == "barre":
            a, b = sx(6 - data["from"]), sx(6 - data["to"])
            cy = top + (data["fret"] - base + 0.5) * dy
            cv.rect(min(a, b) - r, cy - r, abs(b - a) + 2 * r, 2 * r, fill=ACCENT, r=r)
            cv.text((a + b) / 2, cy, "1", font("heavy", r * 1.2), ON_ACCENT, "mm")
        elif kind == "finger":
            finger, string, fret = data
            cx, cy = sx(6 - string), top + (fret - base + 0.5) * dy
            cv.circle(cx, cy, r, fill=ACCENT)
            cv.text(cx, cy, str(finger), font("heavy", r * 1.2), ON_ACCENT, "mm")
    show_muted = shown is None or any(k == "muted" for k, _ in visible)
    for i, f in enumerate(frets):
        if f == 0:
            cv.circle(sx(i), top - h * 0.075, dx * 0.2, outline=SUCCESS, width=w * 0.014)
        elif f < 0 and show_muted:
            cv.text(sx(i), top - h * 0.075, "×", font("heavy", w * 0.12), MISS, "mm")
    return h + (w * 0.25 if name else 0)


def draw_tab(cv, columns, x, y, col_w, gap, size, current=-1, done=False):
    """Six-line tab. columns: list of (frets {string: fret}, muted set, label)."""
    labels = any(c[2] for c in columns)
    top = y + (gap * 1.6 if labels else gap * 0.6)
    gutter = 30
    right = x + gutter + len(columns) * col_w
    yy = lambda s: top + (s - 1) * gap
    if 0 <= current < len(columns):
        cx = x + gutter + (current + 0.5) * col_w
        cv.rect(cx - col_w * 0.43, top - gap * 0.6, col_w * 0.86, gap * 6.2, fill=ACCENT + (46,), r=10)
    for s in range(1, 7):
        cv.line(x + gutter - 4, yy(s), right, yy(s), LINE, 1.4)
        cv.text(x + gutter / 2 - 2, yy(s), LETTERS[s], font("bold", size * 0.75), MUTED, "mm")
    cv.line(x + gutter - 4, yy(1), x + gutter - 4, yy(6), LINE, 3)
    cv.line(right, yy(1), right, yy(6), LINE, 3)
    for ci, (frets, muted, label) in enumerate(columns):
        cx = x + gutter + (ci + 0.5) * col_w
        color = ACCENT if ci == current else (SUCCESS if done and 0 <= current and ci < current else TEXT)
        if label:
            cv.text(cx, y + gap * 0.55, label, font("heavy", size * 0.95), ACCENT if ci == current else MUTED, "mm")
        for s in range(1, 7):
            t = str(frets[s]) if s in frets else ("x" if s in muted else None)
            if t is None:
                continue
            tw = size * (1.3 if len(t) > 1 else 0.9)
            cv.rect(cx - tw / 2, yy(s) - gap * 0.4, tw, gap * 0.8, fill=BG)
            cv.text(cx, yy(s), t, font("heavy", size * (0.85 if t == "x" else 1)), MISS if t == "x" else color, "mm")
    return top + gap * 5.8 - y


def chord_column(cid, label=True):
    frets = CHORDS[cid]["frets"]
    return ({6 - i: f for i, f in enumerate(frets) if f >= 0}, {6 - i for i, f in enumerate(frets) if f < 0},
            symbol(cid) if label else None)


def draw_fretboard(cv, notes, current, x, y, w, h):
    frets = [f for _, f in notes]
    first = 1 if min(frets) <= 1 else min(frets) - 1
    last = max(first + 4, max(frets) + 1)
    open_w = w * 0.08
    board_l, board_w = x + open_w, w - open_w
    fret_w = board_w / (last - first + 1)
    top, gap = y + h * 0.08, h * 0.76 / 5
    sy = lambda s: top + (s - 1) * gap
    fx = lambda f: x + open_w * 0.62 if f == 0 else board_l + (f - first + 0.5) * fret_w
    cv.rect(board_l, top - 10, board_w, gap * 5 + 20, fill=BOARD, r=8)
    for k in range(last - first + 2):
        nut = k == 0 and first == 1
        cv.line(board_l + k * fret_w, top - 10, board_l + k * fret_w, top + gap * 5 + 10, TEXT if nut else FRET, 7 if nut else 2.5)
    for f in range(first, last + 1):
        if f in (3, 5, 7, 9, 12, 15):
            cv.text(fx(f), top + gap * 5 + 30, str(f), font("demi", 20), MUTED, "mm")
    for s in range(1, 7):
        cv.line(board_l, sy(s), board_l + board_w, sy(s), STRING, 1 + (s - 1) * 0.45)
        cv.text(x + open_w * 0.18, sy(s), LETTERS[s], font("bold", 18), MUTED, "mm")
    r = min(gap * 0.42, fret_w * 0.3)
    for i, (s, f) in enumerate(notes):
        if i == current:
            continue
        if current < 0 or i > current:
            cv.circle(fx(f), sy(s), r * 0.7, fill=ACCENT + (60,))
    if 0 <= current < len(notes):
        s, f = notes[current]
        cv.circle(fx(f), sy(s), r * 1.45, fill=ACCENT + (60,))
        cv.circle(fx(f), sy(s), r, fill=ACCENT)
        cv.text(fx(f), sy(s), NOTE_NAMES[(TUNING[s] + f) % 12], font("heavy", r), ON_ACCENT, "mm")


def draw_pattern(cv, pattern, active, x, y, w):
    n = len(pattern)
    slot = w / n
    for i, ch in enumerate(pattern):
        on = i == active
        cv.rect(x + i * slot + 4, y, slot - 8, 120, fill=ACCENT if on else SURFACE_HIGH, r=14)
        col = ON_ACCENT if on else (TEXT if ch != "-" else MUTED)
        cx = x + i * slot + slot / 2
        if ch == "D":
            _arrow(cv, cx, y + 50, 1, col)
        elif ch == "U":
            _arrow(cv, cx, y + 50, -1, col)
        else:
            cv.circle(cx, y + 50, 5, fill=col)
        cv.text(cx, y + 100, str(i // 2 + 1) if i % 2 == 0 else "&", font("bold", 22), ON_ACCENT if on else MUTED, "mm")


def _arrow(cv, cx, cy, direction, color):
    cv.line(cx, cy - 22 * direction, cx, cy + 18 * direction, color, 6)
    tip = cy + 26 * direction
    cv.d.polygon([(cx * S, tip * S), ((cx - 14) * S, (tip - 16 * direction) * S), ((cx + 14) * S, (tip - 16 * direction) * S)], fill=color)


@lru_cache(maxsize=8)
def logo(height):
    """The brand logo mark at [height] px (on the 2x canvas)."""
    img = Image.open(LOGO).convert("RGBA")
    return img.resize((round(img.width * height / img.height), height), Image.LANCZOS)


def draw_logo(cv, cx, cy, height):
    mark = logo(int(height * S))
    cv.img.paste(mark, (int(cx * S - mark.width / 2), int(cy * S - mark.height / 2)), mark)


def _right_arrow(cv, cx, cy, color):
    cv.line(cx - 22, cy, cx + 10, cy, color, 6)
    cv.d.polygon([((cx + 24) * S, cy * S), ((cx + 6) * S, (cy - 14) * S), ((cx + 6) * S, (cy + 14) * S)], fill=color)


def _check(cv, cx, cy, size, color):
    cv.line(cx - size, cy, cx - size * 0.25, cy + size * 0.75, color, size * 0.4)
    cv.line(cx - size * 0.25, cy + size * 0.75, cx + size, cy - size * 0.75, color, size * 0.4)


def draw_gauge(cv, cx, cy, radius, cents, color):
    for a in np.linspace(-0.35, 0.35, 120):
        ang = -math.pi / 2 + a * math.pi
        p = (cx + math.cos(ang) * radius, cy + math.sin(ang) * radius)
        cv.circle(p[0], p[1], 5, fill=SUCCESS + (150,) if abs(a) < 0.042 else SURFACE_HIGH)
    ang = -math.pi / 2 + cents / 50 * 0.35 * math.pi
    cv.line(cx, cy, cx + math.cos(ang) * (radius - 14), cy + math.sin(ang) * (radius - 14), color, 6)
    cv.circle(cx, cy, 11, fill=color)


# ------------------------------------------------------------------------------------ scenes

class Scene:
    lead, tail, gap = 0.45, 0.7, 0.32

    def __init__(self, data, video, voice, rate):
        self.data, self.video = data, video
        self.lines = []  # (start, end, text, wav)
        t = self.lead
        for text in data["lines"]:
            wav, dur = tts(text, voice, rate)
            self.lines.append((t, t + dur, text, wav))
            t += dur + self.gap
        self.speech_end = t
        self.events = []  # guitar events relative to scene start
        self.duration = self.plan(t) + self.tail

    def plan(self, t):
        return t

    def say_more(self, text, t, voice, rate):
        wav, dur = tts(text, voice, rate)
        self.lines.append((t, t + dur, text, wav))
        return t + dur + self.gap

    def state(self, t):
        return None

    def subtitle(self, t):
        """The caption at [t]; long lines are paged two caption-lines at a time as they're spoken."""
        for start, end, text, _ in self.lines:
            if start - 0.05 <= t <= end + 0.25:
                pages = subtitle_pages(text)
                k = min(len(pages) - 1, int(max(0.0, t - start) / max(0.1, end - start) * len(pages)))
                return pages[k]
        return None

    def line_index(self, t):
        idx = -1
        for i, (start, _, _, _) in enumerate(self.lines):
            if t >= start:
                idx = i
        return idx

    def draw(self, cv, state):
        pass


class TitleScene(Scene):
    lead, tail = 0.8, 1.0

    def draw(self, cv, state):
        v = self.video
        label = ("LEVEL %d · %s" % (v["levelIndex"], v["levelTitle"].upper())) if v["kind"] == "lesson" else "LEVEL INTRO"
        cv.text(W / 2, 215, label, font("bold", 24), ACCENT, "mm")
        cv.paragraph(W / 2, 250, self.data["title"], font("heavy", 78), TEXT, 1050, 1.1, "ma", 2)
        cv.rect(W / 2 - 60, 420, 120, 8, fill=ACCENT, r=4)
        cv.paragraph(W / 2, 455, self.data["subtitle"], font("medium", 32), MUTED, 950, 1.3, "ma", 2)
        draw_logo(cv, W / 2, 120, 96)


class PointsScene(Scene):
    def state(self, t):
        pts = self.data.get("points", [])
        if not pts:
            return 0
        span = max(0.1, self.speech_end - self.lead)
        return min(len(pts), 1 + int((t - self.lead) / span * len(pts))) if t >= self.lead else 0

    def draw(self, cv, shown):
        cv.paragraph(110, 100, self.data["heading"], font("heavy", 48), TEXT, 700, 1.1, max_lines=2)
        cv.rect(110, 225 if len(cv.wrap(self.data["heading"], font("heavy", 48), 700)) > 1 else 172, 90, 6, fill=ACCENT, r=3)
        y = 270 if len(cv.wrap(self.data["heading"], font("heavy", 48), 700)) > 1 else 215
        for i, p in enumerate(self.data.get("points", [])[:shown]):
            cv.circle(128, y + 21, 10, fill=ACCENT)
            y += cv.paragraph(158, y, p, font("demi", 34), TEXT, 640, 1.2, max_lines=2) + 20
        if self.data.get("chord"):
            draw_chord(cv, self.data["chord"], 900, 150, 230)
        else:
            draw_logo(cv, 1010, 350, 260)


class RecapScene(PointsScene):
    tail = 1.2

    def draw(self, cv, shown):
        pts = self.data.get("points", [])
        if not pts:
            cv.text(W / 2, 270, "Let's play!", font("heavy", 80), TEXT, "mm")
            cv.rect(W / 2 - 60, 330, 120, 8, fill=ACCENT, r=4)
            return
        cv.text(110, 120, "Recap", font("heavy", 50), TEXT)
        y = 220
        for p in pts[:shown]:
            cv.circle(132, y + 22, 18, fill=SUCCESS + (60,))
            _check(cv, 132, y + 22, 10, SUCCESS)
            y += cv.paragraph(170, y, p, font("demi", 36), TEXT, 980, 1.2, max_lines=2) + 26


class ChordScene(Scene):
    def plan(self, t, voice=None, rate=None):
        cid = self.data["chord"]
        self.strum_at = t
        self.events.append({"t": t, "kind": "strum", "notes": chord_midi(cid), "down": True, "gain": 1.2})
        notes = chord_midi(cid)
        played = [6 - i for i, f in enumerate(CHORDS[cid]["frets"]) if f >= 0]
        self.arp = []
        for k, (midi, string) in enumerate(zip(notes, played)):
            at = t + 2.6 + k * 0.42
            self.events.append({"t": at, "kind": "note", "midi": midi})
            self.arp.append((at, string))
        end = t + 2.6 + len(notes) * 0.42 + 0.8
        self.tip_at = end
        return self.say_more("Tip: " + self.data["tip"], end, self.voice, self.rate)

    def __init__(self, data, video, voice, rate):
        self.voice, self.rate = voice, rate
        super().__init__(data, video, voice, rate)

    def state(self, t):
        first, count = self.data["placementFrom"], self.data["placementCount"]
        li = self.line_index(t)
        shown = None if li >= first + count else max(0, li - first + 1)
        glow = None
        if self.strum_at <= t < self.strum_at + 1.6:
            glow = "all"
        for at, string in self.arp:
            if at <= t < at + 0.42:
                glow = string
        return (shown, glow, li if first <= li < first + count else -1, t >= self.tip_at)

    def draw(self, cv, state):
        shown, glow, current, tip = state
        cid = self.data["chord"]
        cv.text(110, 100, CHORDS[cid]["name"], font("heavy", 44), TEXT)
        draw_chord(cv, cid, 120, 170, 260, shown=shown, glow=glow, name=False)
        col = chord_column(cid, label=False)
        if shown is not None:
            visible = {e[1][1] for e in placement_elements(cid)[:shown] if e[0] == "finger"}
            col = ({s: f for s, f in col[0].items() if f == 0 or s in visible or (shown and CHORDS[cid].get("barre"))}, col[1], None)
        draw_tab(cv, [col], 420, 172, 80, 52, 30)
        y = 176
        first = self.data["placementFrom"]
        for i, text in enumerate(placement_labels(cid)):
            if shown is not None and i >= shown:
                break
            on = first + i == current
            cv.rect(580, y - 8, 600, 48, fill=ACCENT + (40,) if on else SURFACE + (200,), r=12)
            cv.text(602, y + 16, text, font("demi", 26), ACCENT if on else TEXT, "lm")
            y += 54
        if tip:
            top = min(y + 6, 470)
            cv.rect(580, top, 600, 112, fill=SURFACE_HIGH, r=16)
            cv.text(602, top + 14, "TIP", font("heavy", 18), ACCENT)
            cv.paragraph(602, top + 40, self.data["tip"], font("medium", 21), TEXT, 560, 1.2, max_lines=3)


class ChangeScene(Scene):
    def plan(self, t):
        self.hits = []
        chords = self.data["chords"]
        for k in range(2 * len(chords)):
            cid = chords[k % len(chords)]
            at = t + k * 1.7
            self.events.append({"t": at, "kind": "strum", "notes": chord_midi(cid), "gain": 1.1})
            self.hits.append((at, k % len(chords)))
        return t + 2 * len(chords) * 1.7 + 0.6

    def state(self, t):
        active = -1
        for at, idx in self.hits:
            if t >= at:
                active = idx
        return active if t < self.hits[-1][0] + 1.7 else -1

    def draw(self, cv, active):
        chords = self.data["chords"]
        cv.text(110, 100, "Change: " + ", ".join(symbol(c) for c in chords), font("heavy", 44), TEXT)
        n = len(chords)
        w = min(220, 900 / n - 40)
        total = n * w + (n - 1) * 80
        x0 = (W - total) / 2
        for i, cid in enumerate(chords):
            x = x0 + i * (w + 80)
            if i == active:
                cv.rect(x - 22, 175, w + 44, w * 1.45 + 60, fill=ACCENT + (30,), outline=ACCENT, width=3, r=20)
            draw_chord(cv, cid, x, 190, w, glow="all" if i == active else None)
            if i < n - 1:
                _right_arrow(cv, x + w + 40, 190 + w * 0.85, MUTED)


class NotesScene(Scene):
    step_s = 0.6

    def plan(self, t):
        self.times = []
        for k, (s, f) in enumerate(self.data["notes"]):
            at = t + k * self.step_s
            self.events.append({"t": at, "kind": "note", "midi": TUNING[s] + f})
            self.times.append(at)
        return t + len(self.times) * self.step_s + 0.9

    def state(self, t):
        cur = -1
        for k, at in enumerate(self.times):
            if t >= at:
                cur = k
        return cur

    def draw(self, cv, cur):
        notes = self.data["notes"]
        cv.text(110, 95, self.data["title"], font("heavy", 44), TEXT)
        draw_fretboard(cv, notes, cur, 110, 165, 1060, 230)
        cols = [({s: f}, set(), None) for s, f in notes]
        draw_tab(cv, cols, 110, 420, min(110, 1000 / len(cols)), 26, 22, current=cur, done=True)


class StrumScene(Scene):
    def plan(self, t):
        d = self.data
        beat = 60.0 / d["bpm"]
        bpb = d["beatsPerBar"]
        self.demo_at, self.beat, self.bars = t, beat, 2
        for b in range(bpb * (self.bars + 1)):
            self.events.append({"t": t + b * beat, "kind": "click", "accent": b % bpb == 0})
        for bar in range(self.bars):
            notes = chord_midi(d["chords"][bar % len(d["chords"])])
            for i, ch in enumerate(d["pattern"]):
                if ch in "DU":
                    at = t + (bpb + bar * bpb + i / 2) * beat
                    self.events.append({"t": at, "kind": "strum", "notes": notes if ch == "D" else notes[len(notes) // 2:],
                                        "down": ch == "D", "gain": 1.0 if ch == "D" else 0.7})
        return t + bpb * (self.bars + 1) * beat + 0.5

    def state(self, t):
        rel = t - self.demo_at
        bpb = self.data["beatsPerBar"]
        if rel < 0 or rel >= self.beat * bpb * (self.bars + 1):
            return (0, -1, 0)
        if rel < self.beat * bpb:
            return (int(rel / self.beat) + 1, -1, 0)
        rel -= self.beat * bpb
        return (0, int(rel / (self.beat / 2)) % (bpb * 2), int(rel / (self.beat * bpb)))

    def draw(self, cv, state):
        count, eighth, bar = state
        d = self.data
        cv.text(110, 95, "Strumming pattern", font("heavy", 44), TEXT)
        cv.text(110, 152, "%d BPM · %d beats per bar" % (d["bpm"], d["beatsPerBar"]), font("medium", 26), MUTED)
        draw_pattern(cv, d["pattern"], eighth, 110, 200, 1060)
        if count:
            cv.text(W / 2, 455, str(count), font("heavy", 120), ACCENT, "mm")
        else:
            cid = d["chords"][bar % len(d["chords"])]
            draw_chord(cv, cid, W / 2 - 70, 340, 140)


class SongScene(Scene):
    def plan(self, t):
        song = SONGS[self.data["song"]]
        lines = song["lines"][:2] if len(song["lines"][0]["bars"]) >= 4 else song["lines"][:4]
        self.song_lines = lines
        bars = [b for l in lines for b in l["bars"]]
        beat = 60.0 / song["bpm"]
        bpb = song["beatsPerBar"]
        self.demo_at, self.bar_s = t, beat * bpb
        for i, cid in enumerate(bars):
            for k, ch in enumerate(song["pattern"]):
                if ch in "DU":
                    notes = chord_midi(cid)
                    self.events.append({"t": t + i * self.bar_s + k / 2 * beat, "kind": "strum",
                                        "notes": notes if ch == "D" else notes[len(notes) // 2:], "down": ch == "D",
                                        "gain": 1.0 if ch == "D" else 0.7})
        self.nbars = len(bars)
        return t + self.nbars * self.bar_s + 0.8

    def state(self, t):
        rel = t - self.demo_at
        return int(rel / self.bar_s) if 0 <= rel < self.nbars * self.bar_s else -1

    def draw(self, cv, cur):
        song = SONGS[self.data["song"]]
        cv.text(110, 95, song["title"], font("heavy", 46), TEXT)
        cv.text(110, 158, "%s · %d BPM" % (song["credit"], song["bpm"]), font("medium", 24), MUTED)
        y, idx = 205, 0
        step = min(140, (585 - 205) / len(self.song_lines))
        for line in self.song_lines:
            n = len(line["bars"])
            bw = 1060 / max(4, n)
            box = min(64, step - 44)
            for k, cid in enumerate(line["bars"]):
                on, done = idx == cur, 0 <= cur and idx < cur
                cv.rect(110 + k * bw, y, bw - 10, box, fill=ACCENT if on else (SUCCESS + (40,) if done else SURFACE_HIGH), r=12)
                cv.text(110 + k * bw + (bw - 10) / 2, y + box / 2, symbol(cid), font("heavy", 30), ON_ACCENT if on else (SUCCESS if done else TEXT), "mm")
                idx += 1
            cv.text(114, y + box + 6, line["lyrics"] or "(instrumental)", font("medium", 24), TEXT_SOFT)
            y += step


class TunerScene(Scene):
    def plan(self, t):
        self.times = []
        for k, s in enumerate([6, 5, 4, 3, 2, 1]):
            at = t + k * 1.25
            self.events.append({"t": at, "kind": "note", "midi": TUNING[s]})
            self.times.append((at, s))
        return t + 6 * 1.25 + 0.6

    def state(self, t):
        cur = None
        for at, s in self.times:
            if t >= at:
                cur = s
        return cur

    def draw(self, cv, cur):
        cv.text(110, 95, "Tuning", font("heavy", 44), TEXT)
        for k, s in enumerate([6, 5, 4, 3, 2, 1]):
            x = W / 2 - 250 + k * 100
            on = s == cur
            done = cur is not None and s > cur
            cv.circle(x, 185, 36, fill=SUCCESS + (50,) if done else SURFACE_HIGH, outline=ACCENT if on else None, width=3)
            if done:
                _check(cv, x, 185, 14, SUCCESS)
            else:
                cv.text(x, 185, LETTERS[s], font("heavy", 30), TEXT, "mm")
        draw_gauge(cv, W / 2, 470, 200, 0 if cur else -18, SUCCESS if cur else MUTED)
        if cur:
            cv.text(W / 2 + 300, 400, NOTE_NAMES[TUNING[cur] % 12], font("heavy", 96), SUCCESS, "mm")
            cv.text(W / 2 + 300, 470, "string %d" % cur, font("demi", 24), MUTED, "mm")


class ChordGridScene(Scene):
    def plan(self, t):
        self.times = []
        for k, cid in enumerate(self.data["chords"]):
            at = t + k * 1.5
            self.events.append({"t": at, "kind": "strum", "notes": chord_midi(cid), "gain": 1.1})
            self.times.append(at)
        return t + len(self.times) * 1.5 + 0.6

    def state(self, t):
        cur = -1
        for k, at in enumerate(self.times):
            if t >= at:
                cur = k
        return cur if t < self.times[-1] + 1.5 else -1

    def draw(self, cv, cur):
        chords = self.data["chords"]
        cv.text(110, 95, "Chords in this level", font("heavy", 44), TEXT)
        n = len(chords)
        w = min(170, 1000 / n - 30)
        x0 = (W - (n * w + (n - 1) * 30)) / 2
        for i, cid in enumerate(chords):
            x = x0 + i * (w + 30)
            if i == cur:
                cv.rect(x - 14, 185, w + 28, w * 1.45 + 40, fill=ACCENT + (30,), outline=ACCENT, width=3, r=16)
            draw_chord(cv, cid, x, 200, w, glow="all" if i == cur else None)


SCENES = {"title": TitleScene, "points": PointsScene, "recap": RecapScene, "chord": ChordScene, "change": ChangeScene,
          "notes": NotesScene, "strum": StrumScene, "song": SongScene, "tuner": TunerScene, "chordgrid": ChordGridScene}


def chrome(cv, video, title_scene):
    if not title_scene:
        draw_logo(cv, 52, 36, 34)
        cv.text(76, 34, "Fretwise", font("heavy", 24), ACCENT, "lm")
        label = "LEVEL %d · %s" % (video["levelIndex"], video["levelTitle"].upper())
        cv.text(W - 40, 36, label if video["kind"] == "intro" else "%s  ·  %s" % (label, video["title"]), font("demi", 18), MUTED, "ra")


@lru_cache(maxsize=4096)
def subtitle_pages(text):
    lines = Canvas(Image.new("RGB", (8, 8))).wrap(text, font("demi", 30), 1040)
    return tuple(" ".join(lines[i:i + 2]) for i in range(0, len(lines), 2)) or ("",)


def draw_subtitle(cv, text):
    if not text:
        return
    f = font("demi", 30)
    lines = cv.wrap(text, f, 1040)[:2]
    h = len(lines) * 40 + 28
    y = 690 - h
    cv.rect(W / 2 - 560, y, 1120, h, fill=ACCENT + (240,), r=16)
    for i, ln in enumerate(lines):
        cv.text(W / 2, y + 14 + i * 40, ln, f, ON_ACCENT, "ma")


# ------------------------------------------------------------------------------------ render

class Frames:
    def __init__(self, video, scenes):
        self.video, self.scenes = video, scenes
        self.cache = {}

    def image(self, idx, t):
        sc = self.scenes[idx]
        state, sub = sc.state(t), sc.subtitle(t)
        key = (idx, json.dumps(state), sub)
        img = self.cache.get(key)
        if img is None:
            if len(self.cache) > 80:
                self.cache.clear()
            cv = Canvas(background())
            chrome(cv, self.video, isinstance(sc, TitleScene))
            sc.draw(cv, state)
            draw_subtitle(cv, sub)
            img = self.cache[key] = cv.done()
        return img


def render_video(vid, voice, rate, force):
    script_path = os.path.join(SCRIPTS, vid + ".json")
    video = json.load(open(script_path))
    digest = hashlib.sha1((open(script_path).read() + RENDERER_VERSION + voice + str(rate)
                           + open(__file__).read()).encode()).hexdigest()
    out_mp4 = os.path.join(OUT, vid + ".mp4")
    stamp = os.path.join(WORK, vid + ".hash")
    if not force and os.path.exists(out_mp4) and os.path.exists(stamp) and open(stamp).read() == digest:
        return vid, json.load(open(os.path.join(WORK, vid + ".meta.json"))), "cached"

    scenes, t = [], 0.0
    for data in video["scenes"]:
        sc = SCENES[data["type"]](data, video, voice, rate)
        sc.start = t
        scenes.append(sc)
        t += sc.duration
    duration = t
    n = int(math.ceil(duration * SR))

    # Audio: narration lines + guitar track rendered by the app's synth.
    mix = np.zeros(n, np.float32)
    events = []
    for sc in scenes:
        for start, _, _, wav in sc.lines:
            data = read_wav(wav)
            a = int((sc.start + start) * SR)
            mix[a:a + len(data)] += data[: max(0, n - a)]
        events += [dict(e, t=e["t"] + sc.start) for e in sc.events]
    ev_path = os.path.join(WORK, vid + ".events.json")
    gtr_path = os.path.join(WORK, vid + ".guitar.wav")
    json.dump({"seconds": duration, "events": events}, open(ev_path, "w"))
    subprocess.run([os.path.join(WORK, "render_audio"), ev_path, gtr_path], check=True)
    gtr = read_wav(gtr_path)[:n]
    mix[: len(gtr)] += 1.4 * gtr
    mix = np.tanh(mix * 1.1) / math.tanh(1.1)
    mix_path = os.path.join(WORK, vid + ".mix.wav")
    with wave.open(mix_path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((mix.clip(-1, 1) * 32767).astype(np.int16).tobytes())

    frames = Frames(video, scenes)
    ff = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "%dx%d" % (W, H),
                           "-r", str(FPS), "-i", "-", "-i", mix_path, "-c:v", "libx264", "-preset", "medium", "-tune", "animation",
                           "-crf", "27", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "64k", "-shortest",
                           "-movflags", "+faststart", out_mp4], stdin=subprocess.PIPE)
    total = int(duration * FPS)
    idx, prev_last = 0, None
    for f in range(total):
        tt = f / FPS
        while idx + 1 < len(scenes) and tt >= scenes[idx + 1].start:
            prev_last = frames.image(idx, scenes[idx].duration - 0.01)
            idx += 1
        rel = tt - scenes[idx].start
        img = frames.image(idx, rel)
        if prev_last is not None and rel < 0.3:
            img = Image.blend(prev_last, img, rel / 0.3)
        frame = img.copy()
        d = ImageDraw.Draw(frame)
        d.rectangle([0, H - 5, int(W * tt / duration), H], fill=ACCENT)
        ff.stdin.write(frame.tobytes())
    ff.stdin.close()
    if ff.wait() != 0:
        raise RuntimeError("ffmpeg failed for " + vid)

    poster = frames.image(0, min(1.2, scenes[0].duration / 2)).resize((640, 360), Image.LANCZOS)
    poster.save(os.path.join(OUT, vid + ".jpg"), quality=82)
    meta = {"id": vid, "kind": video["kind"], "title": video["title"], "subtitle": video["subtitle"],
            "levelId": video["levelId"], "lessonId": video.get("lessonId"), "duration": round(duration, 1),
            "file": vid + ".mp4", "poster": vid + ".jpg"}
    json.dump(meta, open(os.path.join(WORK, vid + ".meta.json"), "w"))
    open(stamp, "w").write(digest)
    return vid, meta, "rendered"


def build_audio_tool():
    exe = os.path.join(WORK, "render_audio")
    src = [os.path.join(ROOT, "tools", "render_audio.dart"), os.path.join(ROOT, "lib", "audio", "synth.dart")]
    if not os.path.exists(exe) or any(os.path.getmtime(s) > os.path.getmtime(exe) for s in src):
        subprocess.run(["dart", "compile", "exe", src[0], "-o", exe], check=True, cwd=ROOT,
                       stdout=subprocess.DEVNULL)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", action="append", default=[])
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) // 2))
    ap.add_argument("--voice", default="Samantha")
    ap.add_argument("--rate", type=int, default=172)
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(WORK, exist_ok=True)
    build_audio_tool()
    ids = sorted(f[:-5] for f in os.listdir(SCRIPTS) if f.endswith(".json"))
    if args.only:
        ids = [i for i in ids if i in args.only]
    start = time.time()
    index_path = os.path.join(OUT, "index.json")
    index = {m["id"]: m for m in json.load(open(index_path))} if os.path.exists(index_path) else {}
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        for n, (vid, meta, how) in enumerate(pool.map(render_video, ids, [args.voice] * len(ids),
                                                     [args.rate] * len(ids), [args.force] * len(ids)), 1):
            index[vid] = meta
            print("%3d/%d %-16s %5.1fs  %s  (%ds)" % (n, len(ids), vid, meta["duration"], how, time.time() - start), flush=True)
    order = {v: i for i, v in enumerate(sorted(index, key=lambda k: (index[k]["levelId"], index[k]["kind"] != "intro", k)))}
    json.dump(sorted(index.values(), key=lambda m: order[m["id"]]), open(index_path, "w"), indent=1)


if __name__ == "__main__":
    main()
