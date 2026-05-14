import fs from 'node:fs/promises';
import path from 'node:path';

import { randomToken } from './crypto.js';

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
  await fs.writeFile(filePath, JSON.stringify(value, null, 2));
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

  async saveEncryptedProof(record, encryptedPayload) {
    const proofs = await readJson(this.proofDbPath, {});
    const blobPath = path.join(this.blobDir, `${record.proofId}.json`);
    await writeJson(blobPath, encryptedPayload);
    proofs[record.proofId] = {
      ...record,
      blobPath,
      createdAtUtc: new Date().toISOString()
    };
    await writeJson(this.proofDbPath, proofs);
    return proofs[record.proofId];
  }

  async getProof(proofId) {
    const proofs = await readJson(this.proofDbPath, {});
    return proofs[proofId] ?? null;
  }

  async getEncryptedBlob(blobPath) {
    return readJson(blobPath, null);
  }

  async createShare({
    ownerId,
    proofId,
    policyTemplate,
    expiresInMinutes,
    oneTimeView,
    maxViews
  }) {
    const shares = await readJson(this.shareDbPath, {});
    const token = randomToken(24);
    const createdAt = Date.now();
    const expiresAt = createdAt + expiresInMinutes * 60 * 1000;
    shares[token] = {
      token,
      ownerId,
      proofId,
      policyTemplate,
      createdAtUtc: new Date(createdAt).toISOString(),
      expiresAtUtc: new Date(expiresAt).toISOString(),
      oneTimeView: Boolean(oneTimeView),
      maxViews: maxViews ?? null,
      views: 0,
      revoked: false
    };
    await writeJson(this.shareDbPath, shares);
    return shares[token];
  }

  async getShare(token) {
    const shares = await readJson(this.shareDbPath, {});
    return shares[token] ?? null;
  }

  async revokeShare({ token, ownerId }) {
    const shares = await readJson(this.shareDbPath, {});
    const share = shares[token];
    if (!share) {
      return null;
    }
    if (share.ownerId !== ownerId) {
      throw new Error('forbidden');
    }
    share.revoked = true;
    share.revokedAtUtc = new Date().toISOString();
    shares[token] = share;
    await writeJson(this.shareDbPath, shares);
    return share;
  }

  async consumeShareView(token) {
    const shares = await readJson(this.shareDbPath, {});
    const share = shares[token];
    if (!share) {
      return null;
    }
    share.views = Number(share.views ?? 0) + 1;
    shares[token] = share;
    await writeJson(this.shareDbPath, shares);
    return share;
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
