import fs from 'node:fs/promises';
import path from 'node:path';

import { randomToken } from './crypto.js';

const SAFE_ID = /^[A-Za-z0-9._:@\-]+$/;

async function ensureDir(dir) {
  await fs.mkdir(dir, { recursive: true });
}

async function readJson(filePath, fallbackValue) {
  try {
    const raw = await fs.readFile(filePath, 'utf8');
    return JSON.parse(raw);
  } catch {
    return fallbackValue;
  }
}

async function writeJson(filePath, value) {
  const dir = path.dirname(filePath);
  const tmp = path.join(
    dir,
    `.${path.basename(filePath)}.${process.pid}.${Date.now()}.tmp`
  );
  await fs.writeFile(tmp, JSON.stringify(value, null, 2));
  await fs.rename(tmp, filePath);
}

const writeQueue = new Map();

function serializeWrites(key, task) {
  const previous = writeQueue.get(key) ?? Promise.resolve();
  const next = previous.catch(() => null).then(task);
  // The tracker swallows results so storing it in the queue cannot
  // create an unhandled-rejection event when the caller is the only
  // consumer of `next`.
  const tracker = next.then(
    () => null,
    () => null
  );
  writeQueue.set(key, tracker);
  tracker.finally(() => {
    if (writeQueue.get(key) === tracker) {
      writeQueue.delete(key);
    }
  });
  return next;
}

export class FileStore {
  constructor(dataDir) {
    this.dataDir = dataDir;
    this.proofDbPath = path.join(dataDir, 'proofs.json');
    this.shareDbPath = path.join(dataDir, 'shares.json');
    this.auditPath = path.join(dataDir, 'audit.jsonl');
    this.blobDir = path.join(dataDir, 'proof_blobs');
  }

  async init() {
    await ensureDir(this.dataDir);
    await ensureDir(this.blobDir);
    await writeJsonIfMissing(this.proofDbPath, {});
    await writeJsonIfMissing(this.shareDbPath, {});
    await appendFileIfMissing(this.auditPath);
  }

  blobPathFor(proofId) {
    if (!SAFE_ID.test(String(proofId))) {
      throw new Error('unsafe proof id');
    }
    const resolved = path.resolve(this.blobDir, `${proofId}.json`);
    if (!resolved.startsWith(`${this.blobDir}${path.sep}`)) {
      throw new Error('proof id resolves outside blob dir');
    }
    return resolved;
  }

  async saveEncryptedProof(record, encryptedPayload) {
    if (!SAFE_ID.test(String(record.proofId))) {
      throw new Error('unsafe proof id');
    }
    return serializeWrites(this.proofDbPath, async () => {
      const proofs = await readJson(this.proofDbPath, {});
      const blobPath = this.blobPathFor(record.proofId);
      await writeJson(blobPath, encryptedPayload);
      proofs[record.proofId] = {
        ...record,
        blobPath,
        createdAtUtc: new Date().toISOString()
      };
      await writeJson(this.proofDbPath, proofs);
      return proofs[record.proofId];
    });
  }

  async getProof(proofId) {
    const proofs = await readJson(this.proofDbPath, {});
    return proofs[proofId] ?? null;
  }

  async getEncryptedBlob(blobPath) {
    const resolved = path.resolve(String(blobPath));
    if (!resolved.startsWith(`${this.blobDir}${path.sep}`)) {
      return null;
    }
    return readJson(resolved, null);
  }

  async createShare({
    ownerId,
    proofId,
    policyTemplate,
    expiresInMinutes,
    oneTimeView,
    maxViews,
    selection
  }) {
    return serializeWrites(this.shareDbPath, async () => {
      const shares = await readJson(this.shareDbPath, {});
      let token;
      do {
        token = randomToken(24);
      } while (shares[token]);
      const createdAt = Date.now();
      const expiresAt = createdAt + expiresInMinutes * 60 * 1000;
      shares[token] = {
        token,
        ownerId,
        proofId,
        policyTemplate,
        selection: selection ?? null,
        createdAtUtc: new Date(createdAt).toISOString(),
        expiresAtUtc: new Date(expiresAt).toISOString(),
        oneTimeView: Boolean(oneTimeView),
        maxViews: maxViews ?? null,
        views: 0,
        revoked: false
      };
      await writeJson(this.shareDbPath, shares);
      return shares[token];
    });
  }

  async getShare(token) {
    const shares = await readJson(this.shareDbPath, {});
    return shares[token] ?? null;
  }

  async revokeShare({ token, ownerId }) {
    return serializeWrites(this.shareDbPath, async () => {
      const shares = await readJson(this.shareDbPath, {});
      const share = shares[token];
      if (!share) {
        return null;
      }
      if (share.ownerId !== ownerId) {
        throw new Error('forbidden');
      }
      if (share.revoked) {
        return share;
      }
      share.revoked = true;
      share.revokedAtUtc = new Date().toISOString();
      shares[token] = share;
      await writeJson(this.shareDbPath, shares);
      return share;
    });
  }

  async consumeShareView(token) {
    return serializeWrites(this.shareDbPath, async () => {
      const shares = await readJson(this.shareDbPath, {});
      const share = shares[token];
      if (!share) {
        return null;
      }
      share.views = Number(share.views ?? 0) + 1;
      shares[token] = share;
      await writeJson(this.shareDbPath, shares);
      return share;
    });
  }

  async appendAudit(event) {
    await fs.appendFile(this.auditPath, `${JSON.stringify(event)}\n`);
  }
}

async function writeJsonIfMissing(filePath, value) {
  try {
    await fs.access(filePath);
  } catch {
    await writeJson(filePath, value);
  }
}

async function appendFileIfMissing(filePath) {
  try {
    await fs.access(filePath);
  } catch {
    await fs.writeFile(filePath, '');
  }
}
