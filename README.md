# Fretwise

Learn guitar from zero to hero with an app that listens to you play. Flutter, Android + iOS.

Fretwise follows the same idea as SimplyGuitar (guided lessons with video, real-time listening),
built from scratch: none of its code, lessons, videos or licensed songs are used. Songs are
public domain.

## What's in it

- **12 levels, 48 lessons:** first notes, open chords, changes, rhythm, songs, 7ths and colour
  chords, power chords, barre chords, fingerpicking, pentatonic lead, and the 12-bar blues.
- **60 narrated videos:** a teaching video opens every lesson, and every level has an intro.
  Animated chord diagrams and tab, fingers placed as they're named, strumming patterns,
  melodies, songs, and subtitles.
- **Six-line tab everywhere:** chords, melodies and whole songs show as tablature. *Me › Chord
  display* switches between tab, box diagram, or both.
- **Listens through the mic:** detects single notes (YIN pitch), chords (matched against the
  exact voicing taught, string by string), and strum timing (pick-attack onsets).
- **Hear everything:** chords, notes and songs are synthesized on the device (Karplus-Strong
  plucked strings).
- **Songs:** wait mode (pauses until you play the right chord) and play-along with a metronome
  at adjustable tempo. Shown as a chart or as tab.
- **Also:** a tuner, a chord library with a "check my chord" mode, stars, XP and streaks,
  left-handed diagrams, and mic sensitivity.

## Run it

You need the platform SDKs:

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

`flutter test` runs the test suite (DSP, practice logic, content validation, tab, video and
widget flows).

## Generated content and the local Qwen model

Everything generated is checked in, so the app builds without any of this. To regenerate:

```sh
tools/build_content.sh    # needs Ollama running manzi-14b, ffmpeg, dart; each stage is cached
```

| Stage | Tool | Qwen (manzi-14b) writes | Guarded by |
|---|---|---|---|
| Lesson text | `tools/qwen_content.py` | Screen text from short briefs in `content/curriculum.src.json` | Human review; wrong ones replaced by a hand-written `body` |
| Video scripts | `tools/video_script.py` | Narration and on-screen key points for every scene of 60 videos | A numeric check (every string, fret and finger number must appear in the facts), then a Qwen fact-check pass; retries with feedback, then reviewed text as fallback |
| Videos | `tools/video_render.py` | — | Renders frames (Pillow), voice (macOS `say`), guitar (the app's synth via `tools/render_audio.dart`), and encodes with ffmpeg |

Hand-written and never generated: chord shapes (`assets/data/chords.json`), chord tips, the
finger placement each video reads out, notes, strum patterns and songs.

## Serving videos from a server

The videos ship inside the app by default (about 1 MB per minute). To stream them instead,
upload `assets/videos/*.mp4` to any static host or CDN, then build with:

```sh
flutter build appbundle --dart-define=VIDEO_BASE_URL=https://your.host/videos
```

To keep the app download small when streaming, remove the `.mp4` files from `assets/videos/`
before building, and keep `index.json` and the `.jpg` posters.

## Release builds

- **Android:** create an upload key, then `android/key.properties` (it's gitignored):
  ```sh
  keytool -genkey -v -keystore ~/fretwise-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
  ```
  ```properties
  storePassword=…
  keyPassword=…
  keyAlias=upload
  storeFile=/Users/you/fretwise-upload.jks
  ```
  Then run `flutter build appbundle` and upload `build/app/outputs/bundle/release/app-release.aab`
  to Play Console.
- **iOS:** set your team in Xcode (Runner › Signing & Capabilities), then `flutter build ipa`
  and upload with Transporter or Xcode.
- **Version:** bump `version:` in `pubspec.yaml` (currently `1.1.0+2`).
- **Branding:** the app icons, splash and logo mark (`assets/brand/`) come from the brand assets. Replace those files to rebrand.
- **Privacy policy:** both stores require one for microphone apps. Host [PRIVACY.md](PRIVACY.md)
  (a GitHub link works) and paste the URL into the store listing.

**Licensing:** the narration uses macOS system voices. Apple licenses those for personal,
non-commercial use. Before publishing the app publicly, re-render the videos with a voice you
have rights to (`tools/video_render.py --voice …` takes any installed voice; swapping in an
open-source TTS engine only touches the `tts()` function).

## Code map

| Path | What |
|---|---|
| `lib/audio/analysis.dart` | FFT, YIN pitch, spectral peaks, onset detector, `AudioAnalyzer` (samples to frames) |
| `lib/audio/chord_matcher.dart` | Voicing-based chord scoring/verification, note matching |
| `lib/audio/synth.dart` | Plucked-string synth, strums, metronome, WAV encoding |
| `lib/audio/mic_listener.dart` | Shared mic (ref-counted), PCM16 to frames, self-sound suppression |
| `lib/audio/sound_player.dart` | Plays rendered sounds; shares the iOS audio session with recording |
| `lib/practice/trackers.dart` | Note/chord sequences, strum patterns, timing and bar scoring |
| `lib/curriculum/models.dart` | Levels, lessons, step types (including video), songs |
| `lib/video/video_catalog.dart` | Rendered-video index; bundled or streamed sources |
| `lib/ui/widgets/tab_staff.dart` | Six-line tablature for chords, melodies and songs |
| `lib/ui/...` | Learn, lesson runner and steps, video player, songs, chords, tuner, profile |
| `tools/` | Content pipeline (Qwen text and scripts, video renderer) |

## Tuning detection

The thresholds were validated on synthesized guitar audio. Real phones and guitars differ, so
if detection feels strict or loose, these are the knobs:

- `ChordMatcher.verify(minScore, margin)`: how close a chord must be.
- `OnsetDetector(ratio, gate)`: how strong a strum must be.
- `NoteMatcher.matches(centsTolerance)`: how in tune a note must be.
- The in-app *Microphone sensitivity* setting scales the loudness gate.
# guitar
# guitar
