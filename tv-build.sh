#!/usr/bin/env bash
# Builds the TV custom FLauncher (armeabi-v7a release, debuggable, signed with the TV key) and
# prints the APK path. Install it with ~/Code/skyworth-tv/tv-install.sh <apk> (never incremental).
#
# Env:
#   FLUTTER                  flutter binary            (default ~/Code/flutter/bin/flutter)
#   FLAUNCHER_KEYSTORE       keystore path             (default ~/Code/skyworth-tv/remote-keys/release.keystore)
#   FLAUNCHER_KEYSTORE_PASSWORD / FLAUNCHER_SIGNING_KEY_PASSWORD   (default shimpass)
#   FLAUNCHER_SIGNING_KEY_ALIAS                                  (default shim)
#   BUILD_NAME / BUILD_NUMBER   version name / code     (default from pubspec.yaml; code must stay > 20)
set -euo pipefail
cd "$(dirname "$0")"

FLUTTER=${FLUTTER:-$HOME/Code/flutter/bin/flutter}
export FLAUNCHER_KEYSTORE=${FLAUNCHER_KEYSTORE:-$HOME/Code/skyworth-tv/remote-keys/release.keystore}
export FLAUNCHER_KEYSTORE_PASSWORD=${FLAUNCHER_KEYSTORE_PASSWORD:-shimpass}
export FLAUNCHER_SIGNING_KEY_PASSWORD=${FLAUNCHER_SIGNING_KEY_PASSWORD:-$FLAUNCHER_KEYSTORE_PASSWORD}
export FLAUNCHER_SIGNING_KEY_ALIAS=${FLAUNCHER_SIGNING_KEY_ALIAS:-shim}
export FLAUNCHER_DEBUGGABLE=${FLAUNCHER_DEBUGGABLE:-true}

VERSION=$(sed -n 's/^version: *//p' pubspec.yaml)
BUILD_NAME=${BUILD_NAME:-${VERSION%%+*}}
BUILD_NUMBER=${BUILD_NUMBER:-${VERSION##*+}}

"$FLUTTER" build apk --release --target-platform android-arm \
    --build-name "$BUILD_NAME" --build-number "$BUILD_NUMBER" >&2

OUT=build/app/outputs/flutter-apk
APK=$OUT/app-armeabi-v7a-release.apk
[ -f "$APK" ] || APK=$OUT/app-release.apk
# No v4 signature next to the APK: adb would pick incremental install, which panics the TV kernel.
rm -f "$OUT"/*.idsig
SDK=${ANDROID_HOME:-$HOME/Library/Android/sdk}
"$SDK/build-tools/36.0.0/apksigner" verify --print-certs "$APK" | grep -m1 'SHA-256' >&2 || true
echo "$PWD/$APK"
