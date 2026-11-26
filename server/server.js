// HeartCheck 서버 — 의존성 없음 (Node 18+)
// 워치(대기) → 10초마다 /api/ping, 웹에서 [측정 시작] → 워치가 5분간 2초마다 /api/hr → SSE로 페이지에 실시간 표시
'use strict';
const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const PORT = Number(process.env.PORT || 8787);
const VIEW_KEY = process.env.VIEW_KEY || '';
const DEVICE_KEY = process.env.DEVICE_KEY || '';
const SESSION_MIN = Number(process.env.SESSION_MINUTES || 5);
const ONLINE_MS = 40 * 1000; // 40초 안에 신호가 오면 '워치 대기 중'
if (!VIEW_KEY || !DEVICE_KEY) { console.error('VIEW_KEY, DEVICE_KEY 환경변수를 설정하세요.'); process.exit(1); }

const state = { lastSeen: 0, keepUntil: 0, lastHr: null, history: [] };
const clients = new Set();
const now = () => Date.now();
const online = () => now() - state.lastSeen < ONLINE_MS;
const active = () => now() < state.keepUntil;

function snapshot() {
  return { online: online(), active: active(), keepUntil: state.keepUntil, lastSeen: state.lastSeen, lastHr: state.lastHr, now: now() };
}
function broadcast(type, data) {
  const msg = `event: ${type}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const res of clients) res.write(msg);
}
setInterval(() => broadcast('status', snapshot()), 5000);   // 온라인/남은 시간 갱신
setInterval(() => { for (const r of clients) r.write(': ping\n\n'); }, 20000);

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
function safeEq(a, b) {
  const x = Buffer.from(String(a)), y = Buffer.from(String(b));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}
const deviceReply = () => ({ ok: true, watching: active(), keepUntil: state.keepUntil, lastHrTs: state.lastHr ? state.lastHr.ts : 0, now: now() });

const PUBLIC = path.join(__dirname, 'public');
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.svg': 'image/svg+xml' };

http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const p = url.pathname;
  const key = req.headers['x-key'] || url.searchParams.get('k') || '';
  const isViewer = safeEq(key, VIEW_KEY);
  const isDevice = safeEq(key, DEVICE_KEY);
  if (p.startsWith('/api/') && p !== '/api/stream' && p !== '/api/status') {
    const who = isDevice ? 'device' : isViewer ? 'viewer' : `키틀림(${String(key).slice(0, 12) || '없음'})`;
    console.log(new Date().toISOString(), req.method, p, who, req.headers['user-agent'] || '');
  }

  // ----- 웹 페이지용 -----
  if (p === '/api/stream' && req.method === 'GET') {
    if (!isViewer) return json(res, 401, { error: 'unauthorized' });
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store', connection: 'keep-alive', 'x-accel-buffering': 'no' });
    res.write(`event: status\ndata: ${JSON.stringify(snapshot())}\n\n`);
    res.write(`event: history\ndata: ${JSON.stringify(state.history.slice(-150))}\n\n`);
    clients.add(res);
    req.on('close', () => clients.delete(res));
    return;
  }
  // 폴링용: 상태 + since 이후 심박 (터널에서 SSE가 막혀도 동작)
  if (p === '/api/status' && req.method === 'GET') {
    if (!isViewer) return json(res, 401, { error: 'unauthorized' });
    const since = Number(url.searchParams.get('since') || 0);
    const hrs = since ? state.history.filter(h => h.ts > since) : state.history.slice(-150);
    return json(res, 200, { status: snapshot(), hr: hrs });
  }
  if (p === '/api/request' && req.method === 'POST') {
    if (!isViewer) return json(res, 401, { error: 'unauthorized' });
    if (!online()) return json(res, 409, { error: 'offline' });
    state.keepUntil = now() + SESSION_MIN * 60 * 1000;
    broadcast('status', snapshot());
    return json(res, 200, { ok: true, keepUntil: state.keepUntil });
  }
  if (p === '/api/stop' && req.method === 'POST') {
    if (!isViewer) return json(res, 401, { error: 'unauthorized' });
    state.keepUntil = 0;
    broadcast('status', snapshot());
    return json(res, 200, { ok: true });
  }

  // ----- 워치용 -----
  if ((p === '/api/ping' || p === '/api/hr') && req.method === 'POST') {
    if (!isDevice) return json(res, 401, { error: 'unauthorized' });
    const b = await readBody(req);
    const wasOnline = online();
    state.lastSeen = now();
    if (p === '/api/hr') {
      const bpm = Math.round(Number(b.bpm));
      if (bpm > 20 && bpm < 250) {
        const s = { bpm, ts: Number(b.ts) || now() };
        state.lastHr = s;
        state.history.push(s);
        if (state.history.length > 600) state.history.splice(0, state.history.length - 600);
        broadcast('hr', s);
      }
    }
    if (!wasOnline || p === '/api/hr') broadcast('status', snapshot());
    return json(res, 200, deviceReply());
  }

  // ----- 정적 파일 -----
  if (req.method === 'GET') {
    const file = path.normalize(path.join(PUBLIC, p === '/' ? 'index.html' : p));
    if (file.startsWith(PUBLIC) && fs.existsSync(file) && fs.statSync(file).isFile()) {
      res.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream' });
      return fs.createReadStream(file).pipe(res);
    }
  }
  json(res, 404, { error: 'not found' });
}).listen(PORT, () => console.log(`HeartCheck 서버 :${PORT}`));
