# Fretwise

Learn guitar from zero to hero with an app that listens to you play. Flutter, Android + iOS.

Fretwise follows the same idea as SimplyGuitar (guided lessons with real-time listening), built
from scratch: none of its code, lessons or licensed songs are used. Songs are public domain.

## What's in it

- **12 levels, 48 lessons:** first notes, open chords, changes, rhythm, songs, 7ths and colour chords,
  power chords, barre chords, fingerpicking, pentatonic lead, and the 12-bar blues.
- **Listens through the mic:** detects single notes (YIN pitch), chords (matched against the exact
  voicing taught, string by string), and strum timing (pick-attack onsets).
- **Hear everything:** chords, single notes and whole songs are synthesized on the device
  (Karplus-Strong plucked strings), so there are no audio assets.
- **Songs:** wait mode (pauses until you play the right chord) and play-along with a metronome
  at adjustable tempo.
- **Also:** a tuner, a chord library with a "check my chord" mode, stars, XP and streaks,
  left-handed diagrams, and mic sensitivity.

## Run it

You need the platform SDKs, which this machine doesn't have yet:

```sh
# iOS: install Xcode from the App Store, then
sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -runFirstLaunch
brew install cocoapods

# Android: install Android Studio (it installs the SDK and an emulator), then
flutter doctor --android-licenses

flutter doctor          # check everything is green
flutter run             # pick a connected phone or simulator
```

Listening needs a real phone. Simulators have poor or no microphone input.

`flutter test` runs the 32 tests (DSP, practice logic, content validation, widget flows).
`flutter build web` gives a UI preview in a browser, without reliable mic or audio.

## Lesson content and the local Qwen model

- `assets/data/chords.json`: chord shapes (hand-written).
- `assets/data/chord_tips.json`: chord tips (hand-written).
- `content/curriculum.src.json`: levels, lessons, steps and songs. Steps with a `brief` get
  their text from Qwen.
- `assets/data/curriculum.json`: generated. Don't edit it by hand.

To change lesson text, edit the briefs and run:

```sh
python3 tools/qwen_content.py          # uses manzi-14b via Ollama; cached, so only changed briefs rerun
flutter test test/content_test.dart    # checks every chord/song reference, note, pattern and body
```

Review what Qwen writes. It got about 9 of 51 texts wrong (for example "leave string 6 open"
for C, where it should be "don't play string 6"). Fix those by replacing that step's `brief`
with a hand-written `body` in the source file.

## Code map

| Path | What |
|---|---|
| `lib/audio/analysis.dart` | FFT, YIN pitch, spectral peaks, onset detector, `AudioAnalyzer` (samples to frames) |
| `lib/audio/chord_matcher.dart` | Voicing-based chord scoring/verification, note matching |
| `lib/audio/synth.dart` | Plucked-string synth, strums, metronome, WAV encoding |
| `lib/audio/mic_listener.dart` | Shared mic (ref-counted), PCM16 to frames, self-sound suppression |
| `lib/audio/sound_player.dart` | Plays rendered sounds; shares the iOS audio session with recording |
| `lib/practice/trackers.dart` | Note/chord sequences, strum patterns, timing and bar scoring |
| `lib/curriculum/models.dart` | Levels, lessons, step types, songs |
| `lib/ui/...` | Learn, lesson runner and steps, songs, chords, tuner, profile |

## Tuning detection

The thresholds were validated on synthesized guitar audio. Real phones and guitars differ, so
if detection feels strict or loose, these are the knobs:

- `ChordMatcher.verify(minScore, margin)`: how close a chord must be.
- `OnsetDetector(ratio, gate)`: how strong a strum must be.
- `NoteMatcher.matches(centsTolerance)`: how in tune a note must be.
- The in-app *Microphone sensitivity* setting scales the loudness gate.
# guitar
