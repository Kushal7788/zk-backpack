import crypto from 'node:crypto';

function toB64Url(buffer) {
  return buffer
    .toString('base64')
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replace(/=+$/g, '');
}

function fromB64Url(value) {
  const normalized = value.replaceAll('-', '+').replaceAll('_', '/');
  const padded = normalized + '='.repeat((4 - (normalized.length % 4)) % 4);
  return Buffer.from(padded, 'base64');
}

export function requireMasterKey(masterKeyB64) {
  const key = Buffer.from(masterKeyB64, 'base64');
  if (key.length !== 32) {
    throw new Error('MASTER_KEY_B64 must decode to 32 bytes');
  }
  return key;
}

export function randomToken(size = 24) {
  return toB64Url(crypto.randomBytes(size));
}

export function encryptJson(masterKey, payload) {
  const plaintext = Buffer.from(JSON.stringify(payload));
  const dek = crypto.randomBytes(32);
  const dataIv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', dek, dataIv);
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const dataTag = cipher.getAuthTag();

  const wrapIv = crypto.randomBytes(12);
  const wrapCipher = crypto.createCipheriv('aes-256-gcm', masterKey, wrapIv);
  const wrappedDek = Buffer.concat([wrapCipher.update(dek), wrapCipher.final()]);
  const wrapTag = wrapCipher.getAuthTag();

  return {
    ciphertextB64: ciphertext.toString('base64'),
    dataIvB64: dataIv.toString('base64'),
    dataTagB64: dataTag.toString('base64'),
    wrappedDekB64: wrappedDek.toString('base64'),
    wrapIvB64: wrapIv.toString('base64'),
    wrapTagB64: wrapTag.toString('base64')
  };
}

export function decryptJson(masterKey, encryptedPayload) {
  const wrappedDek = Buffer.from(encryptedPayload.wrappedDekB64, 'base64');
  const wrapIv = Buffer.from(encryptedPayload.wrapIvB64, 'base64');
  const wrapTag = Buffer.from(encryptedPayload.wrapTagB64, 'base64');
  const unwrap = crypto.createDecipheriv('aes-256-gcm', masterKey, wrapIv);
  unwrap.setAuthTag(wrapTag);
  const dek = Buffer.concat([unwrap.update(wrappedDek), unwrap.final()]);

  const dataIv = Buffer.from(encryptedPayload.dataIvB64, 'base64');
  const dataTag = Buffer.from(encryptedPayload.dataTagB64, 'base64');
  const ciphertext = Buffer.from(encryptedPayload.ciphertextB64, 'base64');
  const decipher = crypto.createDecipheriv('aes-256-gcm', dek, dataIv);
  decipher.setAuthTag(dataTag);
  const clear = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
  return JSON.parse(clear.toString('utf8'));
}

export function sha256B64(input) {
  const buffer = Buffer.isBuffer(input) ? input : Buffer.from(String(input));
  return crypto.createHash('sha256').update(buffer).digest('base64');
}

export function signReceipt(masterKey, receiptPayload) {
  const header = toB64Url(
    Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' }), 'utf8')
  );
  const body = toB64Url(Buffer.from(JSON.stringify(receiptPayload), 'utf8'));
  const toSign = `${header}.${body}`;
  const signature = crypto.createHmac('sha256', masterKey).update(toSign).digest();
  return `${toSign}.${toB64Url(signature)}`;
}

export function verifyReceipt(masterKey, token) {
  const parts = token.split('.');
  if (parts.length !== 3) {
    return false;
  }
  const [header, body, signature] = parts;
  const check = crypto
    .createHmac('sha256', masterKey)
    .update(`${header}.${body}`)
    .digest();
  const provided = fromB64Url(signature);
  if (provided.length !== check.length) {
    return false;
  }
  return crypto.timingSafeEqual(provided, check);
}
