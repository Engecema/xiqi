const express = require('express');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const os = require('os');
const dns = require('dns').promises;
const net = require('net');
const http = require('http');
const https = require('https');
const zlib = require('zlib');

const app = express();
app.set('trust proxy', 1);
const PORT = Number(process.env.PORT) || 3000;
const HOST = '0.0.0.0';
const INDEX_PATH = path.join(__dirname, 'index.html');

const CONFIG_DIR = (() => {
  const preferred = process.env.XIQI_CONFIG_DIR || '/opt/xiqi/config';
  try {
    fs.mkdirSync(preferred, { recursive: true });
    fs.accessSync(preferred, fs.constants.W_OK);
    return preferred;
  } catch {
    const fallback = path.join(__dirname, '.xiqi-config');
    fs.mkdirSync(fallback, { recursive: true });
    return fallback;
  }
})();

const PROFILES_PATH = path.join(CONFIG_DIR, 'profiles.json');
const ADMINS_PATH = path.join(CONFIG_DIR, 'admins.json');
const MASTER_KEY_PATH = path.join(CONFIG_DIR, 'master.key');
const activeAdminTokens = new Map();
const activeUserTokens = new Map();
const loginFails = new Map();
const rateBuckets = new Map();

const SESSION_TTL_MS = 24 * 3600 * 1000;
const ADMIN_TTL_MS = 2 * 3600 * 1000;
const MAX_PROXY_BYTES = 5 * 1024 * 1024;
const MAX_MAP_ENTRIES = 20000;

let cachedXiqiAI = null;
let cachedXiqiAIKey = '';
async function getXiqiAIClient() {
  const apiKey = String(process.env.XIQI_AI_KEY || '').trim();
  if (!apiKey) {
    cachedXiqiAI = null;
    cachedXiqiAIKey = '';
    return null;
  }
  if (!cachedXiqiAI || cachedXiqiAIKey !== apiKey) {
    const { GoogleGenAI } = await import('@google/genai');
    cachedXiqiAI = new GoogleGenAI({
      apiKey,
      httpOptions: {
        headers: {
          'User-Agent': 'XIQI-OS/1.0'
        }
      }
    });
    cachedXiqiAIKey = apiKey;
  }
  return cachedXiqiAI;
}

function getMasterKey() {
  fs.mkdirSync(CONFIG_DIR, { recursive: true });
  if (!fs.existsSync(MASTER_KEY_PATH)) {
    const k = crypto.randomBytes(24).toString('hex');
    const tmp = MASTER_KEY_PATH + '.tmp-' + process.pid + '-' + crypto.randomBytes(4).toString('hex');
    fs.writeFileSync(tmp, k, { mode: 0o600 });
    fs.renameSync(tmp, MASTER_KEY_PATH);
    return k;
  }
  return fs.readFileSync(MASTER_KEY_PATH, 'utf8').trim();
}

function safeEq(a, b) {
  const sa = String(a || '');
  const sb = String(b || '');
  if (!sa || !sb) return false;
  const ha = crypto.createHash('sha256').update(sa).digest();
  const hb = crypto.createHash('sha256').update(sb).digest();
  return crypto.timingSafeEqual(ha, hb);
}

function safeJsonForScript(val) {
  return JSON.stringify(val)
    .replace(/</g, '\\u003c')
    .replace(/>/g, '\\u003e')
    .replace(/&/g, '\\u0026')
    .replace(/\u2028/g, '\\u2028')
    .replace(/\u2029/g, '\\u2029');
}

function generateRecoveryCode() {
  const raw = crypto.randomBytes(8).toString('hex').toUpperCase();
  return 'XIQI-' + raw.slice(0, 4) + '-' + raw.slice(4, 8) + '-' + raw.slice(8, 12) + '-' + raw.slice(12, 16);
}

function escHtml(str) {
  return String(str || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function isSafeHttpUrl(raw) {
  try {
    const u = new URL(String(raw || '').trim());
    return u.protocol === 'http:' || u.protocol === 'https:';
  } catch {
    return false;
  }
}

/* =====================================================================
   PROTECAO ANTI-SSRF (IPv4/IPv6 NORMALIZADO + PINNING ANTI-DNS-REBINDING)
   ===================================================================== */
function parseIpv6Hextets(ip) {
  const withoutZone = String(ip || '').split('%')[0].toLowerCase();
  if (!net.isIPv6(withoutZone)) return null;
  let working = withoutZone;
  const lastColon = working.lastIndexOf(':');
  if (lastColon !== -1 && working.slice(lastColon + 1).includes('.')) {
    const ipv4Part = working.slice(lastColon + 1);
    if (!net.isIPv4(ipv4Part)) return null;
    const octets = ipv4Part.split('.').map(Number);
    const h1 = ((octets[0] << 8) | octets[1]).toString(16);
    const h2 = ((octets[2] << 8) | octets[3]).toString(16);
    working = working.slice(0, lastColon + 1) + h1 + ':' + h2;
  }
  const halves = working.split('::');
  if (halves.length > 2) return null;
  const left = halves[0] ? halves[0].split(':') : [];
  const right = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
  const missing = 8 - (left.length + right.length);
  if (halves.length === 1 && left.length !== 8) return null;
  if (halves.length === 2 && missing < 0) return null;
  const full = halves.length === 2
    ? [...left, ...Array(missing).fill('0'), ...right]
    : left;
  if (full.length !== 8) return null;
  const nums = full.map(h => parseInt(h || '0', 16));
  if (nums.some(n => Number.isNaN(n) || n < 0 || n > 0xffff)) return null;
  return nums;
}

function isPrivateOrReservedIp(ip) {
  if (!ip) return true;
  const raw = String(ip).split('%')[0].trim();
  const clean = raw.replace(/^::ffff:/i, '');
  if (net.isIPv4(clean)) {
    const parts = clean.split('.').map(Number);
    if (parts.length !== 4 || parts.some(n => Number.isNaN(n) || n < 0 || n > 255)) return true;
    const [a, b, c] = parts;
    if (a === 0) return true; // 0.0.0.0/8
    if (a === 10) return true; // 10.0.0.0/8
    if (a === 100 && b >= 64 && b <= 127) return true; // CGNAT 100.64.0.0/10
    if (a === 127) return true; // Loopback 127.0.0.0/8
    if (a === 169 && b === 254) return true; // Link-local / Cloud Metadata 169.254.0.0/16
    if (a === 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12
    if (a === 192 && b === 0 && (c === 0 || c === 2)) return true; // 192.0.0.0/24 & TEST-NET-1
    if (a === 192 && b === 88 && c === 99) return true; // 6to4 relay anycast
    if (a === 192 && b === 168) return true; // 192.168.0.0/16
    if (a === 198 && (b === 18 || b === 19)) return true; // Benchmarking
    if (a === 198 && b === 51 && c === 100) return true; // TEST-NET-2
    if (a === 203 && b === 0 && c === 113) return true; // TEST-NET-3
    if (a >= 224) return true; // Multicast / Reserved
    return false;
  }
  const h = parseIpv6Hextets(raw);
  if (!h) return true;
  // ::/128 (unspecified) e ::1/128 (loopback)
  if (h[0] === 0 && h[1] === 0 && h[2] === 0 && h[3] === 0 && h[4] === 0 && h[5] === 0 && h[6] === 0 && (h[7] === 0 || h[7] === 1)) {
    return true;
  }
  // ::ffff:0:0/96 (IPv4-mapped IPv6) e ::0:0/96 (IPv4-compatible IPv6)
  if (h[0] === 0 && h[1] === 0 && h[2] === 0 && h[3] === 0 && h[4] === 0 && (h[5] === 0xffff || h[5] === 0)) {
    const mappedIpv4 = `${h[6] >> 8}.${h[6] & 0xff}.${h[7] >> 8}.${h[7] & 0xff}`;
    return isPrivateOrReservedIp(mappedIpv4);
  }
  // 64:ff9b::/96 e 64:ff9b:1::/48 (NAT64)
  if (h[0] === 0x0064 && h[1] === 0xff9b) return true;
  // 100::/64 (Discard-only)
  if (h[0] === 0x0100 && h[1] === 0 && h[2] === 0 && h[3] === 0) return true;
  // fc00::/7 (Unique Local), fe80::/10 (Link-Local), ff00::/8 (Multicast)
  if ((h[0] & 0xfe00) === 0xfc00) return true;
  if ((h[0] & 0xffc0) === 0xfe80) return true;
  if ((h[0] & 0xff00) === 0xff00) return true;
  // 2001::/32 (Teredo), 2001:2::/48 (Benchmarking), 2001:db8::/32 (Docs), 2002::/16 (6to4)
  if (h[0] === 0x2001 && (h[1] === 0 || h[1] === 0x0002 || h[1] === 0x0db8)) return true;
  if (h[0] === 0x2002) return true;
  // Permite apenas Global Unicast 2000::/3 fora dos blocos reservados acima
  if ((h[0] & 0xe000) !== 0x2000) return true;
  return false;
}

async function validatePublicHttpUrl(rawUrl) {
  let parsed;
  try {
    parsed = new URL(String(rawUrl || '').trim());
  } catch {
    return { ok: false, reason: 'URL malformada.' };
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    return { ok: false, reason: 'Protocolo não permitido.' };
  }
  const allowedPorts = new Set(['', '80', '443', '8080', '8443']);
  if (!allowedPorts.has(parsed.port)) {
    return { ok: false, reason: 'Porta de destino não permitida pelo Proxy XIQI.' };
  }
  if (parsed.username || parsed.password) {
    return { ok: false, reason: 'Credenciais embutidas na URL não são permitidas.' };
  }
  const host = parsed.hostname.toLowerCase().replace(/^\[|\]$/g, '').replace(/\.$/, '');
  if (
    !host ||
    host === 'localhost' ||
    host.endsWith('.localhost') ||
    host.endsWith('.local') ||
    host.endsWith('.internal') ||
    host === 'metadata.google.internal' ||
    host === 'xiqios'
  ) {
    return { ok: false, reason: 'Acesso a endereços internos bloqueado por política de segurança.' };
  }
  if (net.isIP(host)) {
    if (isPrivateOrReservedIp(host)) {
      return { ok: false, reason: 'Acesso a faixa de IP privada ou reservada bloqueado.' };
    }
    return {
      ok: true,
      url: parsed.href,
      pinnedAddress: host,
      pinnedFamily: net.isIPv6(host) ? 6 : 4
    };
  }
  try {
    const records = await dns.lookup(host, { all: true });
    if (!records || records.length === 0) {
      return { ok: false, reason: 'Domínio sem resolução DNS.' };
    }
    for (const rec of records) {
      if (isPrivateOrReservedIp(rec.address)) {
        return { ok: false, reason: 'O destino resolve para IP interno/privado bloqueado.' };
      }
    }
    const preferred = records.find(r => r.family === 4) || records[0];
    return {
      ok: true,
      url: parsed.href,
      pinnedAddress: preferred.address,
      pinnedFamily: preferred.family || (net.isIPv6(preferred.address) ? 6 : 4)
    };
  } catch {
    return { ok: false, reason: 'Falha ao resolver domínio de destino.' };
  }
}

function makeHeaderAccessor(rawHeaders) {
  const lower = Object.create(null);
  for (const [k, v] of Object.entries(rawHeaders || {})) {
    lower[k.toLowerCase()] = Array.isArray(v) ? v.join(', ') : String(v ?? '');
  }
  return {
    get(name) {
      const val = lower[String(name || '').toLowerCase()];
      return val === undefined ? null : val;
    }
  };
}

function pinnedHttpRequest(targetUrl, pinned, options = {}) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(targetUrl);
    const mod = parsed.protocol === 'https:' ? https : http;
    const timeoutMs = Number(options.timeoutMs) || 15000;
    const reqHeaders = { ...(options.headers || {}) };
    if (!reqHeaders['Accept-Encoding'] && !reqHeaders['accept-encoding']) {
      reqHeaders['Accept-Encoding'] = 'gzip, deflate, br';
    }

    let settled = false;
    const fail = err => {
      if (!settled) {
        settled = true;
        reject(err);
      }
    };

    const req = mod.request(
      parsed,
      {
        method: options.method || 'GET',
        headers: reqHeaders,
        timeout: timeoutMs,
        lookup: (_hostname, opts, cb) => {
          if (opts && opts.all) {
            return cb(null, [{ address: pinned.pinnedAddress, family: pinned.pinnedFamily }]);
          }
          return cb(null, pinned.pinnedAddress, pinned.pinnedFamily);
        }
      },
      res => {
        const status = res.statusCode || 502;
        const headers = makeHeaderAccessor(res.headers);
        if (options.headOnly || (status >= 300 && status < 400)) {
          res.resume();
          if (!settled) {
            settled = true;
            resolve({ status, headers, bodyBuffer: Buffer.alloc(0) });
          }
          return;
        }
        const contentLength = Number(headers.get('content-length') || 0);
        if (contentLength > MAX_PROXY_BYTES) {
          res.destroy();
          const err = new Error('Conteúdo excede o limite máximo permitido pelo Proxy XIQI.');
          err.statusCode = 413;
          return fail(err);
        }
        const chunks = [];
        let total = 0;
        res.on('data', chunk => {
          total += chunk.length;
          if (total > MAX_PROXY_BYTES) {
            res.destroy();
            const err = new Error('Conteúdo excede o limite máximo permitido pelo Proxy XIQI.');
            err.statusCode = 413;
            return fail(err);
          }
          chunks.push(chunk);
        });
        res.on('end', () => {
          if (settled) return;
          let buf = Buffer.concat(chunks);
          const enc = String(headers.get('content-encoding') || '').toLowerCase().trim();
          try {
            if (enc === 'gzip' || enc === 'x-gzip') {
              buf = zlib.gunzipSync(buf, { maxOutputLength: MAX_PROXY_BYTES });
            } else if (enc === 'deflate') {
              buf = zlib.inflateSync(buf, { maxOutputLength: MAX_PROXY_BYTES });
            } else if (enc === 'br') {
              buf = zlib.brotliDecompressSync(buf, { maxOutputLength: MAX_PROXY_BYTES });
            }
          } catch {
            const err = new Error('Falha ao decodificar ou tamanho excede o limite do Proxy XIQI.');
            err.statusCode = 413;
            return fail(err);
          }
          if (buf.length > MAX_PROXY_BYTES) {
            const err = new Error('Conteúdo excede o limite máximo permitido pelo Proxy XIQI.');
            err.statusCode = 413;
            return fail(err);
          }
          settled = true;
          resolve({ status, headers, bodyBuffer: buf });
        });
        res.on('error', fail);
      }
    );

    req.on('timeout', () => {
      req.destroy(new Error('Tempo limite excedido na conexão externa.'));
    });
    req.on('error', fail);
    req.end();
  });
}

async function safeExternalFetch(rawUrl, options = {}) {
  let currentUrl = rawUrl;
  const maxRedirects = 5;
  for (let hop = 0; hop <= maxRedirects; hop++) {
    const check = await validatePublicHttpUrl(currentUrl);
    if (!check.ok) {
      const err = new Error(check.reason);
      err.statusCode = 403;
      throw err;
    }
    const resp = await pinnedHttpRequest(check.url, check, options);
    if (resp.status >= 300 && resp.status < 400) {
      const loc = resp.headers.get('location');
      if (!loc) return { resp, finalUrl: check.url };
      currentUrl = new URL(loc, check.url).href;
      continue;
    }
    return { resp, finalUrl: check.url };
  }
  const err = new Error('Excesso de redirecionamentos.');
  err.statusCode = 502;
  throw err;
}

/* =====================================================================
   RATE LIMITING, BLOQUEIO CONTRA FORCA BRUTA E SANITIZACAO
   ===================================================================== */
function capMapSize(map, maxEntries) {
  while (map.size > maxEntries) {
    const firstKey = map.keys().next().value;
    if (firstKey === undefined) break;
    map.delete(firstKey);
  }
}

function pruneMapsIfNeeded(force = false) {
  const now = Date.now();
  if (force || activeUserTokens.size > 5000) {
    for (const [k, v] of activeUserTokens.entries()) {
      if (!v || now > v.exp) activeUserTokens.delete(k);
    }
    capMapSize(activeUserTokens, MAX_MAP_ENTRIES);
  }
  if (force || activeAdminTokens.size > 1000) {
    for (const [k, exp] of activeAdminTokens.entries()) {
      if (!exp || now > exp) activeAdminTokens.delete(k);
    }
    capMapSize(activeAdminTokens, 5000);
  }
  if (force || loginFails.size > 5000) {
    for (const [k, v] of loginFails.entries()) {
      if (!v || now > v.until) loginFails.delete(k);
    }
    capMapSize(loginFails, MAX_MAP_ENTRIES);
  }
  if (force || rateBuckets.size > 10000) {
    for (const [k, v] of rateBuckets.entries()) {
      if (!v || now > v.resetAt) rateBuckets.delete(k);
    }
    capMapSize(rateBuckets, MAX_MAP_ENTRIES);
  }
}

setInterval(() => pruneMapsIfNeeded(true), 5 * 60 * 1000).unref();

function isBlocked(key) {
  const rec = loginFails.get(key);
  if (!rec) return false;
  if (Date.now() > rec.until) {
    loginFails.delete(key);
    return false;
  }
  return rec.count >= 5;
}

function markFail(key) {
  pruneMapsIfNeeded();
  const rec = loginFails.get(key) || { count: 0, until: 0 };
  rec.count += 1;
  rec.until = Date.now() + 10 * 60 * 1000;
  loginFails.set(key, rec);
}

function rateLimit(bucketName, windowMs, maxRequests) {
  return (req, res, next) => {
    pruneMapsIfNeeded();
    const ip = req.ip || 'local';
    const key = bucketName + ':' + ip;
    const now = Date.now();
    let rec = rateBuckets.get(key);
    if (!rec || now > rec.resetAt) {
      rec = { count: 0, resetAt: now + windowMs };
    }
    rec.count += 1;
    rateBuckets.set(key, rec);
    if (rec.count > maxRequests) {
      return res.status(429).json({ error: 'Muitas requisições. Aguarde alguns instantes.' });
    }
    next();
  };
}

function stripProtoPollution(val, depth = 0) {
  if (depth > 8 || val === null || typeof val !== 'object') return val;
  if (Array.isArray(val)) {
    return val.slice(0, 200).map(item => stripProtoPollution(item, depth + 1));
  }
  const out = {};
  for (const [k, v] of Object.entries(val)) {
    if (k === '__proto__' || k === 'constructor' || k === 'prototype') continue;
    out[k] = stripProtoPollution(v, depth + 1);
  }
  return out;
}

app.disable('x-powered-by');
app.use(express.json({ limit: '128kb' }));

app.use('/api', (req, res, next) => {
  if (req.method === 'GET' || req.method === 'HEAD' || req.method === 'OPTIONS') {
    return next();
  }
  const secFetchSite = String(req.headers['sec-fetch-site'] || '').toLowerCase();
  if (secFetchSite === 'cross-site') {
    return res.status(403).json({ error: 'Requisição cross-site bloqueada por política CSRF.' });
  }
  const expectedHost = String(req.headers['x-forwarded-host'] || req.headers.host || '').split(',')[0].trim().toLowerCase();
  const origin = req.headers.origin;
  if (origin) {
    try {
      const originHost = new URL(origin).host.toLowerCase();
      if (!expectedHost || originHost !== expectedHost) {
        return res.status(403).json({ error: 'Origem não autorizada para esta operação.' });
      }
    } catch {
      return res.status(403).json({ error: 'Cabeçalho Origin inválido.' });
    }
  } else if (req.headers.referer) {
    try {
      const refHost = new URL(req.headers.referer).host.toLowerCase();
      if (!expectedHost || refHost !== expectedHost) {
        return res.status(403).json({ error: 'Referer não autorizado para esta operação.' });
      }
    } catch {
      return res.status(403).json({ error: 'Cabeçalho Referer inválido.' });
    }
  }
  next();
});

app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('X-DNS-Prefetch-Control', 'off');
  res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
  if (req.path.startsWith('/api/proxy')) {
    res.setHeader(
      'Content-Security-Policy',
      'sandbox allow-scripts allow-forms allow-popups allow-popups-to-escape-sandbox;'
    );
  } else {
    res.setHeader(
      'Content-Security-Policy',
      "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https: http:; connect-src 'self'; frame-src 'self' http: https:; object-src 'none'; base-uri 'self'; form-action 'self';"
    );
  }
  next();
});

function readJson(p, fb) {
  try {
    if (!fs.existsSync(p)) return fb;
    const raw = fs.readFileSync(p, 'utf8');
    if (!raw || !raw.trim()) return fb;
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' ? parsed : fb;
  } catch {
    return fb;
  }
}

function writeJson(p, d) {
  fs.mkdirSync(CONFIG_DIR, { recursive: true });
  const tmp = p + '.tmp-' + process.pid + '-' + crypto.randomBytes(4).toString('hex');
  fs.writeFileSync(tmp, JSON.stringify(d, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, p);
}

function hashSecret(p, s) {
  return crypto.scryptSync(String(p), String(s), 32).toString('hex');
}

function hashLegacySha256(pin, salt) {
  return crypto.createHash('sha256').update(String(salt) + ':' + String(pin)).digest('hex');
}

function verifyUserPin(user, pin) {
  if (!user || !user.salt || !user.pinHash) return false;
  if (user.hashAlgo === 'scrypt') {
    return safeEq(hashSecret(pin, user.salt), user.pinHash);
  }
  // Suporte de compatibilidade para contas antigas SHA-256 com upgrade automatico
  const okScrypt = safeEq(hashSecret(pin, user.salt), user.pinHash);
  if (okScrypt) return true;
  return safeEq(hashLegacySha256(pin, user.salt), user.pinHash);
}

function parseCookies(req) {
  const raw = String(req.headers.cookie || '');
  const map = {};
  raw.split(';').forEach(part => {
    const idx = part.indexOf('=');
    if (idx > 0) {
      const k = part.slice(0, idx).trim();
      const v = part.slice(idx + 1).trim();
      try {
        map[k] = decodeURIComponent(v);
      } catch {
        map[k] = v;
      }
    }
  });
  return map;
}

function issueUserSessionCookie(res, req, token) {
  const isHttps = req.secure || String(req.headers['x-forwarded-proto'] || '').includes('https');
  const attrs = [
    `xiqi_session=${encodeURIComponent(token)}`,
    'Path=/',
    'HttpOnly',
    isHttps ? 'SameSite=None' : 'SameSite=Lax',
    `Max-Age=${Math.floor(SESSION_TTL_MS / 1000)}`
  ];
  if (isHttps) attrs.push('Secure');
  res.setHeader('Set-Cookie', attrs.join('; '));
}

function clearUserSessionCookie(res, req) {
  const isHttps = req.secure || String(req.headers['x-forwarded-proto'] || '').includes('https');
  const attrs = ['xiqi_session=', 'Path=/', 'HttpOnly', isHttps ? 'SameSite=None' : 'SameSite=Lax', 'Max-Age=0'];
  if (isHttps) attrs.push('Secure');
  res.setHeader('Set-Cookie', attrs.join('; '));
}

function getAuthenticatedUserId(req) {
  const cookies = parseCookies(req);
  const token = String(req.headers['x-user-token'] || cookies.xiqi_session || '').trim();
  if (!token) return null;
  const rec = activeUserTokens.get(token);
  if (!rec || Date.now() > rec.exp) {
    activeUserTokens.delete(token);
    return null;
  }
  return rec.userId;
}

function createDefaultGuestSession() {
  return {
    searchEngine: 'xiqi',
    aiMode: false,
    aiHistory: [],
    notes: '',
    activeTabId: 'tab-guest-home',
    tabs: [{ id: 'tab-guest-home', title: 'Nova Aba', type: 'newtab', url: '' }],
    shortcuts: [
      { id: 'sc-g1', name: 'DuckDuckGo', url: 'https://duckduckgo.com' },
      { id: 'sc-g2', name: 'Bing', url: 'https://www.bing.com' },
      { id: 'sc-g3', name: 'Wikipédia', url: 'https://pt.wikipedia.org' }
    ]
  };
}

function isAllowedInternalOrPublicUrl(url) {
  const s = String(url || '').trim();
  return isSafeHttpUrl(s) || s.startsWith('/api/search?') || s.startsWith('/api/proxy?');
}

function sanitizeSessionPayload(rawSession) {
  const s = stripProtoPollution(rawSession || {});
  const validEngines = new Set(['xiqi', 'duckduckgo', 'bing']);
  const tabs = Array.isArray(s.tabs)
    ? s.tabs
        .filter(t => t && typeof t === 'object' && (t.type === 'newtab' || (t.type === 'web' && isAllowedInternalOrPublicUrl(t.url))))
        .slice(0, 20)
        .map(t => ({
          id: String(t.id || 'tab-' + Date.now()).slice(0, 64),
          title: String(t.title || 'Aba').slice(0, 60),
          type: t.type === 'web' ? 'web' : 'newtab',
          url: t.type === 'web' ? String(t.url || '').slice(0, 2000) : '',
          useProxy: Boolean(t.useProxy),
          embedReason: String(t.embedReason || '').slice(0, 140),
          history: Array.isArray(t.history)
            ? t.history.filter(u => isAllowedInternalOrPublicUrl(u)).slice(-20)
            : [],
          historyIndex: typeof t.historyIndex === 'number' ? Math.max(0, t.historyIndex) : 0
        }))
    : [];
  const finalTabs = tabs.length ? tabs : [{ id: 'tab-' + Date.now(), title: 'Nova Aba', type: 'newtab', url: '' }];
  const shortcuts = Array.isArray(s.shortcuts)
    ? s.shortcuts
        .filter(sc => sc && typeof sc.name === 'string' && isSafeHttpUrl(sc.url))
        .slice(0, 30)
        .map(sc => ({
          id: String(sc.id || 'sc-' + Date.now()).slice(0, 64),
          name: sc.name.trim().slice(0, 60),
          url: String(sc.url).slice(0, 2000)
        }))
    : [];
  const aiHistory = Array.isArray(s.aiHistory)
    ? s.aiHistory
        .filter(m => m && typeof m.text === 'string')
        .slice(-30)
        .map(m => ({
          role: m.role === 'model' ? 'model' : 'user',
          text: String(m.text).slice(0, 8000),
          sources: Array.isArray(m.sources)
            ? m.sources.filter(src => src && isSafeHttpUrl(src.uri)).slice(0, 8).map(src => ({
                title: String(src.title || '').slice(0, 120),
                uri: String(src.uri).slice(0, 1000)
              }))
            : []
        }))
    : [];

  return {
    searchEngine: validEngines.has(s.searchEngine) ? s.searchEngine : 'xiqi',
    aiMode: Boolean(s.aiMode),
    aiHistory,
    notes: typeof s.notes === 'string' ? s.notes.slice(0, 15000) : '',
    activeTabId: String(s.activeTabId || finalTabs[0].id).slice(0, 64),
    tabs: finalTabs,
    shortcuts
  };
}

function getAdmins() {
  const list = readJson(ADMINS_PATH, null);
  return Array.isArray(list) ? list : [];
}

function checkAdmin(req) {
  const tk = String(req.headers['x-admin-key'] || '');
  if (!tk) return false;
  if (safeEq(tk, getMasterKey())) return true;
  const exp = activeAdminTokens.get(tk);
  if (!exp || Date.now() > exp) {
    activeAdminTokens.delete(tk);
    return false;
  }
  return true;
}

/* =====================================================================
   AUTENTICACAO DE USUARIO E STORE ISOLADO (SEM EXPOSICAO DE HASHES)
   ===================================================================== */
app.get('/api/store', (req, res) => {
  const d = readJson(PROFILES_PATH, { users: [], guestSession: null });
  const authUserId = getAuthenticatedUserId(req);
  const users = Array.isArray(d.users) ? d.users : [];
  const activeUser = authUserId ? users.find(u => u.id === authUserId) : null;
  const guestSess = d.guestSession || createDefaultGuestSession();
  const activeSess = activeUser ? (activeUser.session || createDefaultGuestSession()) : null;

  res.json({
    activeUserId: activeUser ? activeUser.id : null,
    activeUser: activeUser
      ? {
          id: activeUser.id,
          name: activeUser.name,
          identifier: activeUser.identifier,
          color: activeUser.color || '#2563eb'
        }
      : null,
    users: users.map(u => ({
      id: u.id,
      name: u.name,
      color: u.color || '#2563eb'
    })),
    session: activeSess || guestSess,
    activeSession: activeSess,
    guestSession: guestSess
  });
});

app.post('/api/store', rateLimit('store_write', 60 * 1000, 60), (req, res) => {
  const inc = stripProtoPollution(req.body || {});
  const authUserId = getAuthenticatedUserId(req);
  const cur = readJson(PROFILES_PATH, {
    version: '1.0.0',
    organization: 'Corporação Engecema',
    users: [],
    guestSession: createDefaultGuestSession()
  });
  if (!Array.isArray(cur.users)) cur.users = [];

  if (authUserId) {
    const user = cur.users.find(u => u.id === authUserId);
    if (!user) return res.status(401).json({ error: 'Sessão inválida.' });
    if (inc.session && typeof inc.session === 'object') {
      const prevNotes = user.session && typeof user.session.notes === 'string' ? user.session.notes : '';
      user.session = sanitizeSessionPayload(inc.session);
      if (typeof inc.session.notes !== 'string') user.session.notes = prevNotes;
    }
  } else {
    const incomingGuest = inc.guestSession && typeof inc.guestSession === 'object'
      ? inc.guestSession
      : (inc.session && typeof inc.session === 'object' ? inc.session : null);
    if (incomingGuest) {
      const prevNotes = cur.guestSession && typeof cur.guestSession.notes === 'string' ? cur.guestSession.notes : '';
      cur.guestSession = sanitizeSessionPayload(incomingGuest);
      if (typeof incomingGuest.notes !== 'string') cur.guestSession.notes = prevNotes;
    }
  }

  writeJson(PROFILES_PATH, cur);
  res.json({ ok: true });
});

app.post('/api/auth/register', rateLimit('auth_reg', 60 * 1000, 10), (req, res) => {
  const body = stripProtoPollution(req.body || {});
  const name = typeof body.name === 'string' ? body.name.trim().slice(0, 80) : '';
  const identifier = typeof body.identifier === 'string' ? body.identifier.trim().slice(0, 120) : '';
  const pin = typeof body.pin === 'string' ? body.pin : '';

  if (!name || !identifier || !pin.trim() || pin.length < 4 || pin.length > 128) {
    return res.status(400).json({ error: 'Preencha Nome, E-mail/Usuário e Senha/PIN (4 a 128 caracteres).' });
  }

  const cur = readJson(PROFILES_PATH, {
    version: '1.0.0',
    organization: 'Corporação Engecema',
    users: [],
    guestSession: createDefaultGuestSession()
  });
  if (!Array.isArray(cur.users)) cur.users = [];

  if (cur.users.some(u => String(u.identifier || '').toLowerCase() === identifier.toLowerCase())) {
    return res.status(409).json({ error: 'Já existe um usuário com este identificador.' });
  }

  const palette = ['#2563eb', '#059669', '#7c3aed', '#d97706', '#0d9488', '#dc2626'];
  const salt = crypto.randomBytes(16).toString('hex');
  const pinHash = hashSecret(pin, salt);
  const recoveryCode = generateRecoveryCode();
  const recoverySalt = crypto.randomBytes(16).toString('hex');
  const recoveryHash = hashSecret(recoveryCode, recoverySalt);
  const userId = 'user-' + Date.now() + '-' + crypto.randomBytes(3).toString('hex');
  const initialTabId = 'tab-' + Date.now();
  const newUser = {
    id: userId,
    name,
    identifier,
    salt,
    pinHash,
    recoverySalt,
    recoveryHash,
    hashAlgo: 'scrypt',
    color: palette[cur.users.length % palette.length],
    createdAt: new Date().toISOString(),
    session: {
      searchEngine: 'xiqi',
      aiMode: false,
      aiHistory: [],
      notes: '',
      activeTabId: initialTabId,
      tabs: [{ id: initialTabId, title: 'Nova Aba', type: 'newtab', url: '' }],
      shortcuts: [
        { id: 'sc-' + Date.now() + '-1', name: 'DuckDuckGo', url: 'https://duckduckgo.com' },
        { id: 'sc-' + Date.now() + '-2', name: 'Bing', url: 'https://www.bing.com' },
        { id: 'sc-' + Date.now() + '-3', name: 'Wikipédia', url: 'https://pt.wikipedia.org' }
      ]
    }
  };

  cur.users.push(newUser);
  writeJson(PROFILES_PATH, cur);

  const token = crypto.randomBytes(32).toString('hex');
  activeUserTokens.set(token, { userId: newUser.id, exp: Date.now() + SESSION_TTL_MS });
  issueUserSessionCookie(res, req, token);

  res.json({
    ok: true,
    token,
    recoveryCode,
    activeUser: { id: newUser.id, name: newUser.name, identifier: newUser.identifier, color: newUser.color },
    users: cur.users.map(u => ({ id: u.id, name: u.name, color: u.color || '#2563eb' })),
    session: newUser.session,
    user: { id: newUser.id, name: newUser.name, identifier: newUser.identifier, color: newUser.color, session: newUser.session }
  });
});

app.post('/api/auth/login', rateLimit('auth_login', 60 * 1000, 20), (req, res) => {
  const ipKey = 'user:' + (req.ip || 'local');
  if (isBlocked(ipKey)) {
    return res.status(429).json({ error: 'Muitas tentativas inválidas. Bloqueado por 10 minutos.' });
  }
  const body = stripProtoPollution(req.body || {});
  const userIdParam = typeof body.userId === 'string' ? body.userId.trim().slice(0, 80) : '';
  const identifier = typeof body.identifier === 'string' ? body.identifier.trim().slice(0, 120) : '';
  const pin = typeof body.pin === 'string' ? body.pin : '';
  if ((!identifier && !userIdParam) || !pin || pin.length > 128) {
    return res.status(400).json({ error: 'Informe identificador e senha/PIN válidos.' });
  }

  const cur = readJson(PROFILES_PATH, { users: [], guestSession: createDefaultGuestSession() });
  const users = Array.isArray(cur.users) ? cur.users : [];
  const user = userIdParam
    ? users.find(u => u.id === userIdParam)
    : users.find(u => String(u.identifier || '').toLowerCase() === identifier.toLowerCase());

  const acctKey = 'acct:' + (user ? user.id : (userIdParam || identifier.toLowerCase()));
  if (isBlocked(acctKey)) {
    return res.status(429).json({ error: 'Conta temporariamente bloqueada após múltiplas tentativas inválidas. Aguarde 10 minutos.' });
  }

  if (!user || !verifyUserPin(user, pin)) {
    markFail(ipKey);
    markFail(acctKey);
    return res.status(401).json({ error: 'Credenciais inválidas.' });
  }

  loginFails.delete(ipKey);
  loginFails.delete(acctKey);

  // Migra hash legado automaticamente para scrypt
  if (user.hashAlgo !== 'scrypt') {
    const newSalt = crypto.randomBytes(16).toString('hex');
    user.salt = newSalt;
    user.pinHash = hashSecret(pin, newSalt);
    user.hashAlgo = 'scrypt';
    writeJson(PROFILES_PATH, cur);
  }

  const token = crypto.randomBytes(32).toString('hex');
  activeUserTokens.set(token, { userId: user.id, exp: Date.now() + SESSION_TTL_MS });
  issueUserSessionCookie(res, req, token);
  const userSession = user.session || createDefaultGuestSession();

  res.json({
    ok: true,
    token,
    activeUser: {
      id: user.id,
      name: user.name,
      identifier: user.identifier,
      color: user.color || '#2563eb'
    },
    users: users.map(u => ({ id: u.id, name: u.name, color: u.color || '#2563eb' })),
    session: userSession,
    user: {
      id: user.id,
      name: user.name,
      identifier: user.identifier,
      color: user.color || '#2563eb',
      session: userSession
    }
  });
});

app.post('/api/auth/reset-password', rateLimit('auth_reset', 60 * 1000, 10), (req, res) => {
  const ipKey = 'reset:' + (req.ip || 'local');
  if (isBlocked(ipKey)) {
    return res.status(429).json({ error: 'Muitas tentativas inválidas. Bloqueado por 10 minutos.' });
  }
  const body = stripProtoPollution(req.body || {});
  const identifier = typeof body.identifier === 'string' ? body.identifier.trim().slice(0, 120) : '';
  const recoveryCode = typeof body.recoveryCode === 'string' ? body.recoveryCode.trim().slice(0, 256) : '';
  const newPin = typeof body.newPin === 'string' ? body.newPin : '';

  if (!identifier || !recoveryCode || !newPin.trim() || newPin.length < 4 || newPin.length > 128) {
    return res.status(400).json({ error: 'Preencha usuário, código de recuperação/chave mestra e nova senha (4 a 128 caracteres).' });
  }

  const cur = readJson(PROFILES_PATH, { users: [], guestSession: createDefaultGuestSession() });
  const users = Array.isArray(cur.users) ? cur.users : [];
  const user = users.find(u =>
    String(u.identifier || '').toLowerCase() === identifier.toLowerCase() ||
    String(u.name || '').toLowerCase() === identifier.toLowerCase()
  );

  const acctKey = 'reset_acct:' + (user ? user.id : identifier.toLowerCase());
  if (isBlocked(acctKey)) {
    return res.status(429).json({ error: 'Muitas tentativas inválidas para esta conta. Aguarde 10 minutos.' });
  }

  const isMasterValid = safeEq(recoveryCode, getMasterKey());
  const isUserCodeValid = Boolean(
    user &&
    user.recoverySalt &&
    user.recoveryHash &&
    safeEq(hashSecret(recoveryCode.toUpperCase(), user.recoverySalt), user.recoveryHash)
  );

  if (!user || (!isMasterValid && !isUserCodeValid)) {
    markFail(ipKey);
    markFail(acctKey);
    return res.status(403).json({ error: 'Usuário ou código de recuperação/chave mestra inválido.' });
  }

  loginFails.delete(ipKey);
  loginFails.delete(acctKey);

  const newSalt = crypto.randomBytes(16).toString('hex');
  user.salt = newSalt;
  user.pinHash = hashSecret(newPin, newSalt);
  user.hashAlgo = 'scrypt';

  const nextRecoveryCode = generateRecoveryCode();
  const nextRecoverySalt = crypto.randomBytes(16).toString('hex');
  user.recoverySalt = nextRecoverySalt;
  user.recoveryHash = hashSecret(nextRecoveryCode, nextRecoverySalt);

  // Revoga todas as sessões anteriores do usuário após troca de senha
  for (const [tok, rec] of activeUserTokens.entries()) {
    if (rec && rec.userId === user.id) activeUserTokens.delete(tok);
  }

  writeJson(PROFILES_PATH, cur);
  res.json({ ok: true, recoveryCode: nextRecoveryCode });
});

app.post('/api/auth/logout', (req, res) => {
  const cookies = parseCookies(req);
  const token = String(req.headers['x-user-token'] || cookies.xiqi_session || '').trim();
  if (token) activeUserTokens.delete(token);
  clearUserSessionCookie(res, req);
  const cur = readJson(PROFILES_PATH, { users: [], guestSession: createDefaultGuestSession() });
  const users = Array.isArray(cur.users) ? cur.users : [];
  res.json({
    ok: true,
    users: users.map(u => ({ id: u.id, name: u.name, color: u.color || '#2563eb' })),
    session: cur.guestSession || createDefaultGuestSession()
  });
});

/* =====================================================================
   ADMIN APIs COM BLOQUEIO ANTI-FORCA-BRUTA E RATE LIMIT
   ===================================================================== */
app.post('/api/admin/login', rateLimit('admin_login', 60 * 1000, 15), (req, res) => {
  const ip = 'admin:' + (req.ip || 'local');
  if (isBlocked(ip)) return res.status(429).json({ error: 'Bloqueado por 10 min após 5 falhas.' });
  const body = stripProtoPollution(req.body || {});
  const email = typeof body.email === 'string' ? body.email.trim().toLowerCase().slice(0, 120) : '';
  const password = typeof body.password === 'string' ? body.password : '';
  if (!email || !password || password.length > 128) {
    return res.status(400).json({ error: 'Informe e-mail e senha válidos.' });
  }
  const acctKey = 'admin_acct:' + email;
  if (isBlocked(acctKey)) return res.status(429).json({ error: 'Conta administrativa temporariamente bloqueada.' });
  const adm = getAdmins().find(a => String(a.email || '').toLowerCase() === email);
  if (!adm || !safeEq(hashSecret(password, adm.salt), adm.hash)) {
    markFail(ip);
    markFail(acctKey);
    return res.status(401).json({ error: 'E-mail ou senha inválidos.' });
  }
  loginFails.delete(ip);
  loginFails.delete(acctKey);
  const tk = crypto.randomBytes(32).toString('hex');
  activeAdminTokens.set(tk, Date.now() + ADMIN_TTL_MS);
  res.json({ ok: true, token: tk });
});

app.post('/api/admin/logout', (req, res) => {
  const tk = String(req.headers['x-admin-key'] || '');
  if (tk) activeAdminTokens.delete(tk);
  res.json({ ok: true });
});

app.post('/api/admin/register', rateLimit('admin_mkey', 60 * 1000, 10), (req, res) => {
  const ip = 'mkey:' + (req.ip || 'local');
  if (isBlocked(ip)) return res.status(429).json({ error: 'Bloqueado por 10 min após 5 falhas.' });
  const body = stripProtoPollution(req.body || {});
  const name = typeof body.name === 'string' ? body.name.trim().slice(0, 80) : '';
  const em = typeof body.email === 'string' ? body.email.trim().toLowerCase().slice(0, 120) : '';
  const password = typeof body.password === 'string' ? body.password : '';
  const masterKey = typeof body.masterKey === 'string' ? body.masterKey.slice(0, 256) : '';
  if (!safeEq(masterKey, getMasterKey())) {
    markFail(ip);
    return res.status(403).json({ error: 'Chave mestra inválida.' });
  }
  loginFails.delete(ip);
  if (!name || !em.includes('@') || !password.trim() || password.length < 4 || password.length > 128) {
    return res.status(400).json({ error: 'Preencha Nome, E-mail e Senha (4 a 128 caracteres).' });
  }
  const list = getAdmins();
  if (list.some(a => String(a.email || '').toLowerCase() === em)) {
    return res.status(409).json({ error: 'E-mail já cadastrado.' });
  }
  const salt = crypto.randomBytes(16).toString('hex');
  list.push({
    id: 'adm-' + Date.now() + '-' + crypto.randomBytes(3).toString('hex'),
    name,
    email: em,
    salt,
    hash: hashSecret(password, salt),
    createdAt: new Date().toISOString()
  });
  writeJson(ADMINS_PATH, list);
  res.json({ ok: true });
});

app.post('/api/admin/reset-password', rateLimit('admin_mkey', 60 * 1000, 10), (req, res) => {
  const ip = 'mkey:' + (req.ip || 'local');
  if (isBlocked(ip)) return res.status(429).json({ error: 'Bloqueado por 10 min após 5 falhas.' });
  const body = stripProtoPollution(req.body || {});
  const em = typeof body.email === 'string' ? body.email.trim().toLowerCase().slice(0, 120) : '';
  const masterKey = typeof body.masterKey === 'string' ? body.masterKey.slice(0, 256) : '';
  const newPassword = typeof body.newPassword === 'string' ? body.newPassword : '';
  if (!safeEq(masterKey, getMasterKey())) {
    markFail(ip);
    return res.status(403).json({ error: 'Chave mestra inválida.' });
  }
  loginFails.delete(ip);
  const list = getAdmins();
  const adm = list.find(a => String(a.email || '').toLowerCase() === em);
  if (!adm || !newPassword.trim() || newPassword.length < 4 || newPassword.length > 128) {
    return res.status(400).json({ error: 'Dados inválidos.' });
  }
  const salt = crypto.randomBytes(16).toString('hex');
  adm.salt = salt;
  adm.hash = hashSecret(newPassword, salt);
  writeJson(ADMINS_PATH, list);
  activeAdminTokens.clear();
  res.json({ ok: true });
});

app.get('/api/admin/users', rateLimit('admin_api', 60 * 1000, 30), (req, res) => {
  const ip = 'admin_api:' + (req.ip || 'local');
  if (isBlocked(ip)) return res.status(429).json({ error: 'Bloqueado por 10 min após 5 falhas.' });
  if (!checkAdmin(req)) {
    markFail(ip);
    return res.status(403).json({ error: 'Negado.' });
  }
  loginFails.delete(ip);
  const d = readJson(PROFILES_PATH, { users: [] });
  res.json({ users: (d.users || []).map(u => ({ id: u.id, name: u.name, identifier: u.identifier })) });
});

app.delete('/api/admin/users/:id', rateLimit('admin_api', 60 * 1000, 30), (req, res) => {
  const ip = 'admin_api:' + (req.ip || 'local');
  if (isBlocked(ip)) return res.status(429).json({ error: 'Bloqueado por 10 min após 5 falhas.' });
  if (!checkAdmin(req)) {
    markFail(ip);
    return res.status(403).json({ error: 'Negado.' });
  }
  loginFails.delete(ip);
  const targetId = String(req.params.id || '').trim().slice(0, 80);
  if (!targetId) return res.status(400).json({ error: 'ID inválido.' });
  const d = readJson(PROFILES_PATH, { users: [], guestSession: createDefaultGuestSession() });
  d.users = (d.users || []).filter(u => u.id !== targetId);
  for (const [tok, rec] of activeUserTokens.entries()) {
    if (rec.userId === targetId) activeUserTokens.delete(tok);
  }
  writeJson(PROFILES_PATH, d);
  res.json({ ok: true });
});

/* =====================================================================
   BUSCA WEB RESILIENTE (XIQI BUSCA / DUCKDUCKGO / BING + FALLBACK IA)
   ===================================================================== */
const SEARCH_HEADERS = {
  'User-Agent': 'XIQI-OS/1.0 (XIQI Core x86_64; Corporacao Engecema)',
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Language': 'pt-BR,pt;q=0.9,en;q=0.8'
};

function stripTags(html) {
  return String(html || '')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&nbsp;/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function decodeDdgUrl(rawHref) {
  let href = String(rawHref || '').trim();
  if (href.startsWith('//')) href = 'https:' + href;
  if (href.includes('uddg=')) {
    try {
      href = decodeURIComponent(href.split('uddg=').at(1).split('&').at(0));
    } catch {}
  }
  return href;
}

async function searchDuckDuckGo(query) {
  try {
    const r = await fetch('https://html.duckduckgo.com/html/?kl=br-pt&q=' + encodeURIComponent(query), {
      headers: SEARCH_HEADERS,
      signal: AbortSignal.timeout(8000)
    });
    if (!r.ok) return [];
    const html = await r.text();
    if (html.includes('anomaly-modal') || html.includes('challenge-form')) return [];
    const items = [];
    const blocks = html.split(/class="[^"]*result__body[^"]*"/i).slice(1, 16);
    for (const block of blocks) {
      const aTag = block.match(/<a\b([^>]*class="[^"]*result__a[^"]*"[^>]*)>([\s\S]*?)<\/a>/i);
      if (!aTag) continue;
      const attrs = aTag[1] || '';
      const hrefMatch = attrs.match(/\bhref=["']([^"']+)["']/i);
      if (!hrefMatch) continue;
      const href = decodeDdgUrl(hrefMatch[1]);
      const title = stripTags(aTag[2]);
      const snipMatch = block.match(/<(?:a|div|span)\b[^>]*class="[^"]*result__snippet[^"]*"[^>]*>([\s\S]*?)<\/(?:a|div|span)>/i);
      const snippet = snipMatch ? stripTags(snipMatch[1]) : '';
      if (isSafeHttpUrl(href) && title) {
        items.push({ title, href, snippet });
      }
    }
    return items;
  } catch {
    return [];
  }
}

async function searchBingHtml(query) {
  try {
    const r = await fetch('https://www.bing.com/search?q=' + encodeURIComponent(query) + '&setlang=pt-BR', {
      headers: SEARCH_HEADERS,
      signal: AbortSignal.timeout(8000)
    });
    if (!r.ok) return [];
    const html = await r.text();
    const items = [];
    const blocks = html.split(/<li\b[^>]*class="[^"]*\bb_algo\b[^"]*"[^>]*>/i).slice(1, 16);
    for (const block of blocks) {
      const h2Match = block.match(/<h2[^>]*>[\s\S]*?<a\b([^>]*)>([\s\S]*?)<\/a>[\s\S]*?<\/h2>/i);
      if (!h2Match) continue;
      const hrefMatch = (h2Match[1] || '').match(/\bhref=["']([^"']+)["']/i);
      if (!hrefMatch) continue;
      const href = hrefMatch[1];
      const title = stripTags(h2Match[2]);
      const snipMatch = block.match(/<p[^>]*>([\s\S]*?)<\/p>/i);
      const snippet = snipMatch ? stripTags(snipMatch[1]) : '';
      if (isSafeHttpUrl(href) && title) {
        items.push({ title, href, snippet });
      }
    }
    return items;
  } catch {
    return [];
  }
}

async function searchWikipediaPt(query) {
  try {
    const r = await fetch(
      'https://pt.wikipedia.org/w/api.php?action=query&list=search&srsearch=' +
        encodeURIComponent(query) +
        '&format=json&utf8=1&srlimit=6',
      { headers: { 'User-Agent': 'XIQIOS/1.0' }, signal: AbortSignal.timeout(6000) }
    );
    if (!r.ok) return [];
    const data = await r.json();
    const list = (data && data.query && data.query.search) || [];
    return list.map(item => ({
      title: String(item.title || '') + ' — Wikipédia',
      href: 'https://pt.wikipedia.org/wiki/' + encodeURIComponent(String(item.title || '').replace(/ /g, '_')),
      snippet: stripTags(item.snippet || '')
    }));
  } catch {
    return [];
  }
}

async function withTimeout(promise, ms, label = 'Timeout') {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => {
          const err = new Error(label);
          err.status = 504;
          reject(err);
        }, ms);
      })
    ]);
  } finally {
    clearTimeout(timer);
  }
}

async function searchWithXiqiAi(query) {
  try {
    const ai = await getXiqiAIClient();
    if (!ai) return [];
    const response = await withTimeout(
      ai.models.generateContent({
        model: 'gemini-4-hydrogen',
        contents: 'Liste os principais links oficiais e páginas web relevantes em português para a pesquisa: ' + query,
        config: {
          tools: [{ googleSearch: {} }]
        }
      }),
      12000,
      'Tempo limite na busca XIQI AI.'
    );
    const chunks = response?.candidates?.[0]?.groundingMetadata?.groundingChunks || [];
    const seen = new Set();
    const items = [];
    for (const chunk of chunks) {
      const uri = chunk?.web?.uri;
      const title = chunk?.web?.title;
      if (uri && isSafeHttpUrl(uri) && !seen.has(uri)) {
        seen.add(uri);
        items.push({ title: title || uri, href: uri, snippet: '' });
      }
    }
    return items;
  } catch {
    return [];
  }
}

app.get('/api/search', rateLimit('search', 60 * 1000, 45), async (req, res) => {
  const q = String(req.query.q || '').trim().slice(0, 300);
  const engineParam = String(req.query.engine || 'xiqi').toLowerCase();
  const engineMap = {
    xiqi: { label: 'Pesquisa XIQI', extUrl: 'https://duckduckgo.com/?q=' + encodeURIComponent(q) },
    duckduckgo: { label: 'DuckDuckGo', extUrl: 'https://duckduckgo.com/?q=' + encodeURIComponent(q) },
    bing: { label: 'Bing', extUrl: 'https://www.bing.com/search?q=' + encodeURIComponent(q) }
  };
  const eng = engineMap[engineParam] || engineMap.xiqi;

  if (!q) return res.status(400).type('text/plain').send('Digite um termo para pesquisar.');

  try {
    let items = [];
    if (engineParam === 'bing') {
      items = await searchBingHtml(q);
      if (items.length === 0) items = await searchDuckDuckGo(q);
    } else if (engineParam === 'duckduckgo') {
      items = await searchDuckDuckGo(q);
      if (items.length === 0) items = await searchBingHtml(q);
    } else {
      items = await searchWithXiqiAi(q);
      if (items.length === 0) items = await searchDuckDuckGo(q);
      if (items.length === 0) items = await searchBingHtml(q);
    }
    if (items.length === 0) {
      items = await searchWikipediaPt(q);
    }

    const cards = items.length
      ? items
          .map(
            i =>
              `<article class="res-card">
                <a class="res-title" href="${escHtml(i.href)}" data-xiqi-open="1">${escHtml(i.title)}</a>
                <div class="res-url-row">
                  <span class="res-url">${escHtml(i.href)}</span>
                  <a class="res-ext" href="${escHtml(i.href)}" target="_blank" rel="noopener noreferrer">Abrir fora ↗</a>
                </div>
                ${i.snippet ? `<p class="res-snip">${escHtml(i.snippet)}</p>` : ''}
              </article>`
          )
          .join('')
      : `<div class="res-empty">
           <p>Não foi possível obter resultados diretos neste momento para <strong>${escHtml(q)}</strong>.</p>
           <a class="res-ext-btn" href="${escHtml(eng.extUrl)}" target="_blank" rel="noopener noreferrer">Pesquisar diretamente no ${escHtml(eng.label)} ↗</a>
         </div>`;

    const htmlPage = `<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Busca XIQI — ${escHtml(q)}</title>
  <style>
    body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif;background:#f8fafc;color:#0f172a;margin:0;padding:20px 24px}
    .wrap{max-width:860px;margin:0 auto}
    .head{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:12px;margin-bottom:18px;padding-bottom:12px;border-bottom:1px solid #e2e8f0}
    .head h2{margin:0;font-size:18px;font-weight:600}
    .badge{display:inline-block;background:#eff6ff;color:#1d4ed8;border:1px solid #bfdbfe;border-radius:9999px;padding:2px 10px;font-size:12px;font-weight:600;margin-left:8px}
    .res-ext-btn{display:inline-block;background:#2563eb;color:#fff;text-decoration:none;padding:7px 14px;border-radius:6px;font-size:12px;font-weight:600}
    .res-ext-btn:hover{background:#1d4ed8}
    .res-card{margin-bottom:12px;padding:14px 16px;background:#fff;border-radius:10px;border:1px solid #e2e8f0;transition:border-color 140ms ease,box-shadow 140ms ease}
    .res-card:hover{border-color:#cbd5e1;box-shadow:0 2px 8px rgba(15,23,42,.06)}
    .res-title{font-size:16px;color:#1d4ed8;font-weight:600;text-decoration:none;display:inline-block}
    .res-title:hover{text-decoration:underline}
    .res-url-row{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-top:4px}
    .res-url{font-size:12px;color:#15803d;word-break:break-all}
    .res-ext{font-size:11px;color:#475569;text-decoration:none;white-space:nowrap;border:1px solid #e2e8f0;padding:2px 7px;border-radius:5px;background:#f8fafc}
    .res-ext:hover{background:#f1f5f9;color:#0f172a}
    .res-snip{margin:8px 0 0;font-size:13px;color:#475569;line-height:1.5}
    .res-empty{background:#fff;border:1px solid #e2e8f0;border-radius:10px;padding:24px;text-align:center}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="head">
      <h2>Resultados para: ${escHtml(q)} <span class="badge">${escHtml(eng.label)}</span></h2>
      <a class="res-ext-btn" href="${escHtml(eng.extUrl)}" target="_blank" rel="noopener noreferrer">Abrir no ${escHtml(eng.label)} ↗</a>
    </div>
    ${cards}
  </div>
  <script>
    document.querySelectorAll('a[data-xiqi-open="1"]').forEach(function(link) {
      link.addEventListener('click', function(e) {
        if (window.parent && window.parent !== window) {
          e.preventDefault();
          window.parent.postMessage({
            type: 'xiqi-open-url',
            url: link.href,
            title: link.textContent.trim()
          }, '*');
        }
      });
    });
  </script>
</body>
</html>`;

    res.type('html').send(htmlPage);
  } catch {
    res.status(502).type('text/plain').send('Erro ao consultar mecanismo de pesquisa.');
  }
});

/* =====================================================================
   VERIFICACAO DE EMBED & PROXY WEB COM PROTECAO ANTI-SSRF E SANDBOX
   ===================================================================== */
function headersBlockIframe(headers) {
  const xfo = String(headers.get('x-frame-options') || '').toLowerCase();
  if (xfo.includes('deny') || xfo.includes('sameorigin')) {
    return 'X-Frame-Options: ' + xfo;
  }
  const csp = String(headers.get('content-security-policy') || '').toLowerCase();
  if (csp.includes('frame-ancestors')) {
    const match = csp.match(/frame-ancestors\s+([^;]+)/);
    const val = match ? match[1].trim() : '';
    if (val === "'none'" || val === "'self'" || !val.includes('*')) {
      return 'CSP frame-ancestors';
    }
  }
  return '';
}

app.get('/api/check-embed', rateLimit('embed', 60 * 1000, 60), async (req, res) => {
  const rawUrl = String(req.query.url || '').trim().slice(0, 2000);
  const check = await validatePublicHttpUrl(rawUrl);
  if (!check.ok) {
    return res.status(403).json({ embeddable: false, reason: check.reason, finalUrl: rawUrl });
  }
  try {
    let { resp, finalUrl } = await safeExternalFetch(check.url, {
      method: 'HEAD',
      headOnly: true,
      headers: SEARCH_HEADERS,
      timeoutMs: 6000
    });
    if (resp.status === 405 || resp.status === 501) {
      const retry = await safeExternalFetch(check.url, {
        method: 'GET',
        headOnly: true,
        headers: SEARCH_HEADERS,
        timeoutMs: 6000
      });
      resp = retry.resp;
      finalUrl = retry.finalUrl;
    }
    const reason = headersBlockIframe(resp.headers);
    res.json({
      embeddable: !reason,
      reason,
      finalUrl
    });
  } catch (err) {
    res.json({
      embeddable: false,
      reason: err && err.statusCode === 403 ? err.message : 'Conexão bloqueada ou indisponível',
      finalUrl: rawUrl
    });
  }
});

app.get('/api/proxy', rateLimit('proxy', 60 * 1000, 60), async (req, res) => {
  const rawUrl = String(req.query.url || '').trim().slice(0, 2000);
  const check = await validatePublicHttpUrl(rawUrl);
  if (!check.ok) {
    return res.status(403).type('text/plain').send(check.reason);
  }
  try {
    const { resp: upstream, finalUrl } = await safeExternalFetch(check.url, {
      method: 'GET',
      headers: SEARCH_HEADERS,
      timeoutMs: 15000
    });
    const safeStatus = (upstream.status >= 200 && upstream.status <= 599) ? upstream.status : 502;
    const rawContentType = String(upstream.headers.get('content-type') || 'application/octet-stream').replace(/[\r\n]/g, '');
    const mimeOnly = rawContentType.split(';')[0].trim().toLowerCase();
    const rawBuf = upstream.bodyBuffer || Buffer.alloc(0);

    if (mimeOnly === 'text/html' || mimeOnly === 'application/xhtml+xml') {
      let html = rawBuf.toString('utf8');
      html = html.replace(
        /<meta[^>]+http-equiv=["']?(?:Content-Security-Policy|X-Frame-Options)["']?[^>]*>/gi,
        ''
      );
      html = html.replace(/<base\b[^>]*>/gi, '');

      const parsedFinal = new URL(finalUrl);
      const baseTag = `<base href="${escHtml(parsedFinal.href)}">`;
      const safeFinalUrlJson = safeJsonForScript(finalUrl);
      const safeHostnameJson = safeJsonForScript(parsedFinal.hostname);
      const bridgeScript = `<script>
(function(){
  try {
    window.parent.postMessage({
      type: 'xiqi-proxy-loaded',
      url: ${safeFinalUrlJson},
      title: document.title || ${safeHostnameJson}
    }, '*');
  } catch(e){}
  document.addEventListener('click', function(ev) {
    var a = ev.target && ev.target.closest ? ev.target.closest('a[href]') : null;
    if (!a) return;
    var href = a.getAttribute('href') || '';
    if (!href || href.startsWith('#') || href.startsWith('javascript:') || href.startsWith('mailto:') || a.hasAttribute('download')) return;
    try {
      var abs = new URL(href, ${safeFinalUrlJson}).href;
      if (/^https?:/i.test(abs)) {
        ev.preventDefault();
        var nextProxy = '/api/proxy?url=' + encodeURIComponent(abs);
        window.parent.postMessage({ type: 'xiqi-proxy-navigate', url: abs }, '*');
        window.location.href = nextProxy;
      }
    } catch(e){}
  }, true);
  document.addEventListener('submit', function(ev) {
    var f = ev.target;
    if (!f || (f.method && f.method.toLowerCase() !== 'get')) return;
    try {
      var action = f.getAttribute('action') || ${safeFinalUrlJson};
      var abs = new URL(action, ${safeFinalUrlJson});
      var fd = new FormData(f);
      fd.forEach(function(v, k){ abs.searchParams.set(k, String(v)); });
      ev.preventDefault();
      window.parent.postMessage({ type: 'xiqi-proxy-navigate', url: abs.href }, '*');
      window.location.href = '/api/proxy?url=' + encodeURIComponent(abs.href);
    } catch(e){}
  }, true);
})();
</script>`;

      if (/<head[^>]*>/i.test(html)) {
        html = html.replace(/<head([^>]*)>/i, `<head$1>${baseTag}`);
      } else {
        html = baseTag + html;
      }
      const lastBodyIdx = html.toLowerCase().lastIndexOf('</body>');
      if (lastBodyIdx !== -1) {
        html = html.slice(0, lastBodyIdx) + bridgeScript + html.slice(lastBodyIdx);
      } else {
        html += bridgeScript;
      }

      res.status(safeStatus).type('text/html; charset=utf-8').send(html);
      return;
    }

    res.status(safeStatus).setHeader('Content-Type', rawContentType || 'application/octet-stream').send(rawBuf);
  } catch (err) {
    if (res.headersSent) return;
    const status = err && err.statusCode === 403 ? 403 : (err && err.statusCode === 413 ? 413 : 502);
    const safeExternalHref = isSafeHttpUrl(rawUrl) ? escHtml(rawUrl) : '#';
    res.status(status).type('text/html; charset=utf-8').send(`<!DOCTYPE html>
<html lang="pt-BR"><head><meta charset="utf-8"><title>Acesso indisponível</title></head>
<body style="font-family:sans-serif;padding:32px;background:#f8fafc;color:#0f172a;text-align:center">
  <h2>Não foi possível carregar este endereço pelo Proxy XIQI</h2>
  <p style="color:#475569">${escHtml(err && (err.statusCode === 403 || err.statusCode === 413) ? err.message : rawUrl)}</p>
  ${safeExternalHref !== '#' ? `<a href="${safeExternalHref}" target="_blank" rel="noopener noreferrer" style="display:inline-block;margin-top:12px;padding:10px 18px;background:#2563eb;color:#fff;text-decoration:none;border-radius:6px;font-weight:600">Abrir em nova janela ↗</a>` : ''}
</body></html>`);
  }
});

/* =====================================================================
   MODO XIQI AI (API SERVER-SIDE COM GROUNDING DE PESQUISA)
   ===================================================================== */
async function callXiqiAiWithRetry(ai, params, maxRetries = 1) {
  let lastErr;
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      return await withTimeout(ai.models.generateContent(params), 25000, 'Tempo limite excedido ao consultar a XIQI AI.');
    } catch (err) {
      lastErr = err;
      const msg = String(err?.message || '');
      const status = err?.status || err?.code;
      const transient = status === 429 || (status >= 500 && status < 600) || msg.includes('ECONNRESET');
      if (!transient || attempt === maxRetries) throw err;
      await new Promise(r => setTimeout(r, 800 * (attempt + 1)));
    }
  }
  throw lastErr;
}

app.post('/api/ai', rateLimit('ai', 60 * 1000, 25), async (req, res) => {
  try {
    const body = stripProtoPollution(req.body || {});
    const prompt = typeof body.prompt === 'string' ? body.prompt.trim().slice(0, 8000) : '';
    const rawHistory = Array.isArray(body.history) ? body.history : [];
    if (!prompt) return res.status(400).json({ error: 'Digite uma pergunta.' });

    const ai = await getXiqiAIClient();
    if (!ai) {
      return res.status(503).json({
        error: 'Chave XIQI_AI_KEY não configurada no servidor para o Modo XIQI AI.'
      });
    }

    const contents = rawHistory
      .slice(-10)
      .filter(m => m && typeof m.text === 'string' && m.text.trim())
      .map(m => ({
        role: m.role === 'model' ? 'model' : 'user',
        parts: [{ text: String(m.text).slice(0, 8000) }]
      }));

    contents.push({
      role: 'user',
      parts: [{ text: prompt }]
    });

    const response = await callXiqiAiWithRetry(ai, {
      model: 'gemini-4-hydrogen',
      contents,
      config: {
        systemInstruction:
          'Você é a XIQI AI, assistente oficial do sistema operacional XIQI OS v1.0 (Corporação Engecema). Responda sempre em português do Brasil de forma clara, objetiva e precisa.',
        tools: [{ googleSearch: {} }]
      }
    });

    const answerText = String(response?.text || '').trim();
    if (!answerText) {
      return res.status(502).json({ error: 'A XIQI AI retornou uma resposta vazia.' });
    }

    const chunks = response?.candidates?.[0]?.groundingMetadata?.groundingChunks || [];
    const seen = new Set();
    const sources = [];
    for (const chunk of chunks) {
      const uri = chunk?.web?.uri;
      const title = chunk?.web?.title;
      if (uri && isSafeHttpUrl(uri) && !seen.has(uri)) {
        seen.add(uri);
        sources.push({ title: title || uri, uri });
      }
    }

    res.json({ text: answerText, sources });
  } catch (err) {
    const status = Number(err?.status) || 500;
    const rawMsg = String(err?.message || '');
    if (status === 400 || status === 403 || rawMsg.includes('API_KEY_INVALID') || rawMsg.includes('PERMISSION_DENIED')) {
      return res.status(status).json({
        error: 'Chave XIQI_AI_KEY inválida ou sem permissão no Modo XIQI AI.'
      });
    }
    if (status === 429 || rawMsg.includes('RESOURCE_EXHAUSTED')) {
      return res.status(429).json({
        error: 'Limite de requisições da XIQI AI atingido. Tente novamente em instantes.'
      });
    }
    res.status(502).json({
      error: 'Falha ao consultar a XIQI AI: ' + (rawMsg || 'erro inesperado no servidor.')
    });
  }
});

/* =====================================================================
   SISTEMA, TERMINAL SEGURO E NOTAS ISOLADAS POR USUARIO
   ===================================================================== */
app.get('/api/system', (req, res) => {
  const freeMb = Math.round(os.freemem() / 1024 / 1024);
  const totalMb = Math.round(os.totalmem() / 1024 / 1024);
  const uptimeMin = Math.floor(os.uptime() / 60);
  const info = {
    os: 'XIQI OS v1.0',
    kernel: 'XIQI Core x86_64',
    edition: 'Data Center Independente — Corporação Engecema',
    freeMemMb: freeMb,
    totalMemMb: totalMb,
    uptimeMin
  };
  info.text =
    `Status ${info.os} (${info.edition})\n` +
    `• Núcleo: ${info.kernel}\n` +
    `• Memória Livre: ${freeMb} MB / ${totalMb} MB\n` +
    `• Ativo há: ${uptimeMin} min`;
  res.json(info);
});

app.post('/api/terminal', rateLimit('terminal', 60 * 1000, 30), (req, res) => {
  const ip = 'mkey:' + (req.ip || 'local');
  if (isBlocked(ip)) {
    return res.status(429).json({ output: 'Bloqueado por 10 min após 5 tentativas inválidas.' });
  }
  const body = stripProtoPollution(req.body || {});
  const cmd = typeof body.cmd === 'string' ? body.cmd.slice(0, 200) : '';
  const masterKey = typeof body.masterKey === 'string' ? body.masterKey.slice(0, 256) : '';
  if (!safeEq(masterKey, getMasterKey())) {
    markFail(ip);
    return res.status(403).json({ output: 'Acesso negado: Chave Mestra inválida.' });
  }
  loginFails.delete(ip);
  const raw = cmd.trim();
  const low = raw.toLowerCase();

  if (!raw || low === 'help') {
    return res.json({
      output:
        'Comandos disponíveis (Console Seguro XIQI OS):\n' +
        '  help        - Lista comandos\n' +
        '  status      - Status de memória e tempo ativo\n' +
        '  uname       - Núcleo e arquitetura XIQI OS\n' +
        '  hostname    - Nome do servidor\n' +
        '  free        - Uso de memória RAM\n' +
        '  uptime      - Tempo de operação\n' +
        '  date        - Data e hora do sistema\n' +
        '  ls          - Lista arquivos de configuração'
    });
  }
  if (low === 'status' || low === 'free') {
    const freeMb = Math.round(os.freemem() / 1024 / 1024);
    const totalMb = Math.round(os.totalmem() / 1024 / 1024);
    return res.json({ output: `XIQI OS RAM: ${totalMb - freeMb} MB em uso / ${freeMb} MB livres (${totalMb} MB total)` });
  }
  if (low.startsWith('uname')) {
    return res.json({ output: `XIQI OS v1.0 ${os.hostname()} XIQI Core x86_64 Corporacao-Engecema` });
  }
  if (low === 'hostname') {
    return res.json({ output: os.hostname() });
  }
  if (low === 'uptime') {
    return res.json({ output: `Ativo há ${Math.floor(os.uptime() / 60)} minutos` });
  }
  if (low === 'date') {
    return res.json({ output: new Date().toLocaleString('pt-BR') });
  }
  if (low.startsWith('ls')) {
    try {
      const files = fs
        .readdirSync(CONFIG_DIR)
        .filter(name => name !== 'master.key')
        .map(name => {
          const st = fs.statSync(path.join(CONFIG_DIR, name));
          return `${st.size.toString().padStart(8, ' ')} bytes  ${name}`;
        });
      return res.json({ output: `Arquivos em ${CONFIG_DIR}:\n` + (files.length ? files.join('\n') : '(vazio)') });
    } catch {
      return res.json({ output: 'Não foi possível listar o diretório.' });
    }
  }
  return res.json({ output: `Comando não permitido no console restrito: ${raw}\nDigite "help" para ver os comandos suportados.` });
});

app.get('/api/notes', (req, res) => {
  const authUserId = getAuthenticatedUserId(req);
  const cur = readJson(PROFILES_PATH, { users: [], guestSession: createDefaultGuestSession() });
  if (authUserId) {
    const user = (cur.users || []).find(u => u.id === authUserId);
    return res.json({ text: (user && user.session && user.session.notes) || '' });
  }
  res.json({ text: (cur.guestSession && cur.guestSession.notes) || '' });
});

app.post('/api/notes', rateLimit('store_write', 60 * 1000, 60), (req, res) => {
  const authUserId = getAuthenticatedUserId(req);
  const body = stripProtoPollution(req.body || {});
  if (typeof body.text !== 'string') {
    return res.status(400).json({ error: 'Formato inválido de anotação.' });
  }
  const text = body.text.slice(0, 15000);
  const cur = readJson(PROFILES_PATH, {
    version: '1.0.0',
    organization: 'Corporação Engecema',
    users: [],
    guestSession: createDefaultGuestSession()
  });
  if (!Array.isArray(cur.users)) cur.users = [];
  if (authUserId) {
    const user = cur.users.find(u => u.id === authUserId);
    if (!user) return res.status(401).json({ error: 'Sessão inválida.' });
    if (!user.session || typeof user.session !== 'object') user.session = createDefaultGuestSession();
    user.session.notes = text;
  } else {
    if (!cur.guestSession || typeof cur.guestSession !== 'object') cur.guestSession = createDefaultGuestSession();
    cur.guestSession.notes = text;
  }
  writeJson(PROFILES_PATH, cur);
  res.json({ ok: true });
});

app.get('/admin', (req, res) => res.sendFile(path.join(__dirname, 'admin.html')));
app.get('/', (req, res) => res.sendFile(INDEX_PATH));
app.get('/index.html', (req, res) => res.sendFile(INDEX_PATH));
app.use('/api', (req, res) => res.status(404).json({ error: 'Not Found', output: 'Endpoint não encontrado.' }));
app.use((req, res) => res.status(404).type('text/plain').send('Not Found'));

app.use((err, req, res, _next) => {
  if (res.headersSent) return;
  if (err && err.type === 'entity.parse.failed') {
    return res.status(400).json({ error: 'JSON inválido na requisição.' });
  }
  if (err && err.type === 'entity.too.large') {
    return res.status(413).json({ error: 'Payload excede o limite permitido.' });
  }
  console.error('[XIQI OS Error]', err && err.message ? err.message : err);
  if (req.path && req.path.startsWith('/api')) {
    return res.status(500).json({ error: 'Erro interno no servidor XIQI OS.' });
  }
  res.status(500).type('text/plain').send('Erro interno no servidor XIQI OS.');
});

process.on('unhandledRejection', reason => {
  console.error('[XIQI OS UnhandledRejection]', reason && reason.message ? reason.message : reason);
});

process.on('uncaughtException', err => {
  console.error('[XIQI OS UncaughtException]', err && err.message ? err.message : err);
});

const server = app.listen(PORT, HOST, () => console.log('XIQI OS Server listening on port ' + PORT));
server.requestTimeout = 30000;
server.headersTimeout = 15000;
server.keepAliveTimeout = 5000;
server.on('error', err => {
  console.error('[XIQI OS Server Error]', err && err.message ? err.message : err);
  process.exitCode = 1;
});

function gracefulShutdown(signal) {
  console.log('XIQI OS Server shutting down (' + signal + ')...');
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 5000).unref();
}
process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));
