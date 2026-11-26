# Connect TV: phone app (Android + iPhone)

A Flutter app that controls an Android TV / Google TV **directly from the phone** over Wi-Fi. No computer is needed after it's installed.

- **Setup guide** on first launch: choose your TV brand → find the TV and **pair with a code shown on the TV** → Developer mode (optional, for the screensaver) → set up the screensaver → (iPhone) screen mirroring with an AirPlay app on the TV → feature tour.
- **Remote**: D-pad or **swipe touchpad**, OK, Back, Home, volume, mute, power, playback, and typing or **speaking** (the keyboard's 🎤) into the TV.
- **More**: see the TV screen live, mirror the phone (Android, via the TV's built-in Chromecast), open a YouTube/Netflix link on the TV (Android: Share → Connect TV), sleep timer, and app bedtime.
- **Several TVs**: save more than one TV and switch by tapping the TV name at the top (or Settings → Other TVs → Add another TV).
- **Apps**: quick-switch tiles (Netflix, Prime Video, Disney+, YouTube, …) and every app on the TV.
- **Screensaver**: install the screensaver app on the TV, add photos and videos into **albums** (or **sync a phone album** so new photos appear on the TV automatically), choose which album plays (with **schedules** by date or time), captions, per-video sound, transitions, date and weather, preview, set it as the screensaver, or restore the original.

## How it works

The app talks to the TV in two ways:

| | Needs | Used for |
|---|---|---|
| **Android TV Remote protocol** (`lib/atv/`), the one Google's own TV remote uses | Pairing once with a 6-character code shown on the TV | Keys, volume, power, opening apps, which app is on screen |
| **ADB** (`lib/adb/`) | Developer mode + USB debugging on the TV | Screensaver, typing, full app list; also keys and apps if not paired |

The remote protocol uses TLS with a self-signed client certificate made from the phone's RSA key (`lib/atv/atv_cert.dart`). Pairing is on port 6467 and the remote on port 6466, with hand-encoded protobuf messages, so no extra packages are needed. The TV remembers the certificate, so pairing is a one-time step.

If the TV is on but its ADB port is closed (common after a TV restart), the app says so and tells the user to turn USB debugging off and on.

The app has its own ADB client written in Dart (`lib/adb/`). It connects to the TV's `adbd` on port 5555 and signs in with an RSA key that is generated once and stored on the phone. The first connection shows "Allow USB debugging?" on the TV. Everything else mirrors the laptop `server.js` (`lib/tv/tv_service.dart`).

The TV screensaver APK and `devices.json` are bundled as assets. Refresh them with `tool/sync_assets.sh` after changing either one.

```
lib/
  adb/adb_crypto.dart      RSA key, token signing, Android public-key format
  adb/adb_client.dart      ADB wire protocol: connect/auth, shell, push (sync)
  atv/atv_cert.dart        Self-signed client certificate + tiny DER encoder/parser
  atv/atv_remote.dart      Android TV Remote protocol: pairing (6467) and remote (6466)
  tv/tv_service.dart       TV actions (keys, apps, screensaver) + Wi-Fi discovery
  tv/catalog.dart          Brand setup guides + app names from assets/devices.json
  app_state.dart           Saved TV, key, connection status, auto-reconnect
  ui/setup_wizard.dart     First-run guide
  ui/home_shell.dart       Tabs: Remote · Apps · Screensaver · Settings; receives Android shared links
  ui/screen_page.dart      Live picture of the TV screen
  ui/timers_page.dart      Sleep timer and app bedtime
  ui/album_schedule_page.dart  Which album plays + schedule rules
  ui/sync_page.dart        Link phone albums to TV albums
  sync/album_sync.dart     Mirrors a phone album to a TV album (photo_manager)
tool/
  sync_assets.sh           Copy devices.json + screensaver APK into assets/
  make_icons.sh            Render the app icon (assets/icon/*.svg) for Android + iOS
  adb_live_test.dart       Test the ADB client against a real TV from the Mac
  atv_live_test.dart       Test pairing and the remote from the Mac (check | pair | key)
```

## Build and run

```bash
cd mobile
./tool/sync_assets.sh                 # after changing ../devices.json or ../tv-screensaver
flutter test                          # unit + UI smoke tests
flutter run                           # on a connected phone

flutter build apk --release           # Android: build/app/outputs/flutter-apk/app-release.apk
flutter build ios --release           # iPhone: then archive/sign in Xcode
```

### Installing on an Android phone
Copy `app-release.apk` to the phone (AirDrop doesn't work with Android, so use Google Drive, email, or a USB cable) and open it. Allow "Install unknown apps" when asked.
Or, with the phone plugged in and USB debugging on: `flutter install`.

### Installing on an iPhone
1. Open `ios/Runner.xcworkspace` in Xcode.
2. Set your Apple developer team in a local file that stays out of git. Create `ios/Flutter/Signing.xcconfig` containing `DEVELOPMENT_TEAM = <your team ID>`. The team ID is shown in Xcode → Settings → Accounts, or under Runner → Signing & Capabilities. Don't pick the team in Xcode itself, because that writes it into the shared project file. Change the bundle ID if Xcode asks.
3. Plug in the iPhone, select it as the run target, and press Run. On the iPhone: Settings → General → VPN & Device Management → trust your developer certificate.
4. With a free Apple ID the app stops opening after **7 days** and has to be run from Xcode again. A paid Apple Developer account ($99/year) removes that limit and allows TestFlight or the App Store.

The first time the app connects, iOS asks for **Local Network** access. Allow it, or the app can't reach the TV.

## Testing against the real TV from the Mac

```bash
dart run tool/adb_live_test.dart <tv-ip>
```
This makes a test key, connects (the TV asks "Allow USB debugging?" the first time), reads device info, and pushes, checks and deletes a small file in `/data/local/tmp`.

## Limits

- Needs **USB debugging** (legacy network ADB on port 5555). TVs that only offer encrypted *Wireless debugging* with a pairing code aren't supported yet.
- The TV must be on. Most TVs turn their Wi-Fi off in standby.
