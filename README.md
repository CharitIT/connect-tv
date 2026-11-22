# Connect TV

Control an Android TV / Google TV from your laptop over Wi-Fi, and show your own photos and videos as the TV's screensaver.

- **Remote**: D-pad, OK, Back, Home, volume, power, playback keys, and typing into search boxes (or use your keyboard).
- **Apps**: one-click switching to Netflix, Prime Video, Disney+, YouTube, and every other app installed on the TV.
- **Custom screensaver**: drag photos/videos into the browser; they are sent to a small screensaver app on the TV with crossfades, slow zoom, clock, shuffle, and video support.

There are two ways to use it:
- **Phone app (Android + iPhone)**: in [`mobile/`](mobile/README.md). It controls the TV directly, with no computer needed, and has a step-by-step setup guide.
- **Laptop version**: described below.

The laptop version is a zero-dependency Node.js server (`server.js`) that talks to the TV with `adb`, plus a single-page web UI (`web/index.html`) and a tiny Android screensaver app (`tv-screensaver/`).

Tested on: a **TCL Google TV** (Android 11).

## Requirements

- macOS (Linux should also work)
- [Node.js](https://nodejs.org) 18+
- Android SDK with **platform-tools** (for `adb`) and **build-tools** + a **platform** (for building the screensaver app). Installing Android Studio gives you all of these plus a JDK.
- The TV and the laptop on the same Wi-Fi network

`adb` is found automatically in `~/Library/Android/sdk/platform-tools`, `$ANDROID_HOME`, or Homebrew. Override with `ADB=/path/to/adb`.

## Quick start

```bash
# 1. Build the screensaver app (one time, or after changing its code)
./tv-screensaver/build.sh

# 2. Start the server
node server.js
```

Open **http://localhost:8765**.

Options: `PORT=9000 node server.js` changes the port. The server listens on `127.0.0.1` only by default (see the security note below).

## One-time TV setup (TCL Google TV)

1. **Settings → System → About**: select **Android TV OS build** and press OK 7 times, until it says "You are now a developer".
2. **Settings → System → Developer options**: turn on **USB debugging**.
3. **Settings → Network & Internet →** your Wi-Fi: note the **IP address**.
4. In Connect TV, open the **Connect** tab, pick **TCL (Google TV)**, enter the IP, and click **Connect**.
5. On the TV, tick **Always allow from this computer** and choose **Allow**.

Setup steps for other brands (Sony, Hisense, Philips, Xiaomi, Chromecast, NVIDIA Shield) are shown in the app and live in `devices.json`.

## Using the screensaver

1. **Screensaver** tab → **Install on TV** (one time).
2. Drag photos or videos into the drop zone (JPG, PNG, WEBP, GIF, MP4, MOV, MKV, WEBM).
3. Adjust the settings → **Save settings**.
4. **Preview on TV**, then **Set as screensaver** with the idle time in minutes.
5. **Restore original** puts back the TV's own screensaver.

Google TV hides third-party screensavers from its settings menu, so Connect TV sets it directly with `adb`.

## Troubleshooting

| Problem | Fix |
|---|---|
| "Could not reach the TV" or the TV shows as disconnected | The TV is probably off or in standby (TCL TVs turn Wi-Fi off in standby). Turn it on with its own remote, wait about 20 s, then click **Reconnect**. |
| "No route to host" even though the TV is on (the router answers, but no other device does) | macOS is blocking local network access. **System Settings → Privacy & Security → Local Network** → turn on Visual Studio Code / Terminal (whichever runs the server), then quit and reopen that app. |
| Still can't connect | Turn USB debugging off and on again, or restart the TV. Check that the IP address hasn't changed. |
| "unauthorized" | Accept the "Allow USB debugging?" prompt on the TV, then click **Reconnect**. |
| iPhone photos (HEIC) don't upload | Export them as JPEG first (Photos app → File → Export). |
| After restarting the server it says "Not connected" | Click **Connect** under Saved TVs. The current connection is not remembered across server restarts yet. |

## Project layout

```
server.js                 Node server: adb control, REST API, static files
devices.json              TV setup guides per brand + known app names/colors
web/index.html            The whole web UI (no build step)
tv-screensaver/           Android screensaver app (DreamService)
  build.sh                Builds build/tv-screensaver.apk with SDK tools (no Gradle)
  AndroidManifest.xml
  src/com/connecttv/screensaver/
    Slideshow.java        Shared slideshow view (images, GIFs, videos, clock)
    PhotoDream.java       The screensaver service
    PreviewActivity.java  Launchable preview
data/                     Local only, not in git: saved TVs and uploaded media
```

## Security note

The server has **no login**. It binds to `127.0.0.1` so only your own laptop can use it. Do not set `HOST=0.0.0.0` on a shared network until authentication is added (see [ROADMAP.md](ROADMAP.md)). Anyone who can reach the server can control the paired TV.

## Working with AI agents

Instructions for any AI coding agent are in **[AGENTS.md](AGENTS.md)**: architecture, commands, the API, conventions, and safety rules for the real TV. Put your own TV's IP address and other machine-specific notes in a `LOCAL.md` file (git-ignored).

Every change is recorded in **[DEVLOG.md](DEVLOG.md)**.

## Roadmap

See [ROADMAP.md](ROADMAP.md) for next steps and ideas, and [DEVLOG.md](DEVLOG.md) for the history.
