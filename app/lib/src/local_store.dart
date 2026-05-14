import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'models.dart';

class SecureLocalProofStore {
  SecureLocalProofStore({FlutterSecureStorage? secureStorage, Cipher? cipher})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
      _cipher = cipher ?? AesGcm.with256bits();

  static const _tableName = 'proof_records';
  static const _keyName = 'zk_backpack_aes_key_b64';

  final FlutterSecureStorage _secureStorage;
  final Cipher _cipher;
  Database? _db;

  Future<void> init() async {
    if (_db != null) {
      return;
    }
    final documentsDir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(documentsDir.path, 'zk_backpack.db');
    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_tableName (
            proof_id TEXT PRIMARY KEY,
            provider_id TEXT NOT NULL,
            created_at_utc TEXT NOT NULL,
            integrity_digest TEXT NOT NULL,
            target_host TEXT NOT NULL,
            encrypted_artifact_b64 TEXT NOT NULL,
            nonce_b64 TEXT NOT NULL,
            mac_b64 TEXT NOT NULL,
            cloud_proof_id TEXT,
            share_token TEXT,
            share_url TEXT,
            share_status TEXT NOT NULL
          );
        ''');
      },
    );
  }

  Future<List<ProofRecord>> listProofs() async {
    await init();
    final rows = await _db!.query(_tableName, orderBy: 'created_at_utc DESC');
    return rows.map(ProofRecord.fromDbMap).toList(growable: false);
  }

  Future<void> saveEncryptedProof({
    required String proofId,
    required String providerId,
    required String createdAtUtc,
    required String artifactJson,
    required String integrityDigest,
    required String targetHost,
  }) async {
    await init();
    final key = await _loadOrCreateKey();
    final nonce = _randomBytes(12);
    final secretBox = await _cipher.encrypt(
      utf8.encode(artifactJson),
      secretKey: key,
      nonce: nonce,
    );
    final record = ProofRecord(
      proofId: proofId,
      providerId: providerId,
      createdAtUtc: createdAtUtc,
      integrityDigest: integrityDigest,
      targetHost: targetHost,
      encryptedArtifactB64: base64Encode(secretBox.cipherText),
      nonceB64: base64Encode(secretBox.nonce),
      macB64: base64Encode(secretBox.mac.bytes),
    );
    await _db!.insert(
      _tableName,
      record.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String> decryptProofArtifactJson(ProofRecord record) async {
    await init();
    final key = await _loadOrCreateKey();
    final secretBox = SecretBox(
      base64Decode(record.encryptedArtifactB64),
      nonce: base64Decode(record.nonceB64),
      mac: Mac(base64Decode(record.macB64)),
    );
    final clear = await _cipher.decrypt(secretBox, secretKey: key);
    return utf8.decode(clear);
  }

  Future<void> updateCloudShareState({
    required String proofId,
    String? cloudProofId,
    String? shareToken,
    String? shareUrl,
    String? shareStatus,
  }) async {
    await init();
    final updates = <String, Object?>{};
    if (cloudProofId != null) {
      updates['cloud_proof_id'] = cloudProofId;
    }
    if (shareToken != null) {
      updates['share_token'] = shareToken;
    }
    if (shareUrl != null) {
      updates['share_url'] = shareUrl;
    }
    if (shareStatus != null) {
      updates['share_status'] = shareStatus;
    }
    if (updates.isEmpty) {
      return;
    }
    await _db!.update(
      _tableName,
      updates,
      where: 'proof_id = ?',
      whereArgs: <Object?>[proofId],
    );
  }

  Future<void> deleteProof(String proofId) async {
    await init();
    await _db!.delete(
      _tableName,
      where: 'proof_id = ?',
      whereArgs: <Object?>[proofId],
    );
  }

  Future<SecretKey> _loadOrCreateKey() async {
    final existing = await _secureStorage.read(key: _keyName);
    if (existing != null && existing.isNotEmpty) {
      return SecretKey(base64Decode(existing));
    }
    final bytes = _randomBytes(32);
    await _secureStorage.write(key: _keyName, value: base64Encode(bytes));
    return SecretKey(bytes);
  }

  Uint8List _randomBytes(int length) {
    final rng = Random.secure();
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = rng.nextInt(256);
    }
    return bytes;
  }
}
