#!/usr/bin/env bash
# Build release Android packages and copy them to build/release/ under the app's name, e.g.
#   guitaro-1.1.0-arm64-v8a.apk   guitaro-1.1.0.aab
#
#   tools/build_android.sh            # one APK per CPU type (install the arm64-v8a one)
#   tools/build_android.sh --bundle   # also the .aab for Google Play
# Extra flags after --bundle are passed to flutter build (e.g. --dart-define=...).
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=guitaro
VERSION=$(sed -n 's/^version: *\([^+]*\).*/\1/p' pubspec.yaml)
OUT=build/release
BUNDLE=false
if [ "${1:-}" = "--bundle" ]; then BUNDLE=true; shift; fi

mkdir -p "$OUT"
flutter build apk --release --split-per-abi "$@"
for abi in arm64-v8a armeabi-v7a x86_64; do
  cp "build/app/outputs/flutter-apk/app-$abi-release.apk" "$OUT/$NAME-$VERSION-$abi.apk"
done

if $BUNDLE; then
  flutter build appbundle --release "$@"
  cp build/app/outputs/bundle/release/app-release.aab "$OUT/$NAME-$VERSION.aab"
fi

echo
ls -lh "$OUT"/$NAME-"$VERSION"*
