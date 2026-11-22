#!/usr/bin/env node
// Connect TV — laptop server. Controls an Android / Google TV over Wi-Fi using ADB.
// No npm dependencies: only Node built-ins + the `adb` binary from the Android SDK.

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const net = require('net');
const { execFile } = require('child_process');

const ROOT = __dirname;
const WEB = path.join(ROOT, 'web');
const DATA = path.join(ROOT, 'data');
const MEDIA = path.join(DATA, 'media');
const TVS_FILE = path.join(DATA, 'tvs.json');
const APK = path.join(ROOT, 'tv-screensaver', 'build', 'tv-screensaver.apk');
const PROFILES = JSON.parse(fs.readFileSync(path.join(ROOT, 'devices.json'), 'utf8'));

const SS_PKG = 'com.connecttv.screensaver';
const SS_DREAM = `${SS_PKG}/.PhotoDream`;
const SS_PREVIEW = `${SS_PKG}/.PreviewActivity`;
const SS_DIR_APP = `/sdcard/Android/data/${SS_PKG}/files/screensaver`;
const SS_DIR_PUBLIC = '/sdcard/Pictures/TVScreensaver';
const MEDIA_EXT = /\.(jpe?g|png|webp|gif|bmp|mp4|m4v|webm|mkv|mov)$/i;
const DEFAULT_CONFIG = {
  intervalSec: 12, shuffle: true, showClock: true, fit: 'cover', motion: true, muteVideo: true,
  showDate: false, transition: 'fade', album: '', schedule: [], soundOn: [], captions: {}, weather: null,
  onThisDay: false, dates: {},
};
// Album names: letters, digits, spaces, "_" and "-". "" is the Main album (the screensaver folder itself).
const ALBUM_RE = /^[A-Za-z0-9][A-Za-z0-9 _-]{0,39}$/;

const PORT = Number(process.env.PORT) || 8765;
const HOST = process.env.HOST || '127.0.0.1';

fs.mkdirSync(MEDIA, { recursive: true });

// ---------- adb helpers ----------

function findAdb() {
  const candidates = [
    process.env.ADB,
    process.env.ANDROID_HOME && path.join(process.env.ANDROID_HOME, 'platform-tools', 'adb'),
    process.env.ANDROID_SDK_ROOT && path.join(process.env.ANDROID_SDK_ROOT, 'platform-tools', 'adb'),
    path.join(os.homedir(), 'Library', 'Android', 'sdk', 'platform-tools', 'adb'),
    path.join(os.homedir(), 'Android', 'Sdk', 'platform-tools', 'adb'),
    '/opt/homebrew/bin/adb',
    '/usr/local/bin/adb',
  ].filter(Boolean);
  return candidates.find((p) => fs.existsSync(p)) || null;
}
const ADB = findAdb();

function run(args, timeout = 15000) {
  return new Promise((resolve) => {
    if (!ADB) return resolve({ code: 127, stdout: '', stderr: 'adb not found' });
    execFile(ADB, args, { timeout, maxBuffer: 16 * 1024 * 1024 }, (err, stdout, stderr) => {
      resolve({ code: err ? (typeof err.code === 'number' ? err.code : 1) : 0, stdout: String(stdout), stderr: String(stderr) });
    });
  });
}

// Quote a value for the TV's remote shell.
const q = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;

let serial = null; // e.g. "192.168.1.40:5555"
const ssDirCache = {}; // serial -> remote screensaver dir

function needDevice() {
  if (!serial) throw httpError(409, 'No TV connected. Connect to your TV first.');
  return serial;
}
async function sh(cmd, timeout) {
  return run(['-s', needDevice(), 'shell', cmd], timeout);
}
async function deviceState(s) {
  const r = await run(['-s', s, 'get-state'], 5000);
  if (r.code === 0) return r.stdout.trim(); // "device"
  const msg = (r.stderr + r.stdout).toLowerCase();
  if (msg.includes('unauthorized')) return 'unauthorized';
  if (msg.includes('offline')) return 'offline';
  return 'disconnected';
}
async function deviceInfo(s) {
  const r = await run(['-s', s, 'shell',
    'getprop ro.product.manufacturer; getprop ro.product.model; getprop ro.build.version.release; getprop ro.build.version.sdk; getprop ro.product.device'], 8000);
  const [manufacturer, model, android, sdk, device] = r.stdout.split('\n').map((x) => x.trim());
  return { manufacturer, model, android, sdk: Number(sdk) || null, device };
}

// ---------- saved TVs ----------

function loadTvs() {
  try { return JSON.parse(fs.readFileSync(TVS_FILE, 'utf8')); } catch { return []; }
}
function saveTvs(list) { fs.writeFileSync(TVS_FILE, JSON.stringify(list, null, 2)); }
function upsertTv(address, patch) {
  const list = loadTvs();
  let tv = list.find((t) => t.address === address);
  if (!tv) { tv = { address }; list.push(tv); }
  Object.assign(tv, patch);
  saveTvs(list);
  return tv;
}
function currentTv() { return loadTvs().find((t) => t.address === serial) || null; }

// ---------- network discovery ----------

function localSubnets() {
  const out = [];
  for (const ifs of Object.values(os.networkInterfaces())) {
    for (const i of ifs || []) {
      if (i.family === 'IPv4' && !i.internal && /^(10|172|192)\./.test(i.address)) {
        out.push(i.address.split('.').slice(0, 3).join('.'));
      }
    }
  }
  return [...new Set(out)];
}
// Ports a TV answers on even without Developer mode: Android TV Remote (6466/6467) and Google Cast (8008/8009).
const TV_SERVICE_PORTS = [6466, 6467, 8009, 8008];
const ADB_OFF_MESSAGE = 'Your TV is on, but it isn\'t accepting connections right now. This usually happens after the TV restarts. ' +
  'On the TV, open Settings → System → Developer options, turn USB debugging off and then on again, then click Connect.';

function probe(ip, port, timeout = 450) {
  return new Promise((resolve) => {
    const s = net.connect({ host: ip, port });
    const done = (ok) => { s.destroy(); resolve(ok); };
    s.setTimeout(timeout, () => done(false));
    s.once('connect', () => done(true));
    s.once('error', () => done(false));
  });
}
async function discover() {
  const ips = [];
  for (const net24 of localSubnets()) for (let i = 1; i < 255; i++) ips.push(`${net24}.${i}`);
  const found = [];
  let idx = 0;
  const worker = async () => {
    while (idx < ips.length) {
      const ip = ips[idx++];
      if (await probe(ip, 5555)) found.push(ip);
    }
  };
  await Promise.all(Array.from({ length: 96 }, worker));
  return found.sort((a, b) => Number(a.split('.')[3]) - Number(b.split('.')[3]));
}

// ---------- remote keys ----------

const KEYS = {
  up: 'KEYCODE_DPAD_UP', down: 'KEYCODE_DPAD_DOWN', left: 'KEYCODE_DPAD_LEFT', right: 'KEYCODE_DPAD_RIGHT',
  ok: 'KEYCODE_DPAD_CENTER', back: 'KEYCODE_BACK', home: 'KEYCODE_HOME', menu: 'KEYCODE_MENU',
  volup: 'KEYCODE_VOLUME_UP', voldown: 'KEYCODE_VOLUME_DOWN', mute: 'KEYCODE_VOLUME_MUTE',
  power: 'KEYCODE_POWER', wake: 'KEYCODE_WAKEUP', sleep: 'KEYCODE_SLEEP',
  playpause: 'KEYCODE_MEDIA_PLAY_PAUSE', rewind: 'KEYCODE_MEDIA_REWIND', forward: 'KEYCODE_MEDIA_FAST_FORWARD',
  next: 'KEYCODE_MEDIA_NEXT', prev: 'KEYCODE_MEDIA_PREVIOUS', stop: 'KEYCODE_MEDIA_STOP',
  chup: 'KEYCODE_CHANNEL_UP', chdown: 'KEYCODE_CHANNEL_DOWN', input: 'KEYCODE_TV_INPUT',
  search: 'KEYCODE_SEARCH', assistant: 'KEYCODE_ASSIST', settings: 'KEYCODE_SETTINGS',
  recents: 'KEYCODE_APP_SWITCH', del: 'KEYCODE_DEL', enter: 'KEYCODE_ENTER', captions: 'KEYCODE_CAPTIONS',
};

// ---------- apps ----------

function prettyPkg(pkg) {
  const skip = new Set(['com', 'org', 'net', 'tv', 'android', 'app', 'apps', 'google', 'in', 'androidtv', 'atv', 'leanback']);
  const parts = pkg.split('.').filter((p) => !skip.has(p));
  const name = parts[parts.length - 1] || pkg;
  return name.charAt(0).toUpperCase() + name.slice(1);
}
async function listApps() {
  const pkgs = new Set();
  for (const cat of ['android.intent.category.LEANBACK_LAUNCHER', 'android.intent.category.LAUNCHER']) {
    const r = await sh(`cmd package query-activities -a android.intent.action.MAIN -c ${cat}`, 20000);
    for (const m of r.stdout.matchAll(/packageName=([A-Za-z0-9_.]+)/g)) pkgs.add(m[1]);
    for (const m of r.stdout.matchAll(/^\s*([A-Za-z0-9_.]+)\/[A-Za-z0-9_.$]+\s*$/gm)) pkgs.add(m[1]);
    if (pkgs.size && cat.includes('LEANBACK')) {
      // Also include phone-style launchers only if leanback gave very little.
      if (pkgs.size > 5) break;
    }
  }
  if (!pkgs.size) {
    const r = await sh('pm list packages -3');
    for (const m of r.stdout.matchAll(/package:([A-Za-z0-9_.]+)/g)) pkgs.add(m[1]);
  }
  return [...pkgs].map((pkg) => {
    const known = PROFILES.apps[pkg];
    return { pkg, name: known ? known.name : prettyPkg(pkg), color: known ? known.color : null, known: !!known };
  }).sort((a, b) => (b.known - a.known) || a.name.localeCompare(b.name));
}
async function launch(pkg) {
  let r = await sh(`monkey -p ${q(pkg)} -c android.intent.category.LEANBACK_LAUNCHER 1`);
  if (/No activities found|aborted/i.test(r.stdout + r.stderr)) {
    r = await sh(`monkey -p ${q(pkg)} -c android.intent.category.LAUNCHER 1`);
  }
  if (/No activities found|aborted/i.test(r.stdout + r.stderr)) {
    throw httpError(404, `${PROFILES.apps[pkg]?.name || pkg} is not installed on this TV (or can't be launched).`);
  }
}
async function currentApp() {
  const r = await sh("dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity|ResumedActivity:' | head -n 1");
  const m = r.stdout.match(/ ([A-Za-z0-9_.]+)\/[A-Za-z0-9_.$]+/);
  if (!m) return null;
  const pkg = m[1];
  return { pkg, name: PROFILES.apps[pkg]?.name || prettyPkg(pkg) };
}

// ---------- screensaver ----------

async function isInstalled(pkg) {
  const r = await sh(`pm path ${q(pkg)}`);
  return r.stdout.includes('package:');
}
async function screensaverDir() {
  const s = needDevice();
  if (ssDirCache[s]) return ssDirCache[s];
  // Preferred: the app's private external folder (no permissions needed by the app).
  let r = await sh(`mkdir -p ${q(SS_DIR_APP)} && touch ${q(SS_DIR_APP + '/.probe')} && echo OK`);
  if (r.stdout.includes('OK')) return (ssDirCache[s] = SS_DIR_APP);
  // Fallback: a public Pictures folder + grant read permission to the screensaver app.
  await sh(`mkdir -p ${q(SS_DIR_PUBLIC)}`);
  await grantMediaPermissions();
  return (ssDirCache[s] = SS_DIR_PUBLIC);
}
async function grantMediaPermissions() {
  for (const p of ['android.permission.READ_EXTERNAL_STORAGE', 'android.permission.READ_MEDIA_IMAGES', 'android.permission.READ_MEDIA_VIDEO']) {
    await sh(`pm grant ${SS_PKG} ${p} 2>/dev/null`);
  }
}
function albumName(a) {
  const name = String(a || '').trim();
  if (name && !ALBUM_RE.test(name)) throw httpError(400, 'Album names can use letters, numbers, spaces, - and _.');
  return name;
}
async function albumDir(album) {
  const dir = await screensaverDir();
  return album ? `${dir}/albums/${album}` : dir;
}
async function listAlbums() {
  const dir = await screensaverDir();
  const r = await sh(`ls -1p ${q(dir + '/albums')} 2>/dev/null`);
  return r.stdout.split('\n').map((x) => x.trim()).filter((x) => x.endsWith('/')).map((x) => x.slice(0, -1))
    .filter((x) => ALBUM_RE.test(x)).sort((a, b) => a.localeCompare(b));
}
// The TV's config.json is the source of truth: the phone app edits it too.
async function readTvConfig() {
  const dir = await screensaverDir();
  const r = await sh(`cat ${q(dir + '/config.json')} 2>/dev/null`);
  try { const j = JSON.parse(r.stdout); return j && typeof j === 'object' ? j : null; } catch { return null; }
}
async function listScreensaverFiles(album = '') {
  const dir = await albumDir(album);
  const r = await sh(`ls -1 ${q(dir)} 2>/dev/null`);
  return r.stdout.split('\n').map((x) => x.trim()).filter((x) => MEDIA_EXT.test(x)).map((name) => ({
    name,
    video: /\.(mp4|m4v|webm|mkv|mov)$/i.test(name),
    thumb: fs.existsSync(path.join(MEDIA, name)) ? `/media/${encodeURIComponent(name)}` : null,
  }));
}
function safeName(name) {
  const base = path.basename(String(name || '')).replace(/[^A-Za-z0-9._-]+/g, '_').replace(/^\.+/, '');
  if (!base || !MEDIA_EXT.test(base)) throw httpError(400, 'Only images (jpg, png, webp, gif, bmp) and videos (mp4, webm, mkv, mov) are supported.');
  return base;
}
async function pushConfig(cfg) {
  const dir = await screensaverDir();
  const tmp = path.join(DATA, `config-${Date.now()}.json`);
  fs.writeFileSync(tmp, JSON.stringify(cfg, null, 2));
  const r = await run(['-s', needDevice(), 'push', tmp, `${dir}/config.json`], 30000);
  fs.unlinkSync(tmp);
  if (r.code !== 0) throw httpError(500, 'Could not save settings to the TV: ' + (r.stderr || r.stdout));
}

// ---------- http plumbing ----------

function httpError(status, message) { const e = new Error(message); e.status = status; return e; }
function send(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(body));
}
function readJson(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (c) => { data += c; if (data.length > 1e6) req.destroy(); });
    req.on('end', () => { try { resolve(data ? JSON.parse(data) : {}); } catch { reject(httpError(400, 'Bad JSON')); } });
    req.on('error', reject);
  });
}
const STATIC_TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp', '.gif': 'image/gif', '.bmp': 'image/bmp',
  '.mp4': 'video/mp4', '.m4v': 'video/mp4', '.webm': 'video/webm', '.mov': 'video/quicktime', '.mkv': 'video/x-matroska' };
function serveFile(res, file) {
  fs.stat(file, (err, st) => {
    if (err || !st.isFile()) { res.writeHead(404); return res.end('Not found'); }
    res.writeHead(200, { 'Content-Type': STATIC_TYPES[path.extname(file).toLowerCase()] || 'application/octet-stream', 'Content-Length': st.size });
    fs.createReadStream(file).pipe(res);
  });
}

// ---------- routes ----------

const routes = {
  'GET /api/state': async () => {
    const tvs = loadTvs();
    let state = null, info = null;
    if (serial) {
      state = await deviceState(serial);
      if (state === 'device') info = currentTv()?.info || await deviceInfo(serial);
    }
    return { adb: ADB, apkBuilt: fs.existsSync(APK), connected: serial, state, info, tv: currentTv(), tvs };
  },

  'GET /api/profiles': async () => PROFILES,

  'GET /api/discover': async () => ({ subnets: localSubnets(), found: await discover() }),

  'POST /api/connect': async (body) => {
    userDisconnected = false;
    let address = String(body.address || '').trim();
    if (!/^[A-Za-z0-9.-]+(:\d{2,5})?$/.test(address)) throw httpError(400, 'Enter the TV IP address, e.g. 192.168.1.40');
    if (!address.includes(':')) address += ':5555';
    const r = await run(['connect', address], 12000);
    const out = (r.stdout + r.stderr).trim();
    if (/cannot|failed|refused|unable|no route|timed out/i.test(out)) {
      // The TV is on (its remote/Cast ports answer) but adb isn't listening: usually after a restart.
      const host = address.split(':')[0];
      const on = (await Promise.all(TV_SERVICE_PORTS.map((p) => probe(host, p, 1500)))).some(Boolean);
      if (on) throw httpError(502, ADB_OFF_MESSAGE);
      throw httpError(502, `Could not reach the TV at ${address}. Check that it is on, on the same Wi-Fi, and USB debugging is enabled. (adb: ${out})`);
    }
    serial = address;
    // Wait briefly for the "Allow USB debugging?" prompt to be accepted.
    let state = await deviceState(address);
    for (let i = 0; i < 4 && state !== 'device'; i++) { await new Promise((r2) => setTimeout(r2, 1000)); state = await deviceState(address); }
    const patch = { brand: body.brand || null, model: body.model || null, profile: body.profile || null, name: body.name || null, lastConnected: new Date().toISOString() };
    for (const k of Object.keys(patch)) if (patch[k] == null) delete patch[k];
    if (state === 'device') patch.info = await deviceInfo(address);
    const tv = upsertTv(address, patch);
    return { connected: address, state, tv };
  },

  'POST /api/pair': async (body) => {
    const address = String(body.address || '').trim();
    const code = String(body.code || '').trim();
    if (!/^[A-Za-z0-9.-]+:\d{2,5}$/.test(address) || !/^\d{6}$/.test(code)) throw httpError(400, 'Enter the pairing address (IP:port) and 6-digit code shown on the TV.');
    const r = await run(['pair', address, code], 20000);
    const out = (r.stdout + r.stderr).trim();
    if (!/success/i.test(out)) throw httpError(502, 'Pairing failed: ' + out);
    return { ok: true, message: out };
  },

  'POST /api/disconnect': async () => {
    if (serial) await run(['disconnect', serial], 5000);
    serial = null;
    userDisconnected = true; // don't reconnect by ourselves until the user connects again
    return { ok: true };
  },

  'POST /api/forget': async (body) => {
    saveTvs(loadTvs().filter((t) => t.address !== body.address));
    return { ok: true };
  },

  'POST /api/key': async (body) => {
    let code = KEYS[body.key] || body.key;
    if (!/^(KEYCODE_[A-Z0-9_]+|\d{1,3})$/.test(String(code))) throw httpError(400, 'Unknown key');
    const longpress = body.long ? '--longpress ' : '';
    await sh(`input keyevent ${longpress}${code}`);
    return { ok: true };
  },

  'POST /api/text': async (body) => {
    const text = String(body.text || '');
    if (!text) return { ok: true };
    // `input text` uses %s for spaces; quote the rest for the remote shell.
    await sh(`input text ${q(text.replace(/%/g, '\\%').replace(/ /g, '%s'))}`);
    return { ok: true };
  },

  'GET /api/apps': async () => ({ apps: await listApps() }),

  'POST /api/launch': async (body) => {
    const pkg = String(body.pkg || '');
    if (!/^[A-Za-z0-9_.]+$/.test(pkg)) throw httpError(400, 'Bad package name');
    await launch(pkg);
    return { ok: true };
  },

  'GET /api/current': async () => ({ app: await currentApp() }),

  // The TV's volume (media stream): { level, max, muted }.
  'GET /api/volume': async () => {
    const out = (await sh("dumpsys audio | grep -A7 '^- STREAM_MUSIC'")).stdout;
    const level = Number((out.match(/streamVolume:\s*(\d+)/) || [])[1]);
    const max = Number((out.match(/Max:\s*(\d+)/) || [])[1]);
    if (!Number.isFinite(level) || !(max > 0)) return { level: null, max: null, muted: null };
    return { level, max, muted: /Muted:\s*true/.test(out) };
  },

  // Open a web link on the TV (YouTube, Netflix… links open in their apps).
  'POST /api/open': async (body) => {
    const url = String(body.url || '').trim();
    if (!/^https?:\/\/[^\s'"<>]+$/.test(url)) throw httpError(400, 'That isn\'t a web link. Links start with https://');
    const r = await sh(`am start -a android.intent.action.VIEW -d ${q(url)}`);
    if (/Error|unable to resolve/i.test(r.stdout + r.stderr)) throw httpError(400, 'The TV has no app that can open this link.');
    return { ok: true };
  },

  // Sleep timer. It runs on the TV, so the laptop can be closed. The file holds "pid seconds".
  'POST /api/sleep': async (body) => {
    const P = '/data/local/tmp/connecttv-sleep.pid';
    await sh(`[ -f ${P} ] && kill $(cut -d" " -f1 ${P}) 2>/dev/null; rm -f ${P}`);
    const minutes = Math.round(Number(body.minutes) || 0);
    if (minutes <= 0) return { ok: true, secondsLeft: null };
    const secs = Math.min(Math.max(minutes, 1), 600) * 60;
    await sh(`nohup sh -c 'echo $$ ${secs} > ${P}; sleep ${secs}; rm -f ${P}; input keyevent KEYCODE_SLEEP' >/dev/null 2>&1 &`);
    return { ok: true, secondsLeft: secs };
  },
  'GET /api/sleep': async () => {
    const P = '/data/local/tmp/connecttv-sleep.pid';
    const r = await sh(`[ -f ${P} ] && kill -0 $(cut -d" " -f1 ${P}) 2>/dev/null && echo $(cut -d" " -f2 ${P}) $(stat -c %Y ${P}) $(date +%s)`);
    const n = r.stdout.trim().split(/\s+/).map(Number);
    const left = n.length === 3 && n.every(Number.isFinite) ? n[0] + n[1] - n[2] : 0;
    return { secondsLeft: left > 0 ? left : null };
  },

  'GET /api/screensaver/status': async (_b, url) => {
    const album = albumName(url.searchParams.get('album'));
    const installed = await isInstalled(SS_PKG);
    const comp = (await sh('settings get secure screensaver_components')).stdout.trim();
    const enabled = (await sh('settings get secure screensaver_enabled')).stdout.trim();
    const timeoutMs = Number((await sh('settings get system screen_off_timeout')).stdout.trim()) || null;
    const files = installed ? await listScreensaverFiles(album) : [];
    const albums = installed ? await listAlbums() : [];
    const tvConfig = installed ? await readTvConfig() : null;
    const tv = currentTv();
    return {
      album, albums,
      installed, apkBuilt: fs.existsSync(APK),
      active: comp.includes(SS_PKG), components: comp, enabled,
      timeoutMin: timeoutMs ? Math.round(timeoutMs / 60000) : null,
      files, config: { ...DEFAULT_CONFIG, ...(tvConfig || tv?.screensaverConfig || {}) },
    };
  },

  'POST /api/screensaver/install': async () => {
    if (!fs.existsSync(APK)) throw httpError(409, 'The screensaver app has not been built yet. Run ./tv-screensaver/build.sh on the laptop first.');
    const r = await run(['-s', needDevice(), 'install', '-r', '-g', APK], 180000);
    if (!/Success/.test(r.stdout)) throw httpError(500, 'Install failed: ' + (r.stdout + r.stderr).trim());
    delete ssDirCache[serial];
    await grantMediaPermissions();
    // Launch once so Android creates the app's storage folder, then go back home.
    await sh(`am start -n ${SS_PREVIEW}`);
    await new Promise((r2) => setTimeout(r2, 1500));
    await sh('input keyevent KEYCODE_HOME');
    const tv = currentTv();
    // Keep the settings already on the TV (e.g. after a reinstall).
    await pushConfig({ ...DEFAULT_CONFIG, ...(tv?.screensaverConfig || {}), ...((await readTvConfig()) || {}) });
    return { ok: true };
  },

  // Change only the keys that were sent; everything else on the TV stays as it is.
  'POST /api/screensaver/config': async (body) => {
    const tv = currentTv();
    const cfg = { ...DEFAULT_CONFIG, ...(tv?.screensaverConfig || {}), ...((await readTvConfig()) || {}) };
    const has = (k) => Object.prototype.hasOwnProperty.call(body, k);
    if (has('intervalSec')) cfg.intervalSec = Math.min(600, Math.max(3, Number(body.intervalSec) || DEFAULT_CONFIG.intervalSec));
    for (const k of ['shuffle', 'showClock', 'motion', 'muteVideo', 'showDate', 'onThisDay']) if (has(k)) cfg[k] = !!body[k];
    if (has('fit')) cfg.fit = body.fit === 'contain' ? 'contain' : 'cover';
    if (has('transition')) cfg.transition = ['fade', 'slide', 'none'].includes(body.transition) ? body.transition : 'fade';
    if (has('album')) cfg.album = albumName(body.album);
    if (has('schedule')) {
      const mmdd = (v) => (typeof v === 'string' && /^\d{2}-\d{2}$/.test(v) ? v : undefined);
      const min = (v) => (Number.isInteger(v) && v >= 0 && v < 1440 ? v : undefined);
      cfg.schedule = (Array.isArray(body.schedule) ? body.schedule : []).slice(0, 50).map((r) => ({
        album: albumName(r && r.album), from: mmdd(r && r.from), to: mmdd(r && r.to), fromMin: min(r && r.fromMin), toMin: min(r && r.toMin),
      }));
    }
    if (has('soundOn')) cfg.soundOn = (Array.isArray(body.soundOn) ? body.soundOn : []).filter((x) => typeof x === 'string').slice(0, 1000);
    if (has('captions')) {
      cfg.captions = {};
      for (const [k, v] of Object.entries(body.captions || {})) if (typeof v === 'string' && v.trim()) cfg.captions[k] = v.slice(0, 200);
    }
    if (has('weather')) {
      const w = body.weather;
      cfg.weather = w && Number.isFinite(w.lat) && Number.isFinite(w.lon)
        ? { lat: w.lat, lon: w.lon, place: String(w.place || '').slice(0, 100), unit: w.unit === 'f' ? 'f' : 'c' } : null;
    }
    await pushConfig(cfg);
    upsertTv(needDevice(), { screensaverConfig: cfg });
    return { ok: true, config: cfg };
  },

  'POST /api/screensaver/album': async (body) => {
    const name = albumName(body.name);
    if (!name) throw httpError(400, 'Give the album a name.');
    await sh(`mkdir -p ${q(await albumDir(name))}`);
    return { ok: true, name };
  },
  'DELETE /api/screensaver/album': async (_b, url) => {
    const name = albumName(url.searchParams.get('name'));
    if (!name) throw httpError(400, 'The Main album can\'t be deleted.');
    await sh(`rm -rf ${q(await albumDir(name))}`);
    return { ok: true };
  },

  'DELETE /api/screensaver/file': async (_b, url) => {
    const name = safeName(url.searchParams.get('name'));
    const dir = await albumDir(albumName(url.searchParams.get('album')));
    await sh(`rm -f ${q(dir + '/' + name)}`);
    return { ok: true };
  },

  'POST /api/screensaver/activate': async (body) => {
    if (!(await isInstalled(SS_PKG))) throw httpError(409, 'Install the screensaver app on the TV first.');
    const prev = (await sh('settings get secure screensaver_components')).stdout.trim();
    const tv = currentTv();
    if (!prev.includes(SS_PKG) && prev && prev !== 'null') upsertTv(serial, { previousScreensaver: prev });
    else if (!tv?.previousScreensaver && prev && prev !== 'null' && !prev.includes(SS_PKG)) upsertTv(serial, { previousScreensaver: prev });
    await sh(`settings put secure screensaver_components ${SS_DREAM}`);
    await sh('settings put secure screensaver_enabled 1');
    await sh('settings put secure screensaver_activate_on_sleep 1');
    if (body.timeoutMin) {
      const mins = Math.min(120, Math.max(1, Number(body.timeoutMin)));
      await sh(`settings put system screen_off_timeout ${mins * 60000}`);
    }
    return { ok: true };
  },

  'POST /api/screensaver/restore': async () => {
    const prev = currentTv()?.previousScreensaver;
    if (prev) await sh(`settings put secure screensaver_components ${q(prev)}`);
    else await sh('settings delete secure screensaver_components');
    return { ok: true, restored: prev || 'system default' };
  },

  'POST /api/screensaver/preview': async () => {
    const r = await sh(`am start -n ${SS_PREVIEW}`);
    if (/Error/i.test(r.stdout + r.stderr)) throw httpError(500, (r.stdout + r.stderr).trim());
    return { ok: true };
  },
};

// A PNG of what's on the TV screen. Streaming apps (Netflix, Prime Video) block this.
function handleScreenshot(res) {
  const s = needDevice();
  execFile(ADB, ['-s', s, 'exec-out', 'screencap -p'], { encoding: 'buffer', timeout: 20000, maxBuffer: 64 * 1024 * 1024 }, (err, png) => {
    if (err || !png || png.length < 8 || png[0] !== 0x89) {
      return send(res, 502, { error: 'The TV didn\'t allow a picture of this screen. Streaming apps like Netflix and Prime Video block screenshots. Try it on the home screen.' });
    }
    res.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'no-store', 'Content-Length': png.length });
    res.end(png);
  });
}

async function handleUpload(req, res, url) {
  const name = safeName(url.searchParams.get('name'));
  const album = albumName(url.searchParams.get('album'));
  needDevice();
  if (!(await isInstalled(SS_PKG))) throw httpError(409, 'Install the screensaver app on the TV first.');
  const local = path.join(MEDIA, name);
  await new Promise((resolve, reject) => {
    const out = fs.createWriteStream(local);
    req.pipe(out);
    out.on('finish', resolve);
    out.on('error', reject);
    req.on('error', reject);
  });
  const dir = await albumDir(album);
  if (album) await sh(`mkdir -p ${q(dir)}`);
  const r = await run(['-s', serial, 'push', local, `${dir}/${name}`], 600000);
  if (r.code !== 0) throw httpError(500, 'Upload to TV failed: ' + (r.stderr || r.stdout));
  send(res, 200, { ok: true, name });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  try {
    if (url.pathname === '/api/screensaver/upload' && req.method === 'POST') return await handleUpload(req, res, url);
    if (url.pathname === '/api/screenshot' && req.method === 'GET') return handleScreenshot(res);
    const handler = routes[`${req.method} ${url.pathname}`];
    if (handler) {
      const body = req.method === 'POST' ? await readJson(req) : {};
      return send(res, 200, await handler(body, url));
    }
    if (url.pathname.startsWith('/api/')) return send(res, 404, { error: 'Not found' });
    if (url.pathname.startsWith('/media/')) {
      return serveFile(res, path.join(MEDIA, path.basename(decodeURIComponent(url.pathname.slice(7)))));
    }
    const rel = url.pathname === '/' ? 'index.html' : path.normalize(url.pathname).replace(/^(\.\.[/\\])+/, '');
    const file = path.join(WEB, rel);
    if (!file.startsWith(WEB)) { res.writeHead(403); return res.end(); }
    return serveFile(res, file);
  } catch (e) {
    if (!e.status) console.error(e);
    send(res, e.status || 500, { error: e.message || String(e) });
  }
});

// ---------- auto-reconnect ----------
// On start, reconnect to the TV used last; afterwards, reconnect whenever it comes back
// (e.g. after standby). Quiet: failures just wait for the next try.
let userDisconnected = false;
let reconnecting = false;
async function autoReconnect() {
  if (!ADB || reconnecting || userDisconnected) return;
  reconnecting = true;
  try {
    let address = serial;
    if (!address) {
      const last = loadTvs().filter((t) => t.lastConnected).sort((a, b) => b.lastConnected.localeCompare(a.lastConnected))[0];
      address = last && last.address;
    }
    if (!address) return;
    if ((await deviceState(address)) === 'device') { serial = address; return; }
    const host = address.split(':')[0];
    if (!(await probe(host, 5555, 1500))) return; // TV off or in standby
    await run(['connect', address], 8000);
    if ((await deviceState(address)) === 'device') {
      serial = address;
      console.log(`  🔄  Reconnected to ${address}`);
    }
  } catch { /* try again later */ } finally {
    reconnecting = false;
  }
}

server.listen(PORT, HOST, () => {
  autoReconnect();
  setInterval(autoReconnect, 20000);
  console.log(`\n  📺  Connect TV is running → http://localhost:${PORT}\n`);
  console.log(ADB ? `  adb: ${ADB}` : '  ⚠️  adb not found. Install Android platform-tools or set ADB=/path/to/adb');
  console.log(fs.existsSync(APK) ? '  screensaver app: built' : '  screensaver app: not built yet (run ./tv-screensaver/build.sh)');
  console.log('');
});
