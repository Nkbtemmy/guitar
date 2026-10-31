# Guitaro

Learn guitar from zero to hero with an app that listens to you play. Flutter, Android + iOS.

Guitaro follows the same idea as SimplyGuitar (guided lessons with video, real-time listening),
built from scratch: none of its code, lessons, videos or licensed songs are used. Songs are
public domain.

## What's in it

- **12 levels, 51 lessons:** first notes, open chords, changes, rhythm, songs, 7ths and colour
  chords, power chords, barre chords, fingerpicking, pentatonic lead, and the 12-bar blues.
- **Strumming technique:** holding the pick, keeping time, down and up strums, the folk pattern,
  3/4, accents on the backbeat, muted strums (chucks), palm muting, sixteenth notes and the
  shuffle. Each exercise is scored on timing and chords, and on accents where they're marked
  (the app compares how loud the marked strums are).
- **60 narrated videos:** a teaching video opens every lesson, and every level has an intro.
  (The three newest strumming lessons get theirs the next time `tools/build_content.sh` runs.)
  Animated chord diagrams and tab, fingers placed as they're named, strumming patterns,
  melodies, songs, and subtitles.
- **Six-line tab everywhere:** chords, melodies and whole songs show as tablature.
  - *Me › Chord display* switches between tab, box diagram, or both.
  - *Me › Chord charts* picks upright (chord book) or sideways charts.
  - *Me › String order*: low E on top with high e at the bottom (the default), or high e on top as tab is usually printed.
- **Chord cards:** each chord's chart, with the shape on a drawn guitar neck below it (seen from
  the front, frets spaced as on a real guitar).
- **Listens through the mic:** detects single notes (YIN pitch), chords (matched against the
  exact voicing taught, string by string), and strum timing (pick-attack onsets).
- **Hear everything:** chords, notes and songs are synthesized on the device (Karplus-Strong
  plucked strings).
- **Songs:** wait mode (pauses until you play the right chord) and play-along with a metronome
  at adjustable tempo. Shown as a chart or as tab.
- **Songbook (chords & tabs):** 41 public-domain songs as chord sheets and tabs (`assets/songs/*.cho`,
  ChordPro). Chords sit over the lyrics and open their diagram when tapped. You get autoscroll,
  transpose, capo with a suggested easier capo, simplified chords, text size, favorites, setlists and
  recently viewed, all saved per song. Any chord name gets a diagram and a sound (library shape,
  or a generated movable barre).
- **Tab player:** any six-line text tab scrolls past a glowing play line as you hear it on the
  synth.
  - Fret numbers sit on tiles, with chord names in bubbles above.
  - Speeds: Learn (waits for each note, listening), Slower, Normal, Faster.
  - While it plays it listens: each note turns green when played right and red when missed.
  - After three misses in a row it goes back about 10 seconds and carries on.
  - *Keep playing when I miss* (also in Me) never goes back, and makes Learn move on after a
    wrong note (marked red) instead of waiting.
  - "Play the tune with me" off plays just clicks, so the mic hears only the learner.
  - Pause, back and forward a bar, and a slider to go anywhere.
  - An A–B practice loop, count-in and metronome.
  - Spacing is rhythm: each dash is a sixteenth note.
- **Play along with a way back:** song play-along shows the same scrolling highway, with strum
  arrows.
  - Back returns to the start of the line; Repeat loops it; tap any bar to start there.
  - Each bar turns green or red as it's judged.
  - After two missed bars in a row, it goes back about 10 seconds, to the start of a line, and
    carries on to the end. It goes back to the same place at most three times, and *Keep playing
    when I miss* turns this off.
- **Opening sound:** the splash screen strums the six open strings (can be turned off under Me).
- **Play along with any sheet:** wait mode (waits for the right chord) or play-along, where Guitaro
  strums the song in time with a count-in while the mic scores each bar (use headphones). It follows
  your transpose, capo and simplify settings, one bar per chord.
- **My songs:** write or paste songs as ChordPro or chords over lyrics (tab included), preview, edit,
  and copy any song out as ChordPro. A song can keep a YouTube link with a "Watch on YouTube" button.
  They stay on the device.
- **Find chords by listening:** play a song out loud (from YouTube on another device, say) and the
  mic writes down its chords (major and minor triads), even when they're picked one string at a time
  or under a melody, and the melody too: as tab in time, with the chords over its bars, at the tempo
  and in the metre it heard. It all becomes a new song to fix up and practise, kept on the device.
- **Find chords from a YouTube link:** paste a link and the video plays inside Guitaro while the
  chords are written down in time with it; tap a chord to jump the video there. On Android 10+ the
  app listens to its own playback (the system asks to allow it each time); on other phones it
  listens through the mic. The melody is written down as tab here too. Nothing is downloaded from
  YouTube.
- **Practice tools** (the Practice row on the Learn tab), with a **Today's practice** plan of
  about 15 minutes laid out the way a teacher would:
  1. tune up;
  2. warm up;
  3. a chord change;
  4. the top weak spot;
  5. any homework;
  6. the next lesson.

  Each part is ticked off once given a real try, practice minutes are counted, and an optional
  daily reminder can be set. The tools:
  - **Practise these:** the song lines and tab bars the learner keeps missing in play-along, most
    needed first. One tap loops the spot.
  - **Homework:** a teacher sets a song or tab, a speed to reach and a due date. It ticks itself
    off after a whole run that fast with 80% right.
  - **Chord changes:** one-minute changes between any two chords, counted by the mic, with
    personal bests and a chart.
  - **Fretboard notes:** name the note at a spot, or play the note named, against the clock.
  - **Ear training:** major or minor, and play back short phrases by ear.
  - **Metronome:** tap tempo, plus a speed trainer that steps up to a goal. Play-along and the tab
    player can also "speed up when I get it right".
  - **Recordings:** record yourself, or a play-along run ("Record me"), then listen back, star,
    rename. Recordings stay on the phone.
  - **Progress report:** a summary to send a teacher or parent from any chat app.
- **Tuner:** a headstock with a peg per string. Auto picks out the string you play; or tap a peg
  to tune that one and hear it.
  - Standard, Drop D, half and whole step down, Open G, Open D or DADGAD.
  - A song can name its tuning (`{tuning: Drop D}`); its tabs then play and are listened for in
    it.
  - A straight cents meter, and a "How to tune?" guide.
- **Also:** a chord library with a "check my chord" mode, stars, XP and streaks, left-handed
  diagrams, mic sensitivity, and the screen kept on while you play.

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
| Videos | `tools/video_render.py` | — | Renders frames (Pillow), voice (Kokoro `am_michael`, a local neural voice), guitar (the app's synth via `tools/render_audio.dart`), and encodes with ffmpeg |

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
  keytool -genkey -v -keystore ~/guitaro-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
  ```
  ```properties
  storePassword=…
  keyPassword=…
  keyAlias=upload
  storeFile=/Users/you/guitaro-upload.jks
  ```
  Then run `tools/build_android.sh --bundle` and upload `build/release/guitaro-<version>.aab`
  to Play Console. Without `--bundle` it just builds the APKs (`build/release/guitaro-<version>-arm64-v8a.apk`
  is the one for most phones).
- **iOS:** set your team in Xcode (Runner › Signing & Capabilities), then `flutter build ipa`
  and upload with Transporter or Xcode.
- **Version:** bump `version:` in `pubspec.yaml` (currently `1.1.0+2`).
- **Branding:** the app icons, splash and logo mark (`assets/brand/`) come from the brand assets. Replace those files to rebrand.
- **Privacy policy:** both stores require one for microphone apps. Host [PRIVACY.md](PRIVACY.md)
  (a GitHub link works) and paste the URL into the store listing.
- **Usage stats (Firebase):** the app counts its users with Google Analytics for Firebase and
  reports crashes with Crashlytics (`lib/analytics.dart`). Nothing personal is sent, and there's
  no sign-in. Learners can turn it off in *Me › Share anonymous usage stats*. A build that isn't
  connected to Firebase just sends nothing. To connect it, once:
  ```sh
  npm install -g firebase-tools && firebase login
  dart pub global activate flutterfire_cli
  flutterfire configure --platforms=android,ios \
      --android-package-name=com.thunderzeye.guitaro --ios-bundle-id=com.thunderzeye.guitaro
  ```
  This writes `lib/firebase_options.dart`, `android/app/google-services.json` and
  `ios/Runner/GoogleService-Info.plist`. They aren't secrets, so commit them. In the Firebase
  console, turn off Google signals and ads personalization.
  - **Where to see the numbers:** in the Firebase console, *Analytics › Dashboard* shows daily,
    weekly and monthly active users, new users, retention, countries and app versions. The
    last 30 minutes appear live; the rest takes up to a day.
  - *Events* counts `lesson_start`, `lesson_complete`, `song_open` and `chords_found`. To split
    them by `lesson_id`, `stars`, `song` or `source`, register those as event-scoped custom
    dimensions under *Custom definitions*.
  - *Crashlytics* shows crash-free users and stack traces.
  - **Test on a phone:** run `adb shell setprop debug.firebase.analytics.app com.thunderzeye.guitaro`
    with a release build, and events show in *DebugView* within a minute. Debug builds send
    nothing.
  - **Store forms:** Play Console *Data safety* answers:
    - Collected: app interactions, crash logs, diagnostics and device or other IDs, for
      analytics.
    - Not shared, encrypted in transit, optional.

    *Advertising ID*: **No**, because the manifest removes it.
  - App Store privacy labels: Usage Data (product interaction), Diagnostics and Identifiers
    (device ID). Mark them not linked to the user and not used for tracking. Firebase's
    [Play](https://firebase.google.com/docs/android/play-data-disclosure) and
    [App Store](https://firebase.google.com/docs/ios/app-store-data-collection) guides list the
    details.

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
| `lib/ui/widgets/tab_highway.dart` | Scrolling tab past a play line, for the tab player and play-along |
| `lib/ui/widgets/neck_view.dart` | A chord drawn on a guitar neck |
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
