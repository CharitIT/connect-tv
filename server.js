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
const DEFAULT_CONFIG = { intervalSec: 12, shuffle: true, showClock: true, fit: 'cover', motion: true, muteVideo: true };

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
async function listScreensaverFiles() {
  const dir = await screensaverDir();
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
    let address = String(body.address || '').trim();
    if (!/^[A-Za-z0-9.-]+(:\d{2,5})?$/.test(address)) throw httpError(400, 'Enter the TV IP address, e.g. 192.168.1.40');
    if (!address.includes(':')) address += ':5555';
    const r = await run(['connect', address], 12000);
    const out = (r.stdout + r.stderr).trim();
    if (/cannot|failed|refused|unable|no route|timed out/i.test(out)) {
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

  'GET /api/screensaver/status': async () => {
    const installed = await isInstalled(SS_PKG);
    const comp = (await sh('settings get secure screensaver_components')).stdout.trim();
    const enabled = (await sh('settings get secure screensaver_enabled')).stdout.trim();
    const timeoutMs = Number((await sh('settings get system screen_off_timeout')).stdout.trim()) || null;
    const files = installed ? await listScreensaverFiles() : [];
    const tv = currentTv();
    return {
      installed, apkBuilt: fs.existsSync(APK),
      active: comp.includes(SS_PKG), components: comp, enabled,
      timeoutMin: timeoutMs ? Math.round(timeoutMs / 60000) : null,
      files, config: { ...DEFAULT_CONFIG, ...(tv?.screensaverConfig || {}) },
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
    await pushConfig({ ...DEFAULT_CONFIG, ...(tv?.screensaverConfig || {}) });
    return { ok: true };
  },

  'POST /api/screensaver/config': async (body) => {
    const cfg = {
      intervalSec: Math.min(600, Math.max(3, Number(body.intervalSec) || DEFAULT_CONFIG.intervalSec)),
      shuffle: !!body.shuffle, showClock: !!body.showClock, motion: !!body.motion, muteVideo: body.muteVideo !== false,
      fit: body.fit === 'contain' ? 'contain' : 'cover',
    };
    await pushConfig(cfg);
    upsertTv(needDevice(), { screensaverConfig: cfg });
    return { ok: true, config: cfg };
  },

  'DELETE /api/screensaver/file': async (_b, url) => {
    const name = safeName(url.searchParams.get('name'));
    const dir = await screensaverDir();
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

async function handleUpload(req, res, url) {
  const name = safeName(url.searchParams.get('name'));
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
  const dir = await screensaverDir();
  const r = await run(['-s', serial, 'push', local, `${dir}/${name}`], 600000);
  if (r.code !== 0) throw httpError(500, 'Upload to TV failed: ' + (r.stderr || r.stdout));
  send(res, 200, { ok: true, name });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  try {
    if (url.pathname === '/api/screensaver/upload' && req.method === 'POST') return await handleUpload(req, res, url);
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

server.listen(PORT, HOST, () => {
  console.log(`\n  📺  Connect TV is running → http://localhost:${PORT}\n`);
  console.log(ADB ? `  adb: ${ADB}` : '  ⚠️  adb not found. Install Android platform-tools or set ADB=/path/to/adb');
  console.log(fs.existsSync(APK) ? '  screensaver app: built' : '  screensaver app: not built yet (run ./tv-screensaver/build.sh)');
  console.log('');
});
