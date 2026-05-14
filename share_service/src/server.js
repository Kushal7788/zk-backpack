import fs from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  decryptJson,
  encryptJson,
  requireMasterKey,
  sha256B64,
  signReceipt
} from './crypto.js';
import { FileStore } from './store.js';
import { verifyArtifact } from './verifier.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const projectRoot = path.resolve(__dirname, '..', '..');
const portalRoot = path.join(projectRoot, 'web_portal');
const fileEnv = await readDotEnv(path.join(projectRoot, 'share_service', '.env'));

const env = {
  port: Number(process.env.PORT ?? fileEnv.PORT ?? 8080),
  host: process.env.HOST ?? fileEnv.HOST ?? '0.0.0.0',
  baseUrl: process.env.BASE_URL ?? fileEnv.BASE_URL ?? 'http://localhost:8080',
  dataDir: path.resolve(projectRoot, process.env.DATA_DIR ?? fileEnv.DATA_DIR ?? './data'),
  ownerHeaderName:
    process.env.OWNER_HEADER_NAME ?? fileEnv.OWNER_HEADER_NAME ?? 'x-owner-id',
  verifierUrl: process.env.VERIFIER_URL ?? fileEnv.VERIFIER_URL ?? 'http://localhost:7047',
  masterKeyB64:
    process.env.MASTER_KEY_B64 ??
    fileEnv.MASTER_KEY_B64 ??
    Buffer.alloc(32, 7).toString('base64')
};

const masterKey = requireMasterKey(env.masterKeyB64);
const store = new FileStore(env.dataDir);
await store.init();

const server = http.createServer(async (req, res) => {
  try {
    await route(req, res);
  } catch (error) {
    sendJson(res, 500, {
      status: 'error',
      message: error instanceof Error ? error.message : 'Unknown server error'
    });
  }
});

server.listen(env.port, env.host, () => {
  console.log(`zk_backpack share service listening on ${env.baseUrl}`);
});

async function route(req, res) {
  const url = new URL(req.url ?? '/', env.baseUrl);
  const pathname = url.pathname;

  if (req.method === 'OPTIONS') {
    sendNoContent(res);
    return;
  }
  if (req.method === 'GET' && pathname === '/health') {
    sendJson(res, 200, { status: 'ok' });
    return;
  }
  if (req.method === 'POST' && pathname === '/proofs') {
    const ownerId = requiredOwner(req);
    const body = await readJsonBody(req);
    if (!body.proofId || !body.artifact) {
      sendJson(res, 400, { message: 'proofId and artifact are required' });
      return;
    }
    const artifactString = JSON.stringify(body.artifact);
    const encrypted = encryptJson(masterKey, body.artifact);
    await store.saveEncryptedProof(
      {
        proofId: String(body.proofId),
        ownerId,
        providerId: String(body.providerId ?? ''),
        integrityDigest: String(body.integrityDigest ?? ''),
        targetHost: String(body.targetHost ?? ''),
        declaredCreatedAtUtc: String(body.createdAtUtc ?? '')
      },
      encrypted
    );
    await store.appendAudit({
      at: new Date().toISOString(),
      type: 'proof_uploaded',
      ownerId,
      proofId: body.proofId,
      artifactHashB64: sha256B64(artifactString)
    });
    sendJson(res, 200, {
      proofId: String(body.proofId),
      status: 'stored_encrypted'
    });
    return;
  }
  if (req.method === 'POST' && pathname === '/shares') {
    const ownerId = requiredOwner(req);
    const body = await readJsonBody(req);
    const proofId = String(body.proofId ?? '');
    if (!proofId) {
      sendJson(res, 400, { message: 'proofId is required' });
      return;
    }
    const proof = await store.getProof(proofId);
    if (!proof) {
      sendJson(res, 404, { message: 'proof not found' });
      return;
    }
    if (proof.ownerId !== ownerId) {
      sendJson(res, 403, { message: 'forbidden' });
      return;
    }
    const expiresInMinutes = clampInt(body.expiresInMinutes, 1, 43200, 60);
    const share = await store.createShare({
      ownerId,
      proofId,
      policyTemplate: String(body.policyTemplate ?? 'masked'),
      expiresInMinutes,
      oneTimeView: Boolean(body.oneTimeView),
      maxViews: body.maxViews == null ? null : Number(body.maxViews)
    });
    await store.appendAudit({
      at: new Date().toISOString(),
      type: 'share_created',
      ownerId,
      proofId,
      token: share.token
    });
    sendJson(res, 200, {
      token: share.token,
      url: `${env.baseUrl}/s/${share.token}`,
      expiresAtUtc: share.expiresAtUtc
    });
    return;
  }
  if (req.method === 'POST' && pathname.startsWith('/shares/') && pathname.endsWith('/revoke')) {
    const ownerId = requiredOwner(req);
    const token = pathname.split('/')[2];
    try {
      const revoked = await store.revokeShare({ token, ownerId });
      if (!revoked) {
        sendJson(res, 404, { message: 'share not found' });
        return;
      }
    } catch {
      sendJson(res, 403, { message: 'forbidden' });
      return;
    }
    await store.appendAudit({
      at: new Date().toISOString(),
      type: 'share_revoked',
      ownerId,
      token
    });
    sendJson(res, 200, { status: 'revoked', token });
    return;
  }
  if (req.method === 'POST' && pathname === '/api/share/resolve') {
    const body = await readJsonBody(req);
    const token = String(body.token ?? '');
    const share = await store.getShare(token);
    if (!share) {
      sendJson(res, 404, { status: 'invalid', message: 'share token not found' });
      return;
    }
    const blocked = evaluateShareGate(share);
    if (blocked) {
      sendJson(res, 403, blocked);
      return;
    }
    sendJson(res, 200, {
      status: 'valid',
      token,
      proofId: share.proofId,
      policyTemplate: share.policyTemplate,
      expiresAtUtc: share.expiresAtUtc
    });
    return;
  }
  if (req.method === 'POST' && pathname === '/api/share/verify') {
    const body = await readJsonBody(req);
    const token = String(body.token ?? '');
    const result = await verifyToken(token);
    sendJson(res, result.code, result.payload);
    return;
  }
  if (req.method === 'GET' && pathname === '/api/share/view') {
    const token = url.searchParams.get('token') ?? '';
    const result = await verifyToken(token);
    sendJson(res, result.code, result.payload);
    return;
  }
  if (req.method === 'GET' && pathname.startsWith('/s/')) {
    const token = pathname.split('/')[2];
    const html = await fs.readFile(path.join(portalRoot, 'index.html'), 'utf8');
    sendHtml(res, html.replaceAll('__SHARE_TOKEN__', token));
    return;
  }
  if (req.method === 'GET' && pathname === '/app.js') {
    const js = await fs.readFile(path.join(portalRoot, 'app.js'), 'utf8');
    sendAsset(res, 200, js, 'application/javascript; charset=utf-8');
    return;
  }
  if (req.method === 'GET' && pathname === '/styles.css') {
    const css = await fs.readFile(path.join(portalRoot, 'styles.css'), 'utf8');
    sendAsset(res, 200, css, 'text/css; charset=utf-8');
    return;
  }
  sendJson(res, 404, { message: 'not_found' });
}

async function verifyToken(token) {
  const share = await store.getShare(token);
  if (!share) {
    return {
      code: 404,
      payload: {
        status: 'invalid',
        message: 'Share token not found'
      }
    };
  }
  const blocked = evaluateShareGate(share);
  if (blocked) {
    return { code: 403, payload: blocked };
  }
  const proof = await store.getProof(share.proofId);
  if (!proof) {
    return {
      code: 404,
      payload: {
        status: 'invalid',
        message: 'Proof record not found'
      }
    };
  }
  const encryptedPayload = await store.getEncryptedBlob(proof.blobPath);
  if (!encryptedPayload) {
    return {
      code: 500,
      payload: {
        status: 'invalid',
        message: 'Encrypted blob missing'
      }
    };
  }
  const artifact = decryptJson(masterKey, encryptedPayload);
  const artifactHashB64 = sha256B64(JSON.stringify(artifact));
  const verifier = await verifyArtifact(env.verifierUrl, artifact);
  const viewAfter = await store.consumeShareView(token);
  const receiptPayload = {
    tokenId: token,
    proofId: share.proofId,
    artifactHash: artifactHashB64,
    verifierResult: verifier,
    verifiedAt: new Date().toISOString()
  };
  const receiptToken = signReceipt(masterKey, receiptPayload);

  await store.appendAudit({
    at: new Date().toISOString(),
    type: 'share_verified',
    token,
    proofId: share.proofId,
    verifierOk: verifier.ok,
    views: viewAfter?.views ?? 0
  });

  const scopedClaims = projectClaims(artifact, share.policyTemplate);
  return {
    code: verifier.ok ? 200 : 422,
    payload: {
      status: verifier.ok ? 'valid' : 'invalid',
      message: verifier.ok
        ? 'Verified credential'
        : verifier.reason ?? 'Proof verification failed',
      verification: verifier,
      scopedClaims,
      receipt: {
        ...receiptPayload,
        signature: receiptToken
      }
    }
  };
}

function projectClaims(artifact, policyTemplate) {
  const payload = artifact?.payload ?? {};
  const response = payload?.response ?? {};
  const revealed = response?.revealedBody ?? {};
  if (policyTemplate === 'full') {
    return revealed;
  }
  const keys = Object.keys(revealed);
  const scoped = {};
  for (const key of keys.slice(0, Math.min(4, keys.length))) {
    scoped[key] = revealed[key];
  }
  return scoped;
}

function evaluateShareGate(share) {
  if (share.revoked) {
    return {
      status: 'revoked',
      message: 'Share token has been revoked'
    };
  }
  if (Date.now() > Date.parse(share.expiresAtUtc)) {
    return {
      status: 'expired',
      message: 'Share token has expired'
    };
  }
  if (share.oneTimeView && Number(share.views) > 0) {
    return {
      status: 'consumed',
      message: 'Share link is one-time and already consumed'
    };
  }
  if (share.maxViews != null && Number(share.views) >= Number(share.maxViews)) {
    return {
      status: 'max_views_reached',
      message: 'Share link has reached maximum view count'
    };
  }
  return null;
}

function requiredOwner(req) {
  const owner = req.headers[env.ownerHeaderName];
  if (!owner || Array.isArray(owner) || !owner.trim()) {
    throw new Error(`Missing owner header: ${env.ownerHeaderName}`);
  }
  return owner.trim();
}

async function readJsonBody(req) {
  const chunks = [];
  for await (const chunk of req) {
    chunks.push(chunk);
  }
  if (chunks.length === 0) {
    return {};
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

function clampInt(value, min, max, fallback) {
  const parsed = Number.parseInt(String(value ?? ''), 10);
  if (!Number.isFinite(parsed)) {
    return fallback;
  }
  return Math.max(min, Math.min(max, parsed));
}

function setCorsHeaders(res) {
  res.setHeader('access-control-allow-origin', '*');
  res.setHeader('access-control-allow-methods', 'GET,POST,OPTIONS');
  res.setHeader('access-control-allow-headers', 'content-type,x-owner-id');
}

function sendNoContent(res) {
  setCorsHeaders(res);
  res.writeHead(204);
  res.end();
}

function sendJson(res, statusCode, payload) {
  setCorsHeaders(res);
  res.writeHead(statusCode, {
    'content-type': 'application/json; charset=utf-8'
  });
  res.end(JSON.stringify(payload));
}

function sendHtml(res, html) {
  res.writeHead(200, {
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    'x-frame-options': 'DENY'
  });
  res.end(html);
}

function sendAsset(res, statusCode, body, contentType) {
  res.writeHead(statusCode, { 'content-type': contentType });
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
