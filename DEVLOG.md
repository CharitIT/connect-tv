# Dev Log

A running record of what changed, why, and what was learned. Newest entries first.
Planned work lives in [ROADMAP.md](ROADMAP.md); this file records what actually happened.

---

## 2026-11-26: iPhone mirroring via an AirPlay receiver

### Changed
- Phone app (iPhone): Mirror this phone now offers a working route. Google TVs have no AirPlay, so the page has a button that opens AirScreen (`com.ionitech.airscreen`, a free AirPlay receiver by another company) in the TV's Play Store. After it's installed, the iPhone's own Control Center → Screen Mirroring lists the TV. The page has step-by-step instructions.
- The iPhone setup guide has a new optional step, "Mirror your iPhone", between the screensaver and the end, with the same AirScreen button and steps as the Mirror page (shared `IphoneMirrorSetup` widget). With Developer mode connected it shows a tick when AirScreen is already on the TV. Android phones don't get this step (they use Chromecast).
- Fixed a crash risk in the setup guide: the screensaver step could read its context after it had closed.
- New `openStorePage(pkg)` in `AppState` (remote link: `market://details?id=` app link; Developer mode: `am start`) and `TvService`.

### Tested
- `dart analyze`, all 16 tests (new: the iPhone guide has the mirroring step, Android's doesn't); installed on the iPhone (data kept) and the Android phone. Checked the TV (read-only): it has the Play Store and no AirPlay receiver yet.

### Open issues
- Not yet tried: installing AirScreen on the TV and mirroring the iPhone.
- The iPhone's free signing still expires on 2026-11-28; rebuild and reinstall after that.

---

## 2026-11-26: Several TVs in the phone app

### Changed
- Phone app: it can now save several TVs and switch between them. Tap the TV name under the tab title (or Settings → Other TVs) to switch; "Add another TV" runs the setup guide for a new TV, with Cancel to go back. Each TV keeps its own pairing, screensaver settings, album syncs, bedtime and favourites. Forgetting a TV switches to another saved one, or starts the setup when none is left.
- Saved TVs are stored as a list (`tvs` plus `currentTv`); the single TV saved by older versions moves over by itself.
- Switching closes the old connections and drops any that finish late, clears the old TV's sleep timer state, and is blocked while an album sync runs. One TV is controlled at a time.
- The laptop web app already kept several saved TVs, so it is unchanged.

### Tested
- New `multi_tv_test.dart` (moving the old saved TV over, add/cancel, second TV, reload, forget). `dart analyze`, all tests, release APK; installed on the Android phone.

### Open issues
- Not yet tried with a second real TV.

---

## 2026-11-26: Sleep timer fix

### Changed
- Phone app: the sleep timer didn't turn the TV off. Likely cause: the Developer-mode link had dropped, so the timer ran inside the phone app, and the phone pauses apps in the background, so it never fired. Now, before setting a timer, the app reconnects Developer mode if it worked before (no new Allow prompt), and if the link turns out to be stale it reconnects once and retries, so the timer runs on the TV. When it still has to run on the phone, the Timers page shows a clear warning.

### Tested
- On the TV (harmless test job, no key press): a `nohup` background job started over ADB keeps running after the shell closes and fires on time, so the on-TV timer method itself works.
- On the TV (with the owner's OK): the same 1-minute timer command the app uses switched the TV off on time (power state Asleep, display off).
- `dart analyze`, `flutter test`, release APK build; installed on the Android phone.

### Open issues
- Setting the timer from the phone app itself (with the reconnect step) still to be tried by the owner.

---

## 2026-11-22: Mirror this phone

### Changed
- Phone app: Remote tab → **Mirror this phone**. The TV has Chromecast built in, so on Android the button hands over to the phone's own screen casting: the system Cast settings first (Google Home first on Samsung, whose Cast settings open its own Smart View screen mirroring), then the Google Home app ("Cast my screen"), then Google Home in the Play Store. This gives smooth video with sound, which streaming over ADB could not. On iPhone the page explains that Google TVs don't support AirPlay and lists what works instead (Cast buttons in apps, Open a link, screensaver photos).
- Android `MainActivity`: new `connecttv/cast` method channel (`castScreen`).

### Tested
- `dart analyze`, `flutter test`, release APK build. Confirmed (read-only) that the TV has the Chromecast receiver installed.

### Open issues
- Casting itself still needs a hands-on try on the Samsung (installed there; the phone was locked during testing).

---

## 2026-11-22: Auto-reconnect, favourite apps, volume slider, On this day

### Changed
- **Auto-reconnect**:
  - Phone app: while it's open, a check every 8 s (`tvLooksOn`, a quick port probe) reconnects as soon as the TV is back from standby. If only the remote came back, it retries Developer mode at most once a minute, and only if Developer mode had worked before (no surprise Allow prompt). Settings → Disconnect stops this until the user connects again.
  - Server: on start it reconnects to the TV used last (newest `lastConnected` in `data/tvs.json`), then retries every 20 s. "Disconnect" stops it.
- **Favourite apps**: a row of coloured app buttons on the Remote tab, plus Edit to choose and reorder them (from the TV's app list with Developer mode, otherwise the known apps). Stored in `SavedTv.favourites` (null = `defaultChannels`). The Apps tab's Quick switch uses the same list.
- **Volume slider**: Android 11 has no "set volume to N" command (`media` and `cmd media_session volume` aren't available). The slider presses volume up/down the needed number of times, then checks, up to 3 passes, stopping if a press moves more than one step. Developer mode sends all the presses in one `input keyevent K K K…` (the TV's `input` help confirms several keys are allowed).
- **On this day** (`onThisDay`, `dates` config keys):
  - The TV reads each photo's EXIF date with `android.media.ExifInterface` (cached), or uses `dates` sent by the phone. On days when photos from earlier years match today's month and day, it plays those from every album, captioned "N years ago today".
  - Album sync sends each item's taken date (`createDateTime`) into `dates`, so converted HEIC photos without EXIF still work, and clears entries for removed items.
  - Settings switch on the phone and a checkbox on the web page.

### Tested
- ✅ Server restart **without clicking Connect**: it reconnected to the TV by itself. Config with `onThisDay` keeps `intervalSec: 5`.
- ✅ Analyze clean, 14 tests pass (new: favourites and On this day dates survive saving). Screensaver APK rebuilt and bundled. Both phones updated.
- ⛔ Pressing a no-op key on the TV to check multi-key `input keyevent` was blocked (asking first is the rule). The `input` help text confirms it's supported.
- ⏳ For the owner: the slider, the favourites row, and On this day (needs the screensaver reinstalled on the TV).

---

## 2026-11-22: Show the TV volume

### Changed
- The owner couldn't see the volume level on the phone. The Remote tab now shows "Volume 14" on the volume button, plus a bar with "14 / 100" (or "Muted").
- Sources of the volume reading:
  - **Remote link**: the TV sends `RemoteSetVolumeLevel` (field 50: 6 = max, 7 = level, 8 = muted) whenever the volume changes.
  - **Developer mode**: `dumpsys audio` STREAM_MUSIC `streamVolume` and `Max`, read about 350 ms after a volume key and when the Remote tab opens.
- Server: new `GET /api/volume`. The web page shows "Volume N / max" after the volume keys.

### Remove several photos at once
- The owner asked to delete photos already on the screensaver. Single removal was hidden behind tapping a photo, so the Screensaver tab now has **Select** (or press and hold a photo).
  - Tap photos to tick them, use **All/None**, then **Remove**, and confirm.
  - Removing a photo also clears its caption and sound setting. The phone copies are kept.
- A removed photo that came from a synced phone album isn't sent again: the sync still treats it as already sent.

### Tested
- ✅ The TCL reports STREAM_MUSIC 14/100, not muted. `GET /api/volume` returns `{"level":14,"max":100,"muted":false}`.
- ✅ Analyze clean, 13 tests pass. Installed on the iPhone; the Samsung wasn't on USB.
- ⏳ The volume messages over the remote link (field numbers taken from the public protocol description) haven't been seen live yet. The Developer-mode reading covers it if they differ.

---

## 2026-11-21: Screensaver albums, schedules, overlays, transitions (#12, #14, #15)

### Changed
- **TV app (`Slideshow.java`)**:
  - Albums: the screensaver folder is the Main album, and the others are `albums/<name>/`. The active album comes from the first matching `schedule` rule (a date range like `MM-DD`, a time range in minutes, or both; ranges can wrap past New Year or midnight), otherwise from `album`. It is re-checked before every photo, and an empty album falls back to Main.
  - Transitions: fade, slide (the new photo pushes the old one off; the zoom starts after it arrives), or cut.
  - Per-video sound (`soundOn`), a date line and per-photo captions (`captions`).
  - Weather from Open-Meteo every 30 min. This needs the INTERNET permission; without internet the weather is simply left out.
- **Phone app**:
  - `ScreensaverConfig` covers every key and keeps unknown keys. The Screensaver tab reads the TV's `config.json` as the source of truth.
  - UI: album picker, new/delete album, a sheet per photo (caption, sound, remove), transition, date, and a weather town search (Open-Meteo geocoding, run from the phone).
  - New "Which album plays" page with a schedule editor that can be reordered.
  - Reinstalling the screensaver keeps the TV's settings.
- **Server and web**:
  - The config route now reads the TV's `config.json` and changes only the keys it's sent. Before, the laptop and the phone overwrote each other's settings.
  - New album routes, plus `album` on status, upload and delete. The web page has an album picker, new/delete album, transition, date and the album that plays.

### Tested
- ✅ `dart analyze` clean, 12 tests pass (new: settings round-trip with unknown keys, album names and paths). The TV app builds.
- ✅ The schedule range logic, run with Java: Diwali dates, New Year wrap-around, and a night window.
- ✅ Server against the real TV (nothing visible): status lists albums and reads the TV config; saving with nothing changed keeps the existing `intervalSec: 5`; a test album was created, listed and deleted; bad album names and deleting Main are refused.
- ✅ Both phones updated.
- ⏳ The screensaver app on the TV is still the old version. Reinstalling it shows the preview for about 2 seconds and then goes Home, so it waits until the owner is ready.

### Phone album sync (#13)
- The owner approved the **`photo_manager`** package (added to AGENTS.md).
- `lib/sync/album_sync.dart` + `ui/sync_page.dart`:
  - Link a phone album to a TV album. This covers Google Photos and iCloud albums that are on the phone.
  - Each sync sends new items (up to 150 per run) and removes items deleted from the phone album. A map from asset ID to TV file name is stored in `SavedTv.syncs`.
  - Photos: JPEG/PNG/WEBP up to 12 MB are sent as they are. Others (HEIC, very large) become a 4K JPEG using "fit" mode, so nothing is cropped. Videos up to 500 MB are sent as they are.
  - It runs on "Sync now", and quietly after Developer mode connects, but only if photo access was already given, so no prompt pops up by surprise.
- Android: added the READ_MEDIA_IMAGES/VIDEO/VISUAL_USER_SELECTED permissions (and READ_EXTERNAL_STORAGE for SDK 32 and below). iOS already had the Photos usage text.
- ✅ Analyze clean, 13 tests pass (new: sync links survive saving). Installed on both phones. ⏳ The owner still needs to test a real album sync.

### Fix: album sync "not working"
- On the TV, no album folder had even been created, so the sync stopped on the phone.
- On the Samsung (`dumpsys package`), photo access had been given as **"limited" (selected photos only)**. The app then sees only the picked photos and never new ones.
- Three silent failures could look like "nothing happens":
  1. the sync quietly did nothing when Developer mode wasn't connected;
  2. the album picker could open empty with no message;
  3. errors from the automatic sync were never shown.
- Fixes:
  - The sync page now shows a card for each case: limited access, with **Open Settings** (and it re-checks when you come back); Developer mode not connected, with a Connect button; and the last sync error.
  - A skipped item now gives the reason.

### Open issues / next
- Background sync while the app is closed would need another package (ask first).

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

### Remote features: touchpad, voice, screen, links, timers (#4, #6, #8, #10, #11)
- **#4 Touchpad**: the Remote tab can switch between Buttons and Touchpad. Every 40 px of swipe sends one arrow key, and a quick tap sends OK. An `EagerGestureRecognizer` stops the page from scrolling while you swipe.
- **#6 Voice / typing**: the text box tells you to use the keyboard's 🎤 (no speech package needed). Without Developer mode, text is sent as key presses over the remote link (`charKeyCode`): lower-case letters, digits and common symbols.
- **#8 TV screen**: `ScreenPage` shows `exec:screencap -p` (new `AdbClient.execBytes`) every 3 s, with pause and pinch-to-zoom. On this TCL, `screencap` produces an **empty file while Netflix is playing**, because DRM blocks it. The app shows a plain message instead. Works on the home screen (tested by the owner).
- **#10 Links**: `openUrl` goes over the remote link (app link) or ADB (`am start -a VIEW`). Android: "Share → Connect TV" (a `SEND text/plain` intent filter plus a `MethodChannel` in `MainActivity.kt`) opens a confirm dialog. Both platforms: an "Open a link" button that pre-fills a link from the clipboard. iPhone Share-sheet support would need an app extension; it's on the roadmap.
- **#11 Timers**:
  - The **sleep timer** runs on the TV with Developer mode: `nohup sh -c 'echo $$ secs > pid; sleep …; input keyevent KEYCODE_SLEEP' &`. The app reads the time left back from the file's mtime. Without Developer mode the timer runs in the app.
  - **App bedtime** is a script pushed to `/data/local/tmp`. Every 20 s during the set hours, if a chosen app is on top, it presses HOME. The app restarts the script on connect if the TV restarted.
- **Server/web parity**: `POST /api/open`, `GET /api/screenshot`, and `POST`/`GET /api/sleep`, plus a link box, a sleep-timer menu and a "See TV screen" button on the web Remote tab.
- Safe live checks on the TV (Netflix was playing, so nothing visible was done):
  - a background `nohup` task survives an ADB disconnect;
  - mksh `$((10#$h*60+10#$m))` works;
  - the sleep timer starts, reads back and cancels (600 min, then cancelled);
  - the bedtime script runs and sees the top app (only a made-up app was blocked);
  - the server's open route rejects bad links;
  - the screenshot route reports the Netflix block.
- ✅ `dart analyze` clean, 10 tests pass (new: key codes, link finding and checking, bedtime settings). Installed on both phones.
- ✅ The owner tested these on the real TV and phones: the touchpad, Share → Connect TV on the Samsung, the screen preview on the home screen, and the sleep timer.

### No Developer mode needed for the remote (#2)
- New `mobile/lib/atv/`: the **Android TV Remote protocol v2**, the one Google's TV remote app uses. The TV listens on 6466/6467 even without Developer mode.
  - `atv_cert.dart`: a self-signed X.509 client certificate (SHA256withRSA) and a PKCS#1 key, built from the phone's existing RSA key with a small DER encoder. It also reads the RSA key out of the TV's certificate. Checked with `openssl verify` and `openssl rsa -check`.
  - `atv_remote.dart`: pairing (port 6467): request → options (6-char hex) → configuration → the TV shows a code → secret = SHA-256(client n, e, TV n, e, code[2:]), where the code's first byte is a checksum. Remote (port 6466): configure / set-active handshake, ping replies, key inject (short and long press), app links (`market://launch?id=<pkg>`), and the on-screen app and power state. Protobuf is encoded by hand.
- `AppState` keeps both links. When the phone is paired, the remote connects first and ADB connects in the background. Keys use the remote link, falling back to ADB; launching apps prefers ADB, falling back to an app link. The screensaver, typing and the full app list need ADB.
- UI changes:
  - The setup guide now goes: brand → **find TV + pair with a code** → Developer mode (optional, "Skip for now") → screensaver → done.
  - Settings shows both connections, with "Pair as remote" and "Developer mode" actions.
  - The Screensaver tab shows the Developer-mode steps when only the remote is connected.
  - The Apps tab shows quick-switch tiles plus a hint.
- Wi-Fi discovery now finds TVs on port 6466 or 5555.

### Clear message when ADB is off (#1)
- If the connect to 5555 fails but the TV answers on 6466/6467/8008/8009, both `server.js` and `adb_client.dart` now say the TV is on and tell the user to turn USB debugging off and on. Tested by simulating it (a listener on 6466 with 5555 closed): both show the new message.

### Tested
- ✅ `dart analyze` clean. 7 tests pass: new certificate tests, plus the setup-guide test, which caught a real bug (the pairing panel looked up app state in `dispose()`).
- ✅ `tool/atv_live_test.dart check` against the real TV: the TLS connection to 6466 works, and the TV correctly reports a new identity as not paired. Nothing showed on the TV.
- ✅ Pairing with a code on the real TV works. The owner confirmed that pairing, the remote and app switching all work. The updated build is installed on both the iPhone and the Samsung.

### Other
- A separate Python program on this Mac also listens on port 8765 (all interfaces), so `localhost:8765` can reach it instead of the Connect TV server. Use `127.0.0.1:8765`.

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
