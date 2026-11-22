#!/usr/bin/env bash
# Builds build/tv-screensaver.apk using only the Android SDK command-line tools (no Gradle / Android Studio project).
set -euo pipefail
cd "$(dirname "$0")"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
[ -d "$SDK" ] || { echo "Android SDK not found. Set ANDROID_HOME."; exit 1; }

BT="$(ls -d "$SDK"/build-tools/*/ | sort -V | tail -n 1)"
JAR="$(ls -d "$SDK"/platforms/android-*/android.jar | sort -V | tail -n 1)"
[ -x "$BT/aapt2" ] || { echo "No build-tools found in $SDK/build-tools"; exit 1; }
[ -f "$JAR" ] || { echo "No platform android.jar found in $SDK/platforms"; exit 1; }

# Find a JDK: JAVA_HOME, then Android Studio's bundled one, then PATH.
if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/javac" ]; then JDK="$JAVA_HOME"
elif [ -x "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/javac" ]; then JDK="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
elif /usr/libexec/java_home >/dev/null 2>&1; then JDK="$(/usr/libexec/java_home)"
else echo "No JDK found. Install Android Studio or set JAVA_HOME."; exit 1; fi
export JAVA_HOME="$JDK" PATH="$JDK/bin:$PATH"

echo "build-tools: $BT"
echo "platform:    $JAR"
echo "jdk:         $JDK"

OUT=build
rm -rf "$OUT" && mkdir -p "$OUT/classes" "$OUT/dex"

"$BT/aapt2" compile --dir res -o "$OUT/res.zip"
"$BT/aapt2" link -I "$JAR" --manifest AndroidManifest.xml \
  --min-sdk-version 24 --target-sdk-version 34 --version-code 1 --version-name 1.0 \
  -o "$OUT/unsigned.apk" "$OUT/res.zip"

javac --release 11 -classpath "$JAR" -d "$OUT/classes" $(find src -name '*.java')
"$BT/d8" --release --min-api 24 --lib "$JAR" --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')
(cd "$OUT/dex" && zip -q -j ../unsigned.apk classes.dex)

"$BT/zipalign" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

KS="$HOME/.android/debug.keystore"
if [ ! -f "$KS" ]; then
  mkdir -p "$HOME/.android"
  keytool -genkeypair -keystore "$KS" -storepass android -keypass android -alias androiddebugkey \
    -dname "CN=Android Debug,O=Android,C=US" -keyalg RSA -keysize 2048 -validity 10000
fi
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out "$OUT/tv-screensaver.apk" "$OUT/aligned.apk"
rm -f "$OUT/unsigned.apk" "$OUT/aligned.apk" "$OUT/res.zip"

echo "Built $(pwd)/$OUT/tv-screensaver.apk"
