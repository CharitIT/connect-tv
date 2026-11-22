# Dev Log

A running record of what changed, why, and what was learned. Newest entries first.
Planned work lives in [ROADMAP.md](ROADMAP.md); this file records what actually happened.

---

## 2026-11-21: Installed the phone app on real phones

### Changed
- **iPhone** (iOS 27, connected to the Mac over Wi-Fi): `flutter build ios --release`, then `flutter install`. Signing used the Apple team set in Xcode. Confirmed installed with `xcrun devicectl device info apps`.
- **Android** (Samsung Galaxy, over USB): the owner turned on USB debugging, then `adb -s <phone serial> install -r app-release.apk` succeeded.

- **App icon**: the owner picked idea D (a phone in front of a TV, purple gradient) from 4 drafts. The sources are SVGs in `mobile/assets/icon/`. `mobile/tool/make_icons.sh` renders them with headless Chrome and resizes with `sips`, so no new packages are needed. It writes the iOS AppIcon set (opaque, as Apple requires) and Android legacy icons plus adaptive background/foreground layers. Rebuilt and reinstalled on both phones.

### Notes
- Reinstalling on the iPhone with `flutter install` uninstalls first, which wipes the app's saved TV, setup progress and key. The TV asks "Allow" again after that.
- The APK is Android only. iPhones must be installed from Xcode/Flutter on the Mac.
- With the TV not connected to the Mac's adb, `adb devices` lists only the phone. Always pass `-s <serial>` once both are attached.

### Privacy cleanup before publishing
- Removed AI-tool names and personal details (TV IP and model, phone names and serials, Apple team ID) from the tracked docs and code.
- Personal notes now live in `LOCAL.md` (git-ignored). The iOS signing team moved to `mobile/ios/Flutter/Signing.xcconfig` (git-ignored, pulled in with `#include?`).
- The generated `mobile/assets/tv-screensaver.apk` is now git-ignored. Recreate it with `tool/sync_assets.sh`.

### Open issues / next
- The phone couldn't connect: the TV answered ping and its Cast/remote ports (8008, 8009, 6466, 6467), but **port 5555 was closed**, so network ADB had stopped after a TV restart. Fix: toggle USB debugging off and on. Idea: make the app detect "TV reachable, 5555 closed" and say exactly that.
- The owner tests the setup guide and the TV connection on both phones. Each phone has its own key, so the TV shows "Allow USB debugging?" once per phone.

---

## 2026-11-20: Phone app for Android + iPhone

### Decision
- The owner wants an installable phone app for **both Android and iPhone**, with a first-run guide (Developer mode → connect → screensaver → features).
- Options considered: a Mac app, a home-screen web app that needs the Mac server running, or a standalone app. The owner chose a **standalone Flutter app** that talks to the TV directly, so no computer is needed after setup.
- New dependencies (approved): `pointycastle` (RSA), `shared_preferences`, `image_picker`, `path_provider`.

### Built (`mobile/`)
- **A Dart ADB client** (`lib/adb/`): CNXN/AUTH handshake, RSA token signing (PKCS#1 v1.5, SHA-1 DigestInfo, done by hand with CRT because adb signs the token as a pre-computed digest), the Android `RSAPublicKey` format (n0inv and rr), shell streams, and the sync push protocol with flow control.
- **`tv_service.dart`**: a port of `server.js`, covering keys, text, listing and launching apps, the current app, screensaver install/upload/delete/config/activate/restore/preview, and a Wi-Fi scan for port 5555.
- **UI**: the setup wizard (6 steps), then Remote, Apps, Screensaver and Settings tabs. A status chip in the app bar reconnects on tap, and the app reconnects automatically on launch and resume.
- **Photos**: picked with `pickMultipleMedia` and resized to at most 3840×2160 at quality 90. On iPhone this also converts HEIC to JPEG, which ticks off two roadmap items. Local copies are kept for thumbnails.
- The screensaver APK and `devices.json` are bundled as assets via `tool/sync_assets.sh`.
- iOS: added Local Network, Photos, Camera and Mic usage strings, and raised the deployment target from 13.0 to 15.0 (required by Xcode 27). Android: INTERNET permission. The app is named "Connect TV" on both.

### Tested
- ✅ `dart analyze` is clean, and `flutter test` passes 5 tests (crypto: signature layout, public-key layout, key round-trip; UI: the wizard pages and the home tabs while disconnected).
- ✅ The UI smoke test caught a real bug: home used an `IndexedStack`, which built every tab, so the Screensaver tab called the TV and showed a SnackBar inside `initState` while disconnected. Fixed by building only the visible tab and loading after the first frame.
- ✅ `flutter build apk --release` (52.8 MB, all CPU types) and `flutter build ios --no-codesign` both succeed.
- ❌ The iOS **simulator** build fails ("Failed to copy Flutter framework", and Xcode says the iOS 27.2 simulator isn't installed). This is a toolchain setup problem, not the app code.
- ⏳ **Not yet tested against the real TV**: the TV was in standby. Reading the Mac's trusted adb private key for a no-prompt test was (rightly) blocked by the permission system. Next: run `dart run tool/adb_live_test.dart <tv-ip>` with the owner at the TV to accept the prompt, then test on a real phone.

### Open issues / next
- Live-test the ADB client, then the full app on a real Android phone and a real iPhone.
- Encrypted Wireless debugging (TLS + pairing code) isn't supported. That's fine for the TCL, which uses port 5555.
- The release APK is signed with the debug key. Add a proper release keystore before sharing it with others.

---

## 2026-11-20: Reconnect after the TV dropped off; macOS Local Network fix

### What happened
- The TV couldn't be reached at its usual IP address ("No route to host"). A full subnet scan found nothing, even after the owner restarted the TV's Wi-Fi.
- The TV did briefly show up in the Mac's ARP table, so it was on the network.
- **Root cause:** the Mac could ping the router but **no other LAN device** (another computer on the network also failed). This is the macOS **Local Network** privacy block on VS Code, which starts the coding tools, node and adb. The block returns `EHOSTUNREACH` for LAN peers.
- **Fix:** System Settings → Privacy & Security → Local Network → enable Visual Studio Code, then quit and reopen VS Code. The TV answered straight away.

### Tested
- ✅ Reconnected on port 5555. It was still authorized, so no prompt appeared on the TV.
- ✅ The screensaver is still installed and active (`com.connecttv.screensaver/.PhotoDream`) with a 3-minute idle timeout. It has 4 items: 2 photos and 2 videos, uploaded by the owner on 2026-11-19.

### Changed
- README troubleshooting and ROADMAP known issues now cover the macOS Local Network permission.

### Open issues / next
- How to diagnose it quickly: if the router pings but other LAN devices don't, check the Local Network permission before blaming the TV. A possible feature: show this hint in the UI when connect fails with "No route to host".
- The server was started from the editor's coding session, so it stops when the session ends. A launchd service is on the roadmap.

---

## 2026-11-19: Agent-agnostic project instructions

### Changed
- Added **`AGENTS.md`** as the single source of truth for any AI coding agent (Codex, Antigravity, Gemini CLI, Cursor, …). It covers the architecture, commands, the API, conventions, rules for working with the real TV, documentation duties, and git rules.
- Tool-specific files such as `GEMINI.md` are now thin pointers that import `@AGENTS.md`, so the rules can't drift apart.
- Added a "Working with AI agents" section to the README.

### Why / notes
- The owner wants to switch between AI tools freely. Each tool reads a different file name, and AGENTS.md is the shared standard.
- New rule: agents must ask before visible or disruptive actions on the TV (key presses, launching apps, installs, `settings put`).
- Dev log entries should now say which agent or tool did the work.

---

## 2026-11-19: First working version, tested on a TCL Google TV

### Starting point
- `server.js` and `devices.json` were complete. The screensaver app had only its manifest and resources.
- Missing pieces: the web UI (`web/` was empty), the screensaver Java sources, and the APK build script.
- The source folder was `com/tvremote/screensaver`, but the package is `com.connecttv.screensaver`. Renamed the folder to match.

### Built
- **`web/index.html`**: a single-file UI with four tabs.
  - **Connect**: per-brand setup steps, scanning the Wi-Fi for TVs, saved TVs, and pairing-code support.
  - **Remote**: D-pad, volume, power, playback, typing into the TV, and keyboard shortcuts.
  - **Apps**: quick switch for Netflix, Prime Video, Disney+, JioHotstar and YouTube, filtered to what's installed, plus a list of all apps.
  - **Screensaver**: install, drag-and-drop upload, thumbnails, settings, preview, set as screensaver, and restore.
- **Screensaver app** (`tv-screensaver/src/com/connecttv/screensaver/`):
  - `Slideshow.java`: crossfading photos, a Ken Burns zoom/pan, animated GIFs, videos (muted by default), a clock, and an empty-state message. It reads `config.json` and media from the app's external files folder.
  - `PhotoDream.java`: the screensaver service. `PreviewActivity.java` is a launchable preview: Right skips ahead, OK exits.
- **`tv-screensaver/build.sh`**: builds the APK without Gradle (aapt2 → javac → d8 → zipalign → apksigner, using the debug keystore).
- **`README.md`**, **`ROADMAP.md`** and **`.gitignore`** (`data/` and `build/` are excluded so photos and the TV's IP stay local).

### Fixes along the way
- **Motion animation**: two `animate()` calls on one view overwrote each other's duration, so the fade and the zoom ran at the wrong speeds. Moved the zoom/pan to its own `AnimatorSet`.
- **YouTube TV name**: on this TV, YouTube TV's package is `com.google.android.youtube.tvunplugged`, which wasn't in `devices.json`. Added it so the app shows its proper name.

### Environment notes
- `java` isn't on the PATH on this Mac. `build.sh` falls back to Android Studio's bundled JDK (`/Applications/Android Studio.app/Contents/jbr`, JDK 21).
- SDK: build-tools 37.0.0 and platform android-36. `sort -V` picks android-36 over android-36.1, which is fine.
- `apksigner` also needs a JDK. Set `JAVA_HOME` to the Android Studio JBR when running it by hand.

### Tested on the real TV
- TCL Google TV, Android 11 (SDK 30), network ADB on port 5555.
- Network ADB on port 5555 worked as soon as USB debugging was on. No pairing code was needed.
- ✅ Connect and authorize, after accepting the "Allow USB debugging?" prompt.
- ✅ Volume control and app switching, confirmed by the user.
- ✅ Screensaver APK installed. The `files/screensaver/` folder and `config.json` were confirmed on the TV.
- ✅ Set as screensaver. The original component was saved for Restore: `com.google.android.apps.tv.dreamx/.service.Backdrop`.
- Installed streaming apps: Netflix, Prime Video, Disney+, YouTube, YouTube TV, YouTube Music, ZEE5.

### Problems seen
- **The TV dropped off the network** (no ping and no port 5555; a full subnet scan found nothing). This is most likely standby, since TCL turns Wi-Fi off in standby. It can't be fixed from the laptop. Next: enable network standby on the TV and reserve its IP in the router. Logged in ROADMAP under known issues.
- The server keeps the active connection only in memory, so it is lost when the server restarts. Auto-reconnect is on the roadmap.

### Git
- Initialized the repo on `main` and made the first commit. Not pushed yet: `gh` isn't logged in. Run `gh auth login`, then `gh repo create connect-tv --private --source=. --push`.

---

<!--
Template for new entries (copy above the previous entry):

## YYYY-MM-DD: Short title

### Changed
-

### Why / notes
-

### Tested
-

### Open issues / next
-
-->
