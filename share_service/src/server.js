import fs from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  decryptJson,
  encryptJson,
  requireMasterKey,
  sha256B64,
  signReceipt,
  verifyReceipt
} from './crypto.js';
import { FileStore } from './store.js';
import { evaluateSelection, isSelectionValid } from './selection.js';
import { verifyArtifact } from './verifier.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const moduleRoot = path.resolve(__dirname, '..');
const fileEnv = await readDotEnv(path.join(moduleRoot, '.env'));

// Five environment variables — everything else is hardcoded below.
const env = {
  // Optional. Defaults to 8080 locally; on Fly.io the platform injects
  // its own PORT into the container.
  port: Number(process.env.PORT ?? fileEnv.PORT ?? 8080),
  // Optional. Where the FileStore writes blobs + JSON state. Locally
  // defaults to <share_service>/data; on Fly.io set to /data (the
  // mount point of the persistent volume).
  dataDir: path.resolve(moduleRoot, process.env.DATA_DIR ?? fileEnv.DATA_DIR ?? './data'),
  // Required. URL of the recipient frontend (web_portal). Share URLs
  // minted by /shares point here; the portal fetches back into this
  // service across origins.
  portalBaseUrl:
    process.env.PORTAL_BASE_URL ??
    fileEnv.PORTAL_BASE_URL ??
    'http://localhost:8081',
  // Required. TLSN verifier service endpoint.
  verifierUrl: process.env.VERIFIER_URL ?? fileEnv.VERIFIER_URL ?? 'http://localhost:7047',
  // Required. 32-byte base64 envelope key. Service refuses to start if
  // this is missing.
  masterKeyB64: process.env.MASTER_KEY_B64 ?? fileEnv.MASTER_KEY_B64 ?? ''
};

// Sensible hardcoded defaults — no env knobs.
const HOST = '0.0.0.0';
const OWNER_HEADER_NAME = 'x-owner-id';
const VERIFIER_TIMEOUT_MS = 15_000;
const MAX_BODY_BYTES = 2 * 1024 * 1024;
const RATE_LIMIT_WINDOW_MS = 60_000;
const RATE_LIMIT_MAX = 240;
// The API is intentionally public — anyone with a share token can hit
// /api/share/view from any origin. Mutations are still gated by the
// x-owner-id header.
const CORS_ALLOWED_ORIGIN = '*';

if (!env.masterKeyB64) {
  console.error(
    'FATAL: MASTER_KEY_B64 is not set. Generate one with:\n  node -e "console.log(require(\'crypto\').randomBytes(32).toString(\'base64\'))"'
  );
  process.exit(1);
}

const masterKey = requireMasterKey(env.masterKeyB64);
const store = new FileStore(env.dataDir);
await store.init();

const rateLimiter = createRateLimiter(RATE_LIMIT_WINDOW_MS, RATE_LIMIT_MAX);
const OWNER_ID_PATTERN = /^[A-Za-z0-9._:@\-]{1,128}$/;
const TOKEN_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;

const server = http.createServer(async (req, res) => {
  try {
    if (!rateLimiter.allow(clientIpOf(req))) {
      sendJson(res, 429, { message: 'rate limit exceeded' });
      return;
    }
    await route(req, res);
  } catch (error) {
    if (error && error.code === 'BODY_TOO_LARGE') {
      sendJson(res, 413, { message: 'request body too large' });
      return;
    }
    if (error && error.code === 'BAD_JSON') {
      sendJson(res, 400, { message: 'invalid JSON body' });
      return;
    }
    if (error && error.code === 'MISSING_OWNER') {
      sendJson(res, 401, { message: error.message });
      return;
    }
    if (error && error.code === 'BAD_OWNER') {
      sendJson(res, 400, { message: error.message });
      return;
    }
    sendJson(res, 500, {
      status: 'error',
      message: 'internal server error'
    });
  }
});

server.listen(env.port, HOST, () => {
  console.log(`zk_backpack share service listening on http://${HOST}:${env.port}`);
});

async function route(req, res) {
  // The fake base is only used to make `new URL` accept relative paths;
  // we only care about pathname + search, never the origin.
  const url = new URL(req.url ?? '/', 'http://internal');
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
    const proofId = sanitizeProofId(body.proofId);
    if (!proofId || !body.artifact || typeof body.artifact !== 'object') {
      sendJson(res, 400, { message: 'proofId and artifact are required' });
      return;
    }
    const existing = await store.getProof(proofId);
    if (existing && existing.ownerId !== ownerId) {
      sendJson(res, 409, { message: 'proofId already exists for a different owner' });
      return;
    }
    const artifactString = JSON.stringify(body.artifact);
    const encrypted = encryptJson(masterKey, body.artifact);
    await store.saveEncryptedProof(
      {
        proofId,
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
      proofId,
      artifactHashB64: sha256B64(artifactString)
    });
    sendJson(res, 200, {
      proofId,
      status: 'stored_encrypted'
    });
    return;
  }
  if (req.method === 'POST' && pathname === '/shares') {
    const ownerId = requiredOwner(req);
    const body = await readJsonBody(req);
    const proofId = sanitizeProofId(body.proofId);
    if (!proofId) {
      sendJson(res, 400, { message: 'proofId is required and must be a valid identifier' });
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
    const selection = sanitizeSelection(body.selection);
    const policyTemplate = String(body.policyTemplate ?? (selection ? 'selection' : 'masked'));
    const share = await store.createShare({
      ownerId,
      proofId,
      policyTemplate,
      expiresInMinutes,
      oneTimeView: Boolean(body.oneTimeView),
      maxViews: body.maxViews == null ? null : Number(body.maxViews),
      selection
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
      url: `${env.portalBaseUrl}/s/${share.token}`,
      expiresAtUtc: share.expiresAtUtc
    });
    return;
  }
  if (req.method === 'POST' && pathname.startsWith('/shares/') && pathname.endsWith('/revoke')) {
    const ownerId = requiredOwner(req);
    const token = sanitizeToken(pathname.split('/')[2]);
    if (!token) {
      sendJson(res, 400, { message: 'invalid share token' });
      return;
    }
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
    const token = sanitizeToken(body.token);
    if (!token) {
      sendJson(res, 400, { status: 'invalid', message: 'invalid share token' });
      return;
    }
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
    const token = sanitizeToken(body.token);
    if (!token) {
      sendJson(res, 400, { status: 'invalid', message: 'invalid share token' });
      return;
    }
    const result = await verifyToken(token);
    sendJson(res, result.code, result.payload);
    return;
  }
  if (req.method === 'POST' && pathname === '/api/share/receipt/verify') {
    const body = await readJsonBody(req);
    const signature = String(body.signature ?? '');
    const result = verifyReceiptSignature(signature);
    sendJson(res, result.ok ? 200 : 400, result);
    return;
  }
  if (req.method === 'GET' && pathname === '/api/share/view') {
    const token = sanitizeToken(url.searchParams.get('token'));
    if (!token) {
      sendJson(res, 400, { status: 'invalid', message: 'invalid share token' });
      return;
    }
    const result = await verifyToken(token);
    sendJson(res, result.code, result.payload);
    return;
  }
  // The recipient portal is no longer served from this process. Mint
  // share URLs use PORTAL_BASE_URL (see /shares); the portal frontend
  // fetches back into this service over CORS.
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
  const verifier = await safeVerifyArtifact(env.verifierUrl, artifact);
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

  const scopedClaims = projectClaims(artifact, share);
  return {
    code: verifier.ok ? 200 : 422,
    payload: {
      status: verifier.ok ? 'valid' : 'invalid',
      message: verifier.ok
        ? 'Verified credential'
        : verifier.reason ?? 'Proof verification failed',
      verification: verifier,
      scopedClaims,
      share: summarizeShare(viewAfter ?? share),
      receipt: {
        ...receiptPayload,
        signature: receiptToken
      }
    }
  };
}

function summarizeShare(share) {
  return {
    policyTemplate: share.policyTemplate,
    expiresAtUtc: share.expiresAtUtc,
    oneTimeView: Boolean(share.oneTimeView),
    maxViews: share.maxViews ?? null,
    views: Number(share.views ?? 0)
  };
}

function projectClaims(artifact, share) {
  if (share && share.selection && isSelectionValid(share.selection)) {
    return evaluateSelection(share.selection, artifact);
  }
  const payload = artifact?.payload ?? {};
  const response = payload?.response ?? {};
  const revealed = response?.revealedBody ?? {};
  if (share?.policyTemplate === 'full') {
    return { fields: revealed, predicates: [] };
  }
  const keys = Object.keys(revealed);
  const fields = {};
  for (const key of keys.slice(0, Math.min(4, keys.length))) {
    fields[key] = revealed[key];
  }
  return { fields, predicates: [] };
}

function sanitizeSelection(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const fields = Array.isArray(raw.fields)
    ? raw.fields
        .filter((field) => field && typeof field === 'object' && field.path)
        .map((field) => ({
          path: String(field.path),
          label: String(field.label ?? field.path)
        }))
    : [];
  const predicates = Array.isArray(raw.predicates)
    ? raw.predicates
        .filter((predicate) => predicate && typeof predicate === 'object' && predicate.sourcePath)
        .map((predicate, index) => ({
          id: String(predicate.id ?? `p${index + 1}`),
          label: String(predicate.label ?? ''),
          sourcePath: String(predicate.sourcePath),
          transform: String(predicate.transform ?? 'identity'),
          op: String(predicate.op ?? '=='),
          value: predicate.value ?? null,
          value2: predicate.value2 ?? null
        }))
    : [];
  if (!fields.length && !predicates.length) return null;
  return { fields, predicates };
}

async function safeVerifyArtifact(verifierUrl, artifact) {
  try {
    return await verifyArtifact(verifierUrl, artifact, VERIFIER_TIMEOUT_MS);
  } catch (error) {
    return {
      ok: false,
      integrityVerified: false,
      semanticVerified: false,
      reason:
        error && error.name === 'AbortError'
          ? 'Verifier service timed out'
          : `Verifier service unavailable: ${
              error instanceof Error ? error.message : String(error)
            }`
    };
  }
}

function verifyReceiptSignature(signature) {
  if (!signature || typeof signature !== 'string') {
    return { ok: false, message: 'signature is required' };
  }
  const parts = signature.split('.');
  if (parts.length !== 3) {
    return { ok: false, message: 'malformed receipt token' };
  }
  const verified = verifyReceipt(masterKey, signature);
  if (!verified) {
    return { ok: false, message: 'HMAC signature does not match' };
  }
  try {
    const decoded = JSON.parse(Buffer.from(
      parts[1].replaceAll('-', '+').replaceAll('_', '/'),
      'base64'
    ).toString('utf8'));
    return { ok: true, message: 'Signature verified', payload: decoded };
  } catch {
    return { ok: true, message: 'Signature verified', payload: null };
  }
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
  const owner = req.headers[OWNER_HEADER_NAME];
  if (!owner || Array.isArray(owner) || !owner.trim()) {
    throw Object.assign(new Error(`Missing owner header: ${OWNER_HEADER_NAME}`), {
      code: 'MISSING_OWNER'
    });
  }
  const trimmed = owner.trim();
  if (!OWNER_ID_PATTERN.test(trimmed)) {
    throw Object.assign(new Error('owner id contains unsupported characters'), {
      code: 'BAD_OWNER'
    });
  }
  return trimmed;
}

function sanitizeToken(raw) {
  if (raw == null) return '';
  const trimmed = String(raw).trim();
  if (!TOKEN_PATTERN.test(trimmed)) return '';
  return trimmed;
}

function sanitizeProofId(raw) {
  if (raw == null) return '';
  const trimmed = String(raw).trim();
  if (!trimmed || trimmed.length > 128) return '';
  // Disallow path separators, control characters and anything outside a safe range.
  if (!/^[A-Za-z0-9._:@\-]+$/.test(trimmed)) return '';
  return trimmed;
}

async function readJsonBody(req) {
  const maxBytes = MAX_BODY_BYTES;
  let received = 0;
  const chunks = [];
  for await (const chunk of req) {
    received += chunk.length;
    if (received > maxBytes) {
      throw Object.assign(new Error('body too large'), { code: 'BODY_TOO_LARGE' });
    }
    chunks.push(chunk);
  }
  if (chunks.length === 0) {
    return {};
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw Object.assign(new Error('invalid JSON'), { code: 'BAD_JSON' });
  }
}

function clampInt(value, min, max, fallback) {
  const parsed = Number.parseInt(String(value ?? ''), 10);
  if (!Number.isFinite(parsed)) {
    return fallback;
  }
  return Math.max(min, Math.min(max, parsed));
}

function clientIpOf(req) {
  const forwarded = req.headers['x-forwarded-for'];
  if (typeof forwarded === 'string' && forwarded.length) {
    return forwarded.split(',')[0].trim();
  }
  return req.socket?.remoteAddress ?? 'unknown';
}

function createRateLimiter(windowMs, max) {
  const buckets = new Map();
  return {
    allow(key) {
      const now = Date.now();
      const entry = buckets.get(key);
      if (!entry || now - entry.start >= windowMs) {
        buckets.set(key, { start: now, count: 1 });
        if (buckets.size > 1024) {
          // Drop the oldest bucket to bound memory.
          const firstKey = buckets.keys().next().value;
          if (firstKey !== undefined) buckets.delete(firstKey);
        }
        return true;
      }
      entry.count += 1;
      return entry.count <= max;
    }
  };
}

function setCorsHeaders(res) {
  res.setHeader('access-control-allow-origin', CORS_ALLOWED_ORIGIN);
  res.setHeader('vary', 'origin');
  res.setHeader('access-control-allow-methods', 'GET,POST,OPTIONS');
  res.setHeader(
    'access-control-allow-headers',
    `content-type,${OWNER_HEADER_NAME}`
  );
  res.setHeader('access-control-max-age', '600');
  res.setHeader('x-content-type-options', 'nosniff');
  res.setHeader('referrer-policy', 'no-referrer');
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
