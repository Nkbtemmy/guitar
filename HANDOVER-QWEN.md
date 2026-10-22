# Handover to Qwen (`manzi --big`): web fullscreen fix

Branch: `feature/videos-and-tab` (PR #1). Not committed. Delete this file once the task is done.

## State when handed over

The Playwright pass on the web build found five issues. Four are fixed in the working tree;
`flutter analyze` is clean and `flutter test` passes (40 tests).

| # | Issue | State |
|---|---|---|
| 1 | Level "Intro" chip announced as a checkbox to screen readers | Fixed (`learn_screen.dart`, now an `OutlinedButton` with tooltip), verified in the browser, regression test added |
| 2 | Leaving fullscreen leaves the inline video black and paused (web only) | **Open: this handover** |
| 3 | Tab fret numbers drawn on white patches over beige cards | Fixed (`tab_staff.dart` draws line gaps); needs a visual check |
| 4 | Strum-pattern rest slots shorter than arrow slots | Fixed (`strum_view.dart`); needs a visual check |
| 5 | Selected segmented buttons salmon instead of chocolate | Fixed (`theme.dart`); needs a visual check |

## The task

**Why it breaks:** on web, `video_player` shows each video through one shared `<video>` element
(id `videoElement-<playerId>`). Our fullscreen page puts a second `VideoPlayer` widget on that
element. When the page closes, the element is detached from the page, which makes the browser
pause it, and the inline player is left empty. Re-creating views does not help, because every view
swap detaches the element again.

**Fix:** on web, don't open a second player. Put the existing `<video>` element into the
browser's own fullscreen (with native controls while there). Phones keep the current fullscreen
page, where it works fine.

## Steps (run from the project root)

**0. Setup**
```sh
flutter pub add web
touch lib/ui/video/web_fullscreen.dart lib/ui/video/web_fullscreen_web.dart
```

**1. Stub for phones**
```sh
manzi --big edit lib/ui/video/web_fullscreen.dart "Write this Dart file from scratch. It must contain only: a doc comment saying this is the non-web version used on phones, where the in-app fullscreen page is used instead; and one top-level function: bool enterNativeFullscreen(int playerId) => false;"
```

**2. Web implementation**
```sh
manzi --big edit lib/ui/video/web_fullscreen_web.dart "Write this Dart file from scratch for Flutter web. Imports: dart:js_interop and package:web/web.dart as web. Add a doc comment explaining that on web a second Flutter view of the same <video> element would detach and pause it, so this uses the browser's own fullscreen. Define bool enterNativeFullscreen(int playerId): find the element with web.document.getElementById('videoElement-\$playerId'); if null return false. Cast it to web.HTMLVideoElement. Set video.controls = true. Create a JSFunction handler (a Dart closure taking web.Event, converted with .toJS, stored in a late final variable) that, when web.document.fullscreenElement is null, sets video.controls = false and removes itself with web.document.removeEventListener('fullscreenchange', handler). Register it with web.document.addEventListener('fullscreenchange', handler). Call video.requestFullscreen().toDart and, if that future fails, set controls back to false and remove the listener. Return true."
```

**3. Use it in the player**
```sh
manzi --big edit lib/ui/video/lesson_video_player.dart "Two changes only. (a) Add this conditional import next to the other imports: import 'web_fullscreen.dart' if (dart.library.js_interop) 'web_fullscreen_web.dart'; (b) At the very start of the _fullscreen() method, add: if (enterNativeFullscreen(_controller.playerId)) return; with a one-line comment that on web the browser's own fullscreen is used because a second view of the video element would detach and pause it. Do not change anything else."
```

## Acceptance checks

```sh
flutter analyze            # no issues
flutter test               # 40 tests pass
flutter build web --release
npx --yes http-server build/web -p 8765 -c-1   # supports Range requests; python's http.server does not, and videos won't play
```

Then open http://127.0.0.1:8765 at phone width, tap a level's **Intro**, let it play, tap
**Full screen**: the video goes browser-fullscreen with native controls. Press Esc: the inline
player must still show the video and keep playing (not black, not paused). Also confirm items 3–5
in the table look right: the chord library in Tab mode (Me › Chord display › Tab), any strum
lesson's pattern row, and the Chart/Tab and Wait/Play-along toggles.

Phones are unchanged: `enterNativeFullscreen` returns false there, and the existing fullscreen
page opens as before.
