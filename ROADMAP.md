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
- [ ] Live test against the TCL with the owner at the TV
- [ ] Install and test on a real Android phone and iPhone
- [ ] Release signing key for Android. TestFlight / App Store if a paid Apple account is added.
- [ ] Encrypted "Wireless debugging" (TLS + pairing code) for TVs without port 5555
- [x] App icon: phone + TV, from `mobile/assets/icon/` via `tool/make_icons.sh` (2026-11-21)
- [ ] Splash screen
- [ ] Phone version of the laptop's Wake / network-standby hint

## Known issues

- The server forgets the active connection when it restarts. You have to click **Connect** again.
- When the TV goes into standby it drops off Wi-Fi, and Connect TV can't wake it.
- macOS can block local network access for VS Code / Terminal ("No route to host"). Fix it under System Settings → Privacy & Security → Local Network. Idea: show this hint in the UI when a connect fails that way.
- HEIC photos (iPhone) are rejected. They have to be exported as JPEG first.
- A Google TV system update may reset the screensaver to Google's default. Click **Set as screensaver** again if that happens.

## Ideas for later

### Connection
- [ ] **Auto-reconnect**: reconnect to the last TV on server start, and retry in the background when it comes back online.
- [ ] **Wake the TV**: send Wake-on-LAN, or use the TV's network standby, so Power on works from the laptop.
- [ ] **No developer mode needed**: use the Android TV Remote protocol (the one the Google TV phone app uses) as an alternative to adb.
- [ ] **Multiple TVs**: switch between saved TVs, or send the same command to all of them.

### Remote and apps
- [ ] **Phone remote**: a mobile layout installable as a home-screen app (PWA), with a PIN or login before the server is opened to the network.
- [ ] **Live screen preview**: show a screenshot of what's on the TV (`adb exec-out screencap`).
- [ ] **Deep links**: open a specific YouTube video, Netflix title, or URL directly (`am start -a VIEW -d <url>`).
- [ ] **Favourites**: choose and reorder the quick-switch apps in the UI instead of editing `devices.json`.
- [ ] **Volume slider, sleep timer, and scheduled on/off.**
- [ ] **Keyboard shortcuts for apps** (for example 1 = Netflix, 2 = Prime Video).

### Screensaver
- [ ] **HEIC support**: convert to JPEG on upload (macOS `sips`).
- [ ] **Resize before upload** so large photos send faster and use less TV storage.
- [ ] **Albums**: several named albums, with one active at a time.
- [ ] **Schedules**: different albums by time of day or by season or holiday.
- [ ] **Folder sync**: watch a folder on the Mac (or a Google Photos / iCloud export) and keep the TV in sync.
- [ ] **More overlays**: date, weather, and a photo caption or filename.
- [ ] **Transition choices**: fade, slide, or none, plus a per-video "play with sound" option.
- [ ] **Reorder photos** by drag and drop when shuffle is off.

### Project
- [ ] `package.json` with `npm start`, and a launchd service so the server starts with the Mac.
- [ ] GitHub Actions workflow that builds the APK and attaches it to releases.
- [ ] Basic tests for the API routes, using a fake `adb`.
- [ ] Screenshots in the README.
