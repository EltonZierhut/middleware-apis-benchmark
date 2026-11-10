// node-middleware: implementação do middleware de APIs em Node.js (só stdlib: node:http, node:cluster).
//
// Rotas (mesmo contrato das versões Go e Rails):
//
//	GET /health
//	GET /platform/contacts?page=&page_size=&filter[lead_stage]=&filter[tag]=&filter[email_domain]=
//	GET /platform/contacts/{id}   (agrega Contatos + Automação + Multicanalidade em paralelo)
//
// Node roda o JavaScript numa thread só, então usa node:cluster com 1 processo por CPU
// (WEB_CONCURRENCY), como o Puma no Rails e o GOMAXPROCS no Go.
'use strict';

const cluster = require('node:cluster');
const http = require('node:http');

const UPSTREAM_URL = new URL(process.env.UPSTREAM_URL || 'http://localhost:9000');
const PORT = parseInt(process.env.PORT || '3001', 10);
const WORKERS = Math.max(parseInt(process.env.WEB_CONCURRENCY || '2', 10) || 1, 1);

// Timeouts por domínio (resiliência por domínio)
const CONTACTS_TIMEOUT_MS = 1000;
const OPTIONAL_TIMEOUT_MS = 300;

// Keep-alive para o upstream, como o http.Transport do Go e o net-http-persistent do Rails.
const agent = new http.Agent({ keepAlive: true, maxSockets: 2000, maxFreeSockets: 2000, keepAliveMsecs: 90_000 });

class NotFound extends Error {}
class UpstreamError extends Error {}

// GET no upstream com timeout cobrindo a requisição inteira (conexão + corpo), como o context.WithTimeout do Go.
function fetchJSON(path, timeoutMs) {
  return new Promise((resolve, reject) => {
    let done = false;
    const finish = (fn, v) => { if (!done) { done = true; clearTimeout(timer); fn(v); } };

    const req = http.get({
      host: UPSTREAM_URL.hostname,
      port: UPSTREAM_URL.port || 80,
      path,
      agent,
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('error', (e) => finish(reject, new UpstreamError(e.message)));
      res.on('end', () => {
        if (res.statusCode === 404) return finish(reject, new NotFound());
        if (res.statusCode >= 300) return finish(reject, new UpstreamError(`status ${res.statusCode}`));
        try {
          finish(resolve, JSON.parse(Buffer.concat(chunks)));
        } catch (e) {
          finish(reject, new UpstreamError(e.message));
        }
      });
    });
    req.on('error', (e) => finish(reject, new UpstreamError(e.message)));
    const timer = setTimeout(() => {
      req.destroy();
      finish(reject, new UpstreamError('timeout'));
    }, timeoutMs);
  });
}

function writeJSON(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(payload),
  });
  res.end(payload);
}

// Mesma regra do strconv.Atoi do Go: só inteiro completo, senão o padrão.
function atoiDefault(s, d) {
  return s !== null && /^[+-]?\d+$/.test(s) ? parseInt(s, 10) : d;
}

// time.Unix(...).UTC().Format(time.RFC3339) => "2023-11-14T22:13:20Z" (sem milissegundos)
function rfc3339(unixSeconds) {
  return new Date(unixSeconds * 1000).toISOString().slice(0, 19) + 'Z';
}

// Converte o contrato upstream para o contrato público (OpenAPI).
function present(c) {
  return {
    id: c.uuid,
    name: c.name,
    email: c.email,
    job_title: c.job_title,
    tags: c.tags,
    lead_stage: c.lead_stage.replaceAll(' ', '_').toLowerCase(),
    created_at: rfc3339(c.created_at),
    custom_fields: c.cf,
  };
}

async function listContacts(res, q) {
  const page = Math.max(atoiDefault(q.get('page'), 1), 1);
  const pageSize = Math.min(Math.max(atoiDefault(q.get('page_size'), 25), 1), 100);
  const fStage = q.get('filter[lead_stage]') || '';
  const fTag = q.get('filter[tag]') || '';
  const fDomain = q.get('filter[email_domain]') || '';

  let up;
  try {
    up = await fetchJSON(`/contacts?page=${page}&per_page=100`, CONTACTS_TIMEOUT_MS);
  } catch {
    return writeJSON(res, 502, { error: 'contacts_unavailable' });
  }

  const data = [];
  for (const c of up.contacts || []) {
    const p = present(c);
    if (fStage && p.lead_stage !== fStage) continue;
    if (fTag && !(p.tags || []).includes(fTag)) continue;
    if (fDomain && !p.email.endsWith('@' + fDomain)) continue;
    data.push(p);
    if (data.length === pageSize) break;
  }

  writeJSON(res, 200, {
    data,
    meta: { page, page_size: pageSize, count: data.length },
    links: { next: `/platform/contacts?page=${page + 1}&page_size=${pageSize}` },
  });
}

async function showContact(res, id) {
  const [contact, flows, channels] = await Promise.allSettled([
    fetchJSON(`/contacts/${id}`, CONTACTS_TIMEOUT_MS),
    fetchJSON(`/automation/contacts/${id}/flows`, OPTIONAL_TIMEOUT_MS),
    fetchJSON(`/multichannel/contacts/${id}/channels`, OPTIONAL_TIMEOUT_MS),
  ]);

  if (contact.status === 'rejected') {
    if (contact.reason instanceof NotFound) return writeJSON(res, 404, { error: 'not_found' });
    return writeJSON(res, 502, { error: 'contacts_unavailable' });
  }

  const degraded = [];
  if (flows.status === 'rejected') degraded.push('automation');
  if (channels.status === 'rejected') degraded.push('multichannel');

  writeJSON(res, 200, {
    data: {
      contact: present(contact.value),
      automation: flows.status === 'fulfilled' ? { flows: flows.value.flows } : null,
      channels: channels.status === 'fulfilled' ? channels.value.channels : null,
    },
    meta: { degraded },
  });
}

const DETAIL = /^\/platform\/contacts\/([^/]+)$/;

function handler(req, res) {
  const url = new URL(req.url, 'http://localhost');
  const path = url.pathname;

  if (req.method === 'GET') {
    if (path === '/health') return writeJSON(res, 200, { status: 'ok' });
    if (path === '/platform/contacts') return listContacts(res, url.searchParams).catch((e) => fail(res, e));
    const m = DETAIL.exec(path);
    if (m) return showContact(res, decodeURIComponent(m[1])).catch((e) => fail(res, e));
  }
  res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end('404 page not found\n');
}

function fail(res, e) {
  console.error(e);
  if (!res.headersSent) writeJSON(res, 500, { error: 'internal_error' });
  else res.destroy();
}

if (cluster.isPrimary && WORKERS > 1) {
  console.log(`node-middleware on :${PORT} upstream=${UPSTREAM_URL.origin} workers=${WORKERS}`);
  for (let i = 0; i < WORKERS; i++) cluster.fork();
  cluster.on('exit', (w, code) => {
    console.error(`worker ${w.process.pid} saiu (code=${code}); subindo outro`);
    cluster.fork();
  });
} else {
  const server = http.createServer({ keepAlive: true, headersTimeout: 5000 }, handler);
  server.keepAliveTimeout = 90_000;
  server.listen(PORT, () => {
    if (WORKERS === 1) console.log(`node-middleware on :${PORT} upstream=${UPSTREAM_URL.origin} workers=1`);
  });
}
