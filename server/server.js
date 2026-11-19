#!/usr/bin/env node
/*
 * huma-leads — приёмник заявок с лендингов → лиды в Битрикс24.
 *
 * Лендинг шлёт POST https://leads.huma.marketing/<client> с JSON-заявкой.
 * Сервер проверяет её и создаёт лид через входящий вебхук клиента (crm.lead.add).
 * Вебхуки хранятся только на сервере, в CLIENTS_FILE (по умолчанию /etc/huma-leads/clients.json):
 *
 * {
 *   "atlant": {
 *     "webhook": "https://xxx.bitrix24.ru/rest/1/xxxxxxxx/",
 *     "title": "Атлант · Чёрная пятница 11.11",
 *     "origins": ["https://rdana743.github.io"]
 *   }
 * }
 *
 * Без зависимостей, Node.js 18+. Каждая заявка дублируется в журнал (LOG_DIR/<client>.jsonl),
 * чтобы ничего не потерялось, если Битрикс недоступен.
 */
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = +process.env.PORT || 8787;
const HOST = process.env.HOST || '127.0.0.1';
const CLIENTS_FILE = process.env.CLIENTS_FILE || '/etc/huma-leads/clients.json';
const LOG_DIR = process.env.LOG_DIR || '/var/lib/huma-leads';
const MAX_BODY = 16 * 1024;
const RATE = { windowMs: 10 * 60 * 1000, max: 8 };   // не больше 8 заявок с одного IP за 10 минут

let clients = {};
function loadClients() {
  try {
    clients = JSON.parse(fs.readFileSync(CLIENTS_FILE, 'utf8'));
    log('info', 'clients loaded: ' + Object.keys(clients).join(', '));
  } catch (e) { log('error', 'cannot read ' + CLIENTS_FILE + ': ' + e.message); }
}
process.on('SIGHUP', loadClients);   // systemctl reload huma-leads — перечитать клиентов без рестарта

function log(level, msg) { console[level === 'error' ? 'error' : 'log'](new Date().toISOString() + ' [' + level + '] ' + msg); }

// ---------- защита от флуда ----------
const hits = new Map();
function rateLimited(ip) {
  const now = Date.now();
  const arr = (hits.get(ip) || []).filter((t) => now - t < RATE.windowMs);
  arr.push(now); hits.set(ip, arr);
  return arr.length > RATE.max;
}
setInterval(() => { const now = Date.now(); for (const [ip, a] of hits) if (!a.some((t) => now - t < RATE.windowMs)) hits.delete(ip); }, 60000).unref();

// ---------- утилиты ----------
const str = (v, n) => String(v == null ? '' : v).replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, n || 500);
function normPhone(p) {
  let d = String(p || '').replace(/\D/g, '');
  if (d.length === 10) d = '7' + d;
  if (d.length === 11 && d[0] === '8') d = '7' + d.slice(1);
  return /^7\d{10}$/.test(d) ? '+' + d : null;
}
const FORM_NAMES = {
  quiz: 'Квиз на первом экране', mid: 'Форма в середине страницы', final: 'Финальная форма',
  'modal:call_header': 'Попап «Перезвоните мне» (шапка)', 'modal:book_sticky': 'Попап «Забронировать скидку» (нижняя панель)',
  'modal:book': 'Попап «Хочу такую же улыбку»', 'modal:price': 'Попап из прайса', 'modal:situation': 'Попап из блока «Ситуации»',
  'modal:calc': 'Попап из калькулятора', 'modal:doctor': 'Попап «Записаться к врачу»', 'modal:case': 'Попап из кейса до/после',
  'modal:exit': 'Попап при уходе со страницы'
};

function appendLog(client, rec) {
  try {
    fs.mkdirSync(LOG_DIR, { recursive: true, mode: 0o700 });
    fs.appendFileSync(path.join(LOG_DIR, client + '.jsonl'), JSON.stringify(rec) + '\n', { mode: 0o600 });
  } catch (e) { log('error', 'log write failed: ' + e.message); }
}

async function bitrixAddLead(cfg, lead) {
  const url = cfg.webhook.replace(/\/?$/, '/') + 'crm.lead.add.json';
  const body = JSON.stringify({ fields: lead, params: { REGISTER_SONET_EVENT: 'Y' } });
  for (let attempt = 1; attempt <= 2; attempt++) {
    try {
      const r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body, signal: AbortSignal.timeout(10000) });
      const j = await r.json().catch(() => ({}));
      if (r.ok && j.result) return { ok: true, id: j.result };
      log('error', 'bitrix ' + r.status + ' ' + (j.error || '') + ' ' + (j.error_description || ''));
      if (r.status < 500) return { ok: false, error: j.error || 'HTTP ' + r.status };
    } catch (e) { log('error', 'bitrix request failed (try ' + attempt + '): ' + e.message); }
    await new Promise((res) => setTimeout(res, 1500));
  }
  return { ok: false, error: 'bitrix_unreachable' };
}

function buildLead(cfg, d, phone) {
  const form = str(d.source, 60);
  const formName = FORM_NAMES[form] || form || 'Форма';
  const lines = [
    'Источник: ' + (cfg.title || 'Лендинг'),
    'Форма: ' + formName,
    d.discount ? 'Скидка: ' + str(d.discount, 10) : '',
    d.details ? 'Детали: ' + str(d.details, 1500).replace(/; /g, '\n') : '',
    d.page ? 'Страница: ' + str(d.page, 500) : '',
    d.referrer ? 'Откуда пришёл: ' + str(d.referrer, 500) : '',
    d.yclid ? 'yclid: ' + str(d.yclid, 100) : '',
    d.gclid ? 'gclid: ' + str(d.gclid, 100) : ''
  ].filter(Boolean);
  const lead = {
    TITLE: (cfg.title || 'Заявка с лендинга') + ' — ' + formName,
    PHONE: [{ VALUE: phone, VALUE_TYPE: 'WORK' }],
    SOURCE_ID: cfg.sourceId || 'WEB',
    SOURCE_DESCRIPTION: str(cfg.title || 'Лендинг', 200),
    COMMENTS: lines.join('\n'),
    OPENED: 'Y'
  };
  ['utm_source', 'utm_medium', 'utm_campaign', 'utm_content', 'utm_term'].forEach((k) => { if (d[k]) lead[k.toUpperCase()] = str(d[k], 255); });
  if (cfg.assignedById) lead.ASSIGNED_BY_ID = cfg.assignedById;
  return lead;
}

// ---------- HTTP ----------
function send(res, code, obj, origin) {
  const h = { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
  if (origin) { h['Access-Control-Allow-Origin'] = origin; h['Vary'] = 'Origin'; }
  res.writeHead(code, h); res.end(JSON.stringify(obj));
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  const client = url.pathname.replace(/^\/+|\/+$/g, '');
  if (url.pathname === '/health') return send(res, 200, { ok: true });
  const cfg = clients[client];
  if (!cfg || !cfg.webhook) return send(res, 404, { ok: false, error: 'not_found' });

  const origin = req.headers.origin || '';
  const allowed = (cfg.origins || []).includes(origin) ? origin : '';

  if (req.method === 'OPTIONS') {
    if (!allowed) return send(res, 403, { ok: false });
    res.writeHead(204, { 'Access-Control-Allow-Origin': allowed, 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type', 'Access-Control-Max-Age': '86400', 'Vary': 'Origin' });
    return res.end();
  }
  if (req.method !== 'POST') return send(res, 405, { ok: false }, allowed);
  if (!allowed) return send(res, 403, { ok: false, error: 'origin' });

  const ip = String(req.headers['x-real-ip'] || req.socket.remoteAddress || '');
  if (rateLimited(ip)) return send(res, 429, { ok: false, error: 'too_many' }, allowed);

  let size = 0; const chunks = [];
  req.on('data', (c) => { size += c.length; if (size > MAX_BODY) { req.destroy(); } else chunks.push(c); });
  req.on('end', async () => {
    let d;
    try { d = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { return send(res, 400, { ok: false, error: 'bad_json' }, allowed); }
    if (d.company) return send(res, 200, { ok: true }, allowed);            // ловушка для ботов
    const phone = normPhone(d.phone);
    if (!phone) return send(res, 422, { ok: false, error: 'phone' }, allowed);

    const lead = buildLead(cfg, d, phone);
    const rec = { at: new Date().toISOString(), ip, phone, form: str(d.source, 60), details: str(d.details, 1500), utm_source: str(d.utm_source, 100), utm_campaign: str(d.utm_campaign, 200) };
    const r = await bitrixAddLead(cfg, lead);
    rec.bitrix = r.ok ? 'lead ' + r.id : 'FAILED ' + r.error;
    appendLog(client, rec);
    log(r.ok ? 'info' : 'error', client + ' ' + rec.form + ' → ' + rec.bitrix);
    // пользователю всегда «ок»: заявка сохранена в журнале, даже если Битрикс не ответил
    send(res, 200, { ok: true }, allowed);
  });
});

loadClients();
server.listen(PORT, HOST, () => log('info', 'huma-leads listening on ' + HOST + ':' + PORT));
