import fs from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const fileEnv = await readDotEnv(path.join(__dirname, '.env'));

const env = {
  port: Number(process.env.PORT ?? fileEnv.PORT ?? 8081),
  host: process.env.HOST ?? fileEnv.HOST ?? '0.0.0.0',
  baseUrl: process.env.BASE_URL ?? fileEnv.BASE_URL ?? 'http://localhost:8081',
  shareServiceUrl:
    process.env.SHARE_SERVICE_URL ??
    fileEnv.SHARE_SERVICE_URL ??
    'http://localhost:8080'
};

const TOKEN_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;

const server = http.createServer(async (req, res) => {
  try {
    await route(req, res);
  } catch (error) {
    sendJson(res, 500, {
      status: 'error',
      message: 'internal server error'
    });
  }
});

server.listen(env.port, env.host, () => {
  console.log(`zk_backpack web portal listening on ${env.baseUrl}`);
  console.log(`  -> share_service at ${env.shareServiceUrl}`);
});

async function route(req, res) {
  const url = new URL(req.url ?? '/', env.baseUrl);
  const pathname = url.pathname;

  if (req.method === 'GET' && pathname === '/health') {
    sendJson(res, 200, { status: 'ok' });
    return;
  }

  if (req.method === 'GET' && pathname === '/app.js') {
    const js = await fs.readFile(path.join(__dirname, 'app.js'), 'utf8');
    sendAsset(res, 200, js, 'application/javascript; charset=utf-8');
    return;
  }
  if (req.method === 'GET' && pathname === '/styles.css') {
    const css = await fs.readFile(path.join(__dirname, 'styles.css'), 'utf8');
    sendAsset(res, 200, css, 'text/css; charset=utf-8');
    return;
  }

  if (req.method === 'GET' && pathname.startsWith('/s/')) {
    const token = sanitizeToken(pathname.split('/')[2]);
    if (!token) {
      sendHtml(res, await renderPortal(''), 400);
      return;
    }
    sendHtml(res, await renderPortal(token), 200);
    return;
  }

  if (req.method === 'GET' && (pathname === '/' || pathname === '/index.html')) {
    sendHtml(res, await renderPortal(''), 200);
    return;
  }

  sendJson(res, 404, { message: 'not_found' });
}

async function renderPortal(token) {
  const raw = await fs.readFile(path.join(__dirname, 'index.html'), 'utf8');
  return raw
    .replaceAll('%%SHARE_TOKEN_VALUE%%', escapeHtml(token))
    .replaceAll('%%SHARE_SERVICE_BASE%%', escapeHtml(env.shareServiceUrl));
}

function sanitizeToken(raw) {
  if (raw == null) return '';
  const trimmed = String(raw).trim();
  if (!TOKEN_PATTERN.test(trimmed)) return '';
  return trimmed;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function sendJson(res, statusCode, payload) {
  res.writeHead(statusCode, {
    'content-type': 'application/json; charset=utf-8',
    'x-content-type-options': 'nosniff'
  });
  res.end(JSON.stringify(payload));
}

function sendHtml(res, html, statusCode = 200) {
  // CSP must allow the portal to fetch from share_service (different
  // origin) and load Vue from unpkg.
  const connectSrc = ["'self'", env.shareServiceUrl].filter(Boolean).join(' ');
  res.writeHead(statusCode, {
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    'x-frame-options': 'DENY',
    'referrer-policy': 'no-referrer',
    'content-security-policy':
      `default-src 'self'; ` +
      `script-src 'self' https://unpkg.com 'unsafe-inline'; ` +
      `style-src 'self' 'unsafe-inline'; ` +
      `img-src 'self' data:; ` +
      `connect-src ${connectSrc}; ` +
      `base-uri 'self'; ` +
      `form-action 'self'; ` +
      `frame-ancestors 'none'`
  });
  res.end(html);
}

function sendAsset(res, statusCode, body, contentType) {
  res.writeHead(statusCode, {
    'content-type': contentType,
    'cache-control': 'public, max-age=300',
    'x-content-type-options': 'nosniff'
  });
  res.end(body);
}

async function readDotEnv(filePath) {
  try {
    const raw = await fs.readFile(filePath, 'utf8');
    return raw
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => line && !line.startsWith('#') && line.includes('='))
      .reduce((acc, line) => {
        const idx = line.indexOf('=');
        const key = line.slice(0, idx).trim();
        const value = line.slice(idx + 1).trim();
        acc[key] = value;
        return acc;
      }, {});
  } catch {
    return {};
  }
}
