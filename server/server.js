// HeartCheck 서버 — 의존성 없음 (Node 18+)
// 사이트 버튼 → APNs 무음 푸시 → 아이폰 → 워치 측정 → /api/hr 로 심박 수신 → SSE로 사이트에 실시간 전달
'use strict';
const http = require('http');
const http2 = require('http2');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const env = (k, d) => process.env[k] ?? d;
const PORT = Number(env('PORT', 8787));
const VIEW_KEY = env('VIEW_KEY', '');          // 사이트(확인하는 사람)용 키
const DEVICE_KEY = env('DEVICE_KEY', '');      // 아이폰/워치 앱용 키
const SESSION_MIN = Number(env('SESSION_MINUTES', 5)); // 버튼 한 번에 측정 유지 시간
const APNS_TEAM_ID = env('APNS_TEAM_ID', '');
const APNS_KEY_ID = env('APNS_KEY_ID', '');
const APNS_KEY_FILE = env('APNS_KEY_FILE', '/data/AuthKey.p8');
const APNS_TOPIC = env('APNS_TOPIC', 'com.kuroart.heartcheck'); // 아이폰 앱 번들 ID
const APNS_HOST = env('APNS_SANDBOX', '1') === '1'
  ? 'https://api.sandbox.push.apple.com'   // Xcode로 직접 설치한 빌드
  : 'https://api.push.apple.com';          // TestFlight/배포 빌드
const DATA_DIR = env('DATA_DIR', '/data');
const STATE_FILE = path.join(DATA_DIR, 'state.json');

if (!VIEW_KEY || !DEVICE_KEY) {
  console.error('VIEW_KEY 와 DEVICE_KEY 환경변수를 설정하세요.');
  process.exit(1);
}

// ---------- 상태 ----------
const state = {
  deviceToken: null,
  keepUntil: 0,          // 이 시각까지 워치가 측정을 유지
  lastRequestAt: 0,
  lastHr: null,          // {bpm, ts}
  history: [],           // 최근 심박 (최대 300개)
  phase: 'idle',         // idle | requested | phone_woke | measuring | ended | error
  phaseDetail: '',
  phaseAt: 0,
};
try {
  const saved = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
  state.deviceToken = saved.deviceToken || null;
} catch { /* 첫 실행 */ }
function saveState() {
  try {
    fs.mkdirSync(DATA_DIR, { recursive: true });
    fs.writeFileSync(STATE_FILE, JSON.stringify({ deviceToken: state.deviceToken }));
  } catch (e) { console.error('state 저장 실패', e.message); }
}

// ---------- SSE ----------
const clients = new Set();
function snapshot() {
  return {
    phase: state.phase, phaseDetail: state.phaseDetail, phaseAt: state.phaseAt,
    lastHr: state.lastHr, keepUntil: state.keepUntil,
    deviceRegistered: !!state.deviceToken, now: Date.now(),
  };
}
function broadcast(type, data) {
  const msg = `event: ${type}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const res of clients) res.write(msg);
}
function setPhase(phase, detail = '') {
  state.phase = phase; state.phaseDetail = detail; state.phaseAt = Date.now();
  broadcast('status', snapshot());
}
setInterval(() => { for (const res of clients) res.write(': ping\n\n'); }, 20000);

// 지금 보고 있는 사람이 있는지 (밤새 모드에서 워치 전송 간격 조절용)
const watching = () => clients.size > 0 || Date.now() < state.keepUntil;

// ---------- APNs ----------
let jwtCache = { token: null, at: 0 };
function apnsJwt() {
  if (jwtCache.token && Date.now() - jwtCache.at < 50 * 60 * 1000) return jwtCache.token;
  const key = fs.readFileSync(APNS_KEY_FILE, 'utf8');
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const iat = Math.floor(Date.now() / 1000);
  const unsigned = `${b64({ alg: 'ES256', kid: APNS_KEY_ID })}.${b64({ iss: APNS_TEAM_ID, iat })}`;
  const sig = crypto.sign('sha256', Buffer.from(unsigned), { key, dsaEncoding: 'ieee-p1363' });
  jwtCache = { token: `${unsigned}.${sig.toString('base64url')}`, at: Date.now() };
  return jwtCache.token;
}
function sendSilentPush(deviceToken) {
  return new Promise((resolve) => {
    let client;
    try { client = http2.connect(APNS_HOST); } catch (e) { return resolve({ ok: false, error: e.message }); }
    client.on('error', (e) => resolve({ ok: false, error: e.message }));
    const body = JSON.stringify({ aps: { 'content-available': 1 }, hc: { minutes: SESSION_MIN } });
    const req = client.request({
      ':method': 'POST',
      ':path': `/3/device/${deviceToken}`,
      authorization: `bearer ${apnsJwt()}`,
      'apns-push-type': 'background',
      'apns-priority': '5',          // 무음 푸시는 5만 허용
      'apns-topic': APNS_TOPIC,
      'apns-expiration': String(Math.floor(Date.now() / 1000) + 120),
    });
    let status = 0, data = '';
    req.on('response', (h) => { status = h[':status']; });
    req.on('data', (c) => { data += c; });
    req.on('end', () => { client.close(); resolve({ ok: status === 200, status, body: data }); });
    req.on('error', (e) => { client.close(); resolve({ ok: false, error: e.message }); });
    req.end(body);
  });
}

// ---------- HTTP ----------
function json(res, code, obj) {
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  res.end(JSON.stringify(obj));
}
function readBody(req) {
  return new Promise((resolve) => {
    let d = '';
    req.on('data', (c) => { d += c; if (d.length > 1e5) req.destroy(); });
    req.on('end', () => { try { resolve(d ? JSON.parse(d) : {}); } catch { resolve({}); } });
  });
}
function keyOf(req, url) { return req.headers['x-key'] || url.searchParams.get('k') || ''; }
function safeEq(a, b) {
  const x = Buffer.from(String(a)), y = Buffer.from(String(b));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

const PUBLIC = path.join(__dirname, 'public');
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.webmanifest': 'application/manifest+json' };

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const p = url.pathname;
  const key = keyOf(req, url);
  const isViewer = safeEq(key, VIEW_KEY);
  const isDevice = safeEq(key, DEVICE_KEY);

  // --- 사이트용 ---
  if (p === '/api/stream' && req.method === 'GET') {
    if (!isViewer) return json(res, 401, { error: 'unauthorized' });
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store', connection: 'keep-alive', 'x-accel-buffering': 'no' });
    res.write(`event: status\ndata: ${JSON.stringify(snapshot())}\n\n`);
    res.write(`event: history\ndata: ${JSON.stringify(state.history.slice(-120))}\n\n`);
    clients.add(res);
    req.on('close', () => clients.delete(res));
    return;
  }
  if (p === '/api/request' && req.method === 'POST') {
    if (!isViewer) return json(res, 401, { error: 'unauthorized' });
    const now = Date.now();
    state.keepUntil = now + SESSION_MIN * 60 * 1000;
    state.lastRequestAt = now;
    broadcast('status', snapshot());
    // 이미 측정 중이면 푸시 없이 시간만 연장
    if (state.lastHr && now - state.lastHr.ts < 20000) return json(res, 200, { ok: true, extended: true });
    if (!state.deviceToken) { setPhase('error', '아이폰 앱이 아직 등록되지 않았어요'); return json(res, 409, { error: 'no device' }); }
    setPhase('requested');
    const r = await sendSilentPush(state.deviceToken);
    if (!r.ok) {
      console.error('APNs 실패', r);
      setPhase('error', `푸시 실패 (${r.status || r.error}) ${r.body || ''}`.trim());
      if (r.status === 410) { state.deviceToken = null; saveState(); }
      return json(res, 502, { error: 'push failed', detail: r });
    }
    return json(res, 200, { ok: true });
  }
  if (p === '/api/stop' && req.method === 'POST') {
    if (!isViewer) return json(res, 401, { error: 'unauthorized' });
    state.keepUntil = 0;
    broadcast('status', snapshot());
    return json(res, 200, { ok: true });
  }

  // --- 앱용 ---
  if (p === '/api/register' && req.method === 'POST') {
    if (!isDevice) return json(res, 401, { error: 'unauthorized' });
    const b = await readBody(req);
    if (!/^[0-9a-f]{64,200}$/i.test(b.deviceToken || '')) return json(res, 400, { error: 'bad token' });
    state.deviceToken = b.deviceToken; saveState();
    broadcast('status', snapshot());
    return json(res, 200, { ok: true });
  }
  if (p === '/api/event' && req.method === 'POST') {
    if (!isDevice) return json(res, 401, { error: 'unauthorized' });
    const b = await readBody(req);
    const map = { phone_woke: 'phone_woke', watch_started: 'measuring', watch_ended: 'ended', error: 'error' };
    if (map[b.type]) setPhase(map[b.type], String(b.detail || '').slice(0, 200));
    return json(res, 200, { ok: true, keepUntil: state.keepUntil });
  }
  if (p === '/api/hr' && req.method === 'POST') {
    if (!isDevice) return json(res, 401, { error: 'unauthorized' });
    const b = await readBody(req);
    const bpm = Math.round(Number(b.bpm));
    if (!(bpm > 20 && bpm < 250)) return json(res, 400, { error: 'bad bpm' });
    const sample = { bpm, ts: Number(b.ts) || Date.now() };
    state.lastHr = sample;
    state.history.push(sample);
    if (state.history.length > 300) state.history.splice(0, state.history.length - 300);
    if (state.phase !== 'measuring') { state.phase = 'measuring'; state.phaseDetail = ''; state.phaseAt = Date.now(); }
    broadcast('hr', sample);
    broadcast('status', snapshot());
    return json(res, 200, { ok: true, keepUntil: state.keepUntil, watching: watching() });
  }

  // --- 정적 파일 ---
  if (req.method === 'GET') {
    const file = path.normalize(path.join(PUBLIC, p === '/' ? 'index.html' : p));
    if (file.startsWith(PUBLIC) && fs.existsSync(file) && fs.statSync(file).isFile()) {
      res.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream' });
      return fs.createReadStream(file).pipe(res);
    }
  }
  json(res, 404, { error: 'not found' });
});

server.listen(PORT, () => console.log(`HeartCheck 서버 :${PORT} (APNs ${APNS_HOST})`));
