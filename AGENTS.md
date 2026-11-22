# AGENTS.md

Instructions for AI coding agents and for human contributors.
This is the **single source of truth**. Tool-specific files (such as `GEMINI.md`) only point here, so edit this file, not those.
Machine-specific details (your TV's IP address, test devices) go in **`LOCAL.md`**, which is git-ignored. Read it if it exists.

## What this project is

Connect TV controls an Android TV / Google TV from a laptop over Wi-Fi using `adb`:
a remote control, app switching (Netflix, Prime Video, YouTube, …), and a custom photo/video screensaver.

| Part | Path | Notes |
|---|---|---|
| Server | `server.js` | Node.js, **no npm dependencies**: built-ins plus the `adb` binary only. REST API plus static file server. |
| Web UI | `web/index.html` | One self-contained file (HTML + CSS + vanilla JS). No framework, no build step. |
| Device data | `devices.json` | Setup steps per brand (`profiles`), known app names and colours (`apps`), quick-switch list (`defaultChannels`). |
| TV app | `tv-screensaver/` | Android screensaver (`DreamService`) in plain Java with no Gradle. Package `com.connecttv.screensaver`. |
| Phone app | `mobile/` | Flutter app (Android + iOS) that talks to the TV **directly**, with its own Dart ADB client in `mobile/lib/adb/`. `mobile/lib/tv/tv_service.dart` mirrors `server.js`. See `mobile/README.md`. |
| Local data | `data/` | `tvs.json` (saved TVs) and `media/` (uploaded photos). **Git-ignored; never commit.** |

## Commands

```bash
node server.js                      # start the server → http://localhost:8765 (PORT/HOST env vars to change)
./tv-screensaver/build.sh           # build tv-screensaver/build/tv-screensaver.apk
node --check server.js              # syntax check (the server has no test suite yet)

cd mobile
./tool/sync_assets.sh               # copy devices.json + screensaver APK into the phone app's assets
./tool/make_icons.sh                # re-render the app icon from assets/icon/*.svg (needs Chrome)
dart analyze && flutter test        # must pass before committing phone app changes
flutter build apk --release         # Android APK
flutter build ios --debug --no-codesign   # iOS compile check (the simulator build is broken by Xcode 27 setup)
dart run tool/adb_live_test.dart <tv-ip>        # live test of the Dart ADB client (TV shows an Allow prompt for a new key)
```

### Phone app rules
- The Flutter app's dependencies were approved by the owner: `pointycastle`, `shared_preferences`, `image_picker`, `path_provider`. Ask before adding more.
- When you change TV behaviour, change **both** `server.js` and `mobile/lib/tv/tv_service.dart`.
- After changing `devices.json` or the screensaver Java code, run `mobile/tool/sync_assets.sh`.
- `mobile/lib/adb/` is pure Dart (no Flutter imports), so it can be run from the command line.

- `build.sh` needs the Android SDK (`~/Library/Android/sdk` or `$ANDROID_HOME`) and a JDK. It uses `$JAVA_HOME`, then Android Studio's bundled JBR. `java` is **not** on the PATH on the owner's Mac.
- `adb`: `~/Library/Android/sdk/platform-tools/adb` (or set `ADB=`).

## How it works (key facts)

- The server holds the connected TV in memory (`serial`). After a restart the user must click **Connect** again.
- Every TV command goes through `run()` / `sh()` in `server.js`. **Always quote user input with `q()`** before putting it into a remote shell command, and validate it with a regex (see the existing routes).
- Screensaver media and `config.json` are pushed to `/sdcard/Android/data/com.connecttv.screensaver/files/screensaver/`. The fallback is `/sdcard/Pictures/TVScreensaver`. The Java `Slideshow` reads both.
- The screensaver is activated with `settings put secure screensaver_components com.connecttv.screensaver/.PhotoDream`. The previous value is saved in `data/tvs.json` for **Restore**.
- Config keys shared by the server and the app: `intervalSec, shuffle, showClock, fit ("cover"|"contain"), motion, muteVideo`. If you add one, update `DEFAULT_CONFIG` and the `/api/screensaver/config` route in `server.js`, the settings form in `web/index.html`, and `Slideshow.loadConfig()`.

### API (all JSON; POST bodies are JSON)
`GET /api/state` · `GET /api/profiles` · `GET /api/discover` · `POST /api/connect {address}` · `POST /api/pair {address, code}` ·
`POST /api/disconnect` · `POST /api/forget {address}` · `POST /api/key {key, long?}` · `POST /api/text {text}` ·
`GET /api/apps` · `POST /api/launch {pkg}` · `GET /api/current` ·
`GET /api/screensaver/status` · `POST /api/screensaver/install` · `POST /api/screensaver/config` ·
`POST /api/screensaver/upload?name=` (raw file body) · `DELETE /api/screensaver/file?name=` ·
`POST /api/screensaver/activate {timeoutMin}` · `POST /api/screensaver/restore` · `POST /api/screensaver/preview`

## Conventions

- **Keep it dependency-free.** Don't add npm packages, bundlers, frameworks, or Gradle without the owner agreeing first.
- Keep the UI in one file. Use CSS variables for colours (it supports light and dark mode). Show errors to the user with `toast(msg, true)`.
- Java: target minSdk 24, compile against the newest installed platform, and use no AndroidX or other libraries.
- Error messages are shown to non-technical users. Write them in plain words and say what to do next.
- Keep the server bound to `127.0.0.1` by default. It has no authentication.

## Working with the real TV

- The owner's TV model and IP address are in `LOCAL.md`. TCL Google TVs drop off Wi-Fi in standby. If the TV is unreachable, ask the owner to turn it on rather than retrying in a loop.
- Read-only checks (`adb devices`, `getprop`, `settings get`, `pm list packages`) are fine.
- **Ask the owner first** before anything visible or disruptive on the TV: launching apps, key presses, power or sleep, installing or uninstalling, changing `settings put`, or deleting files.
- After changing Java code, rebuild with `build.sh` and reinstall (Screensaver tab → Reinstall, or `POST /api/screensaver/install`).

## Documentation you must maintain

- **`DEVLOG.md`**: after any session that changes code, config, or the TV setup, add a dated entry **at the top** (or add to today's entry): what changed, why, what was tested on the real TV, and open issues. A template is at the bottom of the file. Don't put IP addresses, device serials or other personal details in it.
- **`ROADMAP.md`**: tick off finished items, and add new ideas or known issues.
- **`README.md`**: update it when the setup, commands, or features change.

## Git

- Branch: `main`. Write commit messages in the imperative, with a short summary line.
- Never commit `data/`, `LOCAL.md`, `tv-screensaver/build/`, `mobile/ios/Flutter/Signing.xcconfig`, keystores, or `.env` files.
- Commit only when the owner asks. Don't force-push.
