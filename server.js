const https = require("https");
const express = require('express');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const os = require('os');

const app = express();
const PORT = Number(process.env.PORT) || 3000;
const HOST = '0.0.0.0';
const INDEX_PATH = path.join(__dirname, 'index.html');
const CONFIG_DIR = '/opt/xiqi/config';
const PROFILES_PATH = path.join(CONFIG_DIR, 'profiles.json');
const ADMINS_PATH = path.join(CONFIG_DIR, 'admins.json');
const MASTER_KEY_PATH = path.join(CONFIG_DIR, "master.key");
const activeTokens = new Map();
const loginFails = new Map();

function getMasterKey() {
  fs.mkdirSync(CONFIG_DIR, { recursive: true });
  if (!fs.existsSync(MASTER_KEY_PATH)) {
    const k = crypto.randomBytes(16).toString("hex");
    fs.writeFileSync(MASTER_KEY_PATH, k, { mode: 0o600 });
    return k;
  }
  return fs.readFileSync(MASTER_KEY_PATH, "utf8").trim();
}

function safeEq(a, b) {
  const ba = Buffer.from(String(a || ""));
  const bb = Buffer.from(String(b || ""));
  return ba.length > 0 && ba.length === bb.length && crypto.timingSafeEqual(ba, bb);
}

function escHtml(str) {
  return String(str || "").replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");
}

function isBlocked(ip) {
  const rec = loginFails.get(ip);
  if (!rec) return false;
  if (Date.now() > rec.until) { loginFails.delete(ip); return false; }
  return rec.count >= 5;
}

function markFail(ip) {
  const rec = loginFails.get(ip) || { count: 0, until: 0 };
  rec.count += 1;
  rec.until = Date.now() + 10 * 60 * 1000;
  loginFails.set(ip, rec);
}

app.disable('x-powered-by');
app.use(express.json({ limit: '16kb' }));

app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
  res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; connect-src 'self'; frame-src 'self' http: https:; object-src 'none'; base-uri 'self'; form-action 'self';");
  next();
});

function readJson(p, fb) { try { return fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, 'utf8')) : fb; } catch (e) { return fb; } }
function writeJson(p, d) { fs.mkdirSync(CONFIG_DIR, { recursive: true }); fs.writeFileSync(p, JSON.stringify(d, null, 2), { mode: 0o600 }); }
function hashSecret(p, s) { return crypto.scryptSync(String(p), String(s), 32).toString('hex'); }

function getAdmins() {
  let list = readJson(ADMINS_PATH, null);
  if (!Array.isArray(list)) list = [];
  return list;
}

function checkAdmin(req) {
  const tk = String(req.headers['x-admin-key'] || '');
  if (!tk) return false;
  if (safeEq(tk, getMasterKey())) return true;
  const parts = tk.split(':');
  const exp = activeTokens.get(tk); if (!exp || Date.now() > exp) { activeTokens.delete(tk); return false; } return true;
}

app.get('/api/store', (req, res) => {
  const d = readJson(PROFILES_PATH, { activeUserId: null, users: [], guestSession: null });
  res.json({ activeUserId: d.activeUserId || null, users: (d.users || []).map(u => ({ id: u.id, name: u.name, identifier: u.identifier, salt: u.salt, pinHash: u.pinHash, color: u.color, session: u.session })), guestSession: d.guestSession || null });
});

app.post('/api/store', (req, res) => {
  const inc = req.body || {};
  const cur = readJson(PROFILES_PATH, { version: '1.0.0', organization: 'Corporação Engecema', activeUserId: null, users: [], guestSession: null });
  const prevMap = new Map((cur.users || []).map(u => [u.id, u]));
  cur.activeUserId = inc.activeUserId || null;
  cur.guestSession = inc.guestSession || cur.guestSession;
  if (Array.isArray(inc.users) && (inc.users.length > 0 || cur.users.length === 0)) cur.users = inc.users.map(u => {
    const prev = prevMap.get(u.id) || {};
    return { id: String(u.id), name: String(u.name || '').slice(0, 80), identifier: String(u.identifier || '').slice(0, 120), salt: u.salt || prev.salt || '', pinHash: u.pinHash || prev.pinHash || '', color: u.color || prev.color || '#2563eb', createdAt: prev.createdAt || new Date().toISOString(), session: u.session || prev.session || {} };
  });
  writeJson(PROFILES_PATH, cur);
  res.json({ ok: true });
});

app.post('/api/admin/login', (req, res) => { const ip = req.ip || "local"; if (isBlocked(ip)) return res.status(429).json({ error: "Bloqueado por 10 min após 5 falhas." });
  const { email, password } = req.body || {};
  const adm = getAdmins().find(a => String(a.email || '').toLowerCase() === String(email || '').trim().toLowerCase());
  if (!adm || !safeEq(hashSecret(password || '', adm.salt), adm.hash)) { markFail(ip); return res.status(401).json({ error: 'E-mail ou senha inválidos.' }); } loginFails.delete(ip);
  const tk = crypto.randomBytes(24).toString('hex'); activeTokens.set(tk, Date.now() + 2 * 3600 * 1000); res.json({ ok: true, token: tk });
});

app.post('/api/admin/register', (req, res) => {
  const { name, email, password, masterKey } = req.body || {};
  if (!safeEq(masterKey, getMasterKey())) return res.status(403).json({ error: 'Chave mestra inválida.' });
  const em = String(email || '').trim().toLowerCase();
  if (!name || !em.includes('@') || !password || String(password).length < 4) return res.status(400).json({ error: 'Preencha Nome, E-mail e Senha (min. 4).' });
  const list = getAdmins();
  if (list.some(a => String(a.email || '').toLowerCase() === em)) return res.status(409).json({ error: 'E-mail já cadastrado.' });
  const salt = crypto.randomBytes(16).toString('hex');
  list.push({ id: 'adm-' + Date.now(), name: String(name).trim().slice(0, 80), email: em.slice(0, 120), salt, hash: hashSecret(password, salt), createdAt: new Date().toISOString() });
  writeJson(ADMINS_PATH, list);
  res.json({ ok: true });
});

app.post('/api/admin/reset-password', (req, res) => {
  const { email, masterKey, newPassword } = req.body || {};
  if (!safeEq(masterKey, getMasterKey())) return res.status(403).json({ error: 'Chave mestra inválida.' });
  const em = String(email || '').trim().toLowerCase();
  const list = getAdmins();
  const adm = list.find(a => String(a.email || '').toLowerCase() === em);
  if (!adm || !newPassword || String(newPassword).length < 4) return res.status(400).json({ error: 'Dados inválidos.' });
  const salt = crypto.randomBytes(16).toString('hex');
  adm.salt = salt; adm.hash = hashSecret(newPassword, salt);
  writeJson(ADMINS_PATH, list);
  res.json({ ok: true });
});

app.get('/api/admin/users', (req, res) => {
  if (!checkAdmin(req)) return res.status(403).json({ error: 'Negado.' });
  const d = readJson(PROFILES_PATH, { users: [] });
  res.json({ users: (d.users || []).map(u => ({ id: u.id, name: u.name, identifier: u.identifier })) });
});

app.delete('/api/admin/users/:id', (req, res) => {
  if (!checkAdmin(req)) return res.status(403).json({ error: 'Negado.' });
  const d = readJson(PROFILES_PATH, { users: [] });
  d.users = (d.users || []).filter(u => u.id !== String(req.params.id || ''));
  writeJson(PROFILES_PATH, d);
  res.json({ ok: true });
});

app.get('/api/search', async (req, res) => {
  const q = String(req.query.q || '').trim();
  if (!q) return res.status(400).send('Digite um termo.');
  try {
    const host = String.fromCharCode(104,116,109,108,46,100,117,99,107,100,117,99,107,103,111,46,99,111,109);
    const r = await fetch('https://' + host + '/html/?kl=br-pt&q=' + encodeURIComponent(q), { headers: { 'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36', 'Accept-Language': 'pt-BR,pt;q=0.9' } });
    const html = await r.text();
    const rx = new RegExp('<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>([\\s\\S]*?)<\\/a>', 'gi');
    const items = []; let m;
    while ((m = rx.exec(html)) !== null && items.length < 15) {
      let href = m.at(1) || '';
      if (href.includes('uddg=')) { try { href = decodeURIComponent(href.split('uddg=').at(1).split('&').at(0)); } catch (e) {} }
      const title = (m.at(2) || '').replace(/<[^>]+>/g, '').trim();
      if (href.startsWith('http') && title) items.push({ title, href });
    }
    const cards = items.length ? items.map(i => '<div style="margin-bottom:14px;padding:14px;background:#fff;border-radius:8px;border:1px solid #cbd5e1"><a href="' + i.href + '" target="_blank" rel="noopener" style="font-size:16px;color:#1d4ed8;font-weight:600;text-decoration:none">' + escHtml(i.title) + '</a><div style="font-size:12px;color:#15803d;margin-top:4px;word-break:break-all">' + i.href + '</div></div>').join('') : '<p>Nenhum resultado.</p>';
    res.type('html').send('<!DOCTYPE html><html><head><meta charset="utf-8"><title>Busca XIQI</title></head><body style="font-family:sans-serif;background:#f8fafc;padding:24px;max-width:860px;margin:auto"><h2>Resultados XIQI OS para: ' + q.replace(/</g, '&lt;') + '</h2>' + cards + '</body></html>');
  } catch (err) { res.status(502).send('Erro na consulta.'); }
});

app.post('/api/ai', async (req, res) => {
  try {
    const prompt = String((req.body && req.body.prompt) || '').trim();
    if (!prompt) return res.status(400).json({ error: 'Digite uma pergunta.' });
    const low = prompt.toLowerCase();
    if (low.includes('sistema') || low.includes('memoria') || low.includes('status')) {
      return res.json({ text: 'Status XIQI OS (Corporação Engecema):\n• Memória Livre: ' + Math.round(os.freemem()/1024/1024) + ' MB / ' + Math.round(os.totalmem()/1024/1024) + ' MB\n• Ativo há: ' + Math.floor(os.uptime()/60) + ' min' });
    }
    const host = String.fromCharCode(104,116,109,108,46,100,117,99,107,100,117,99,107,103,111,46,99,111,109);
    const r = await fetch('https://' + host + '/html/?kl=br-pt&q=' + encodeURIComponent(prompt), { headers: { 'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36', 'Accept-Language': 'pt-BR,pt;q=0.9' } });
    const html = await r.text();
    const blocks = html.split('result__body').slice(1, 6);
    const out = [];
    for (const b of blocks) {
      const aM = b.match(/<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/i);
      const sM = b.match(/<a[^>]+class="result__snippet"[^>]*>([\s\S]*?)<\/a>/i);
      if (!aM) continue;
      let href = aM.at(1) || '';
      if (href.includes('uddg=')) { try { href = decodeURIComponent(href.split('uddg=').at(1).split('&').at(0)); } catch (e) {} }
      const clean = t => t.replace(/<[^>]+>/g, '').replace(/&quot;/g, '"').replace(/&amp;/g, '&').trim();
      const title = clean(aM.at(2) || ''); const snip = sM ? clean(sM.at(1) || '') : '';
      if (href.startsWith('http') && title) out.push((out.length + 1) + '. ' + title + (snip ? '\n' + snip : '') + '\nFonte: ' + href);
    }
    return res.json({ text: out.length ? 'Síntese XIQI IA para "' + prompt + '":\n\n' + out.join('\n\n') : 'XIQI IA: Sem resumo direto para "' + prompt + '".' });
  } catch (e) { return res.json({ text: 'XIQI IA: Núcleo local ativo.' }); }
});


const NOTES_PATH = path.join(CONFIG_DIR, "notes.json");
app.get("/api/notes", (req, res) => {
  res.json(readJson(NOTES_PATH, { text: "", updatedAt: null }));
});
app.post("/api/notes", (req, res) => {
  const text = String((req.body && req.body.text) || "").slice(0, 15000);
  writeJson(NOTES_PATH, { text, updatedAt: new Date().toISOString() });
  res.json({ ok: true });
});

app.get("/admin", (req, res) => res.sendFile(path.join(__dirname, 'admin.html')));
app.get('/', (req, res) => res.sendFile(INDEX_PATH));
app.get('/index.html', (req, res) => res.sendFile(INDEX_PATH));
app.use((req, res) => res.status(404).type('text/plain').send('Not Found'));


const tlsOpts = {
  key: fs.readFileSync("/opt/xiqi/config/xiqios.key"),
  cert: fs.readFileSync("/opt/xiqi/config/xiqios.crt")
};
https.createServer(tlsOpts, app).listen(443, HOST, () => console.log("XIQI OS HTTPS ativo em https://xiqios"));

require('http').createServer((req, res) => { res.writeHead(301, { Location: 'https://' + (req.headers.host || 'xiqios').replace(/:\d+$/, '') + req.url }); res.end(); }).listen(80, HOST).on('error', () => {});
app.listen(PORT, HOST, () => console.log('XIQI OS Server listening on port ' + PORT));
app.use((req, res) => res.status(404).type("text/plain").send("Not Found"));
require("http").createServer((req, res) => { res.writeHead(301, { Location: "https://" + (req.headers.host || "xiqios").replace(/:\d+$/, "") + req.url }); res.end(); }).listen(80, HOST).on("error", () => {});
app.listen(PORT, HOST, () => console.log("XIQI OS Server listening on port " + PORT));
