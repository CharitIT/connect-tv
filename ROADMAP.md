# Roadmap

Status as of 2026-11-19: remote control, app switching, and the custom screensaver all work on a TCL Google TV. The screensaver app is installed and set as the TV's screensaver.

## Next steps (do soon)

- [ ] **Add photos** to the screensaver from the Screensaver tab, then **Preview on TV** to check how they look.
- [ ] **Keep the TV reachable**: on the TV, look under Settings → System → Power for "Network standby", "Wake on Wi-Fi" or "Quick start" and turn it on.
- [ ] **Reserve the TV's IP** in the router's DHCP settings so it never changes.
- [ ] **Push to GitHub** (private repo).

## Phone app (mobile/)

- [x] Flutter app for Android + iPhone with its own ADB client (2026-11-20)
- [x] First-run setup guide: brand → Developer mode → connect → screensaver → feature tour
- [x] HEIC conversion and resizing before upload (done in the phone app)
- [x] Live test against the TCL with the owner at the TV
- [x] Install and test on a real Android phone and iPhone
- [ ] Release signing key for Android. TestFlight / App Store if a paid Apple account is added.
- [x] Clear message when the TV is on but its ADB port is closed: "turn USB debugging off and on" (phone app + server, 2026-11-21)
- [x] Android TV Remote protocol: pair with a code on the TV, so the remote and app switching work **without Developer mode** (2026-11-21)
- [x] Live-test pairing on the TCL from a phone (confirmed by the owner, 2026-11-21)
- [x] Typing without Developer mode: sent as key presses over the remote link (lower-case letters, digits, common symbols)
- [ ] Full typing over the remote protocol (IME messages): capitals and all characters
- [ ] Encrypted "Wireless debugging" (TLS + pairing code) for TVs without port 5555
- [x] App icon: phone + TV, from `mobile/assets/icon/` via `tool/make_icons.sh` (2026-11-21)
- [ ] Splash screen
- [ ] Phone version of the laptop's Wake / network-standby hint

### Planned for today (2026-11-21)
- [x] Swipe touchpad on the Remote tab (#4)
- [x] Voice search via the keyboard's 🎤, and typing now also works without Developer mode (#6)
- [x] Live screen preview of what's on the TV (#8). Needs Developer mode; streaming apps block it.
- [x] Open links on the TV: Android Share menu, plus an "Open a link" button that pastes from the clipboard (#10)
- [ ] iPhone Share-sheet extension, so iPhone can also use Share → Connect TV
- [x] Sleep timer (runs on the TV with Developer mode, in the app without it) and app bedtime (a script on the TV) (#11)

### Next phase
- [x] Screensaver albums and schedules (#12, 2026-11-21)
- [x] Sync a whole phone album (#13): link a phone album to a TV album; new photos go to the TV and removed ones are removed. It runs on connect and on "Sync now" (2026-11-21).
- [ ] **Album sync: test on a real phone.** The Samsung had "limited" photo access; allow all photos, then link a small album. Paused by the owner on 2026-11-21.
- [ ] Reinstall the updated screensaver app on the TV, then check albums, schedules, date/weather and slide on screen
- [ ] Check the Remote tab's **Assistant** and **Recent** buttons on the TCL. If they do nothing, remove them or swap them for something useful (e.g. a Netflix shortcut).
- [ ] Album sync in the background (needs a background-task package) and syncing straight from the Google Photos cloud (needs a Google Cloud project with OAuth)
- [x] Overlays: date, weather (Open-Meteo), captions (#14)
- [x] Transition styles (fade, slide, cut) and per-video sound (#15)

### Ideas from the 2026-11-22 review
- [x] "On this day" screensaver mode: photos taken on today's date in earlier years, captioned "N years ago today"
- [ ] Number keys and channel up/down
- [ ] Home-screen widget and lock-screen controls
- [ ] Wake the TV over Wi-Fi (check the TCL's network-standby support)
- [ ] Show which input the TV is on (HDMI 1/2…), with one-tap switching
- [ ] TV storage: show how much space the screensaver uses; clear caches
- [ ] Photo frame mode: start the slideshow now with one tap
- [ ] Music during the slideshow
- [ ] Photos sent at the TV's exact resolution; blurred background for portrait photos
- [ ] Multiple TVs in one app; easy family setup with an optional kids mode
- [ ] One clear status line (Remote ✓, Developer mode ✓)
- [ ] Faster Screensaver tab (cached thumbnails, background loading)
- [ ] Dark-mode polish and larger buttons option
- [ ] New app icon (optional). The current phone-and-TV icon is kept. Mock-ups from 2026-11-22: the favourites were "TV-pad" (D-pad arrows on a TV showing a photo) and "Ring with signal".
- [ ] Android release signing key; iPhone TestFlight; GitHub Actions APK builds; server tests with a fake TV

## Known issues

- The server forgets the active connection when it restarts. You have to click **Connect** again.
- When the TV goes into standby it drops off Wi-Fi, and Connect TV can't wake it.
- macOS can block local network access for VS Code / Terminal ("No route to host"). Fix it under System Settings → Privacy & Security → Local Network. Idea: show this hint in the UI when a connect fails that way.
- HEIC photos (iPhone) are rejected. They have to be exported as JPEG first.
- A Google TV system update may reset the screensaver to Google's default. Click **Set as screensaver** again if that happens.

## Ideas for later

### Connection
- [x] **Auto-reconnect**: reconnect to the last TV on server start, and retry in the background when it comes back online (server every 20 s; phone app every 8 s while open, 2026-11-22).
- [ ] **Wake the TV**: send Wake-on-LAN, or use the TV's network standby, so Power on works from the laptop.
- [ ] **No developer mode needed**: use the Android TV Remote protocol (the one the Google TV phone app uses) as an alternative to adb.
- [x] **Multiple TVs** (phone app): save several TVs and switch between them (tap the TV name at the top, or Settings → Other TVs).
- [ ] Send the same command to all TVs at once.

### Remote and apps
- [ ] **Phone remote**: a mobile layout installable as a home-screen app (PWA), with a PIN or login before the server is opened to the network.
- [x] **Live screen preview**: show a screenshot of what's on the TV (`adb exec-out screencap`).
- [x] **Mirror the phone**: Android hands over to the phone's Chromecast screen casting. iPhone: via an AirPlay receiver app on the TV (AirScreen), opened from the app.
- [x] **Deep links**: open a specific YouTube video, Netflix title, or URL directly (`am start -a VIEW -d <url>`).
- [x] **Favourites**: choose and reorder the quick-switch apps in the UI instead of editing `devices.json` (phone: row of app buttons on the Remote tab).
- [x] **Volume slider** (presses volume keys to reach the level; Android 11 can't set a number directly).
- [ ] **Scheduled on/off**, e.g. TV off at 11 pm every night. (Sleep timer: done.)
- [ ] **Keyboard shortcuts for apps** (for example 1 = Netflix, 2 = Prime Video).

### Screensaver
- [ ] **HEIC support**: convert to JPEG on upload (macOS `sips`).
- [ ] **Resize before upload** so large photos send faster and use less TV storage.
- [x] **Albums**: several named albums, with one active at a time.
- [x] **Schedules**: different albums by time of day or by season or holiday.
- [ ] **Folder sync**: watch a folder on the Mac (or a Google Photos / iCloud export) and keep the TV in sync.
- [x] **More overlays**: date, weather, and a photo caption.
- [x] **Transition choices**: fade, slide, or none, plus a per-video "play with sound" option.
- [ ] **Reorder photos** by drag and drop when shuffle is off.

### Project
- [ ] `package.json` with `npm start`, and a launchd service so the server starts with the Mac.
- [ ] GitHub Actions workflow that builds the APK and attaches it to releases.
- [ ] Basic tests for the API routes, using a fake `adb`.
- [ ] Screenshots in the README.
