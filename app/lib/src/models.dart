import 'dart:convert';

import 'share_selection.dart';

class ProviderConfig {
  const ProviderConfig({
    required this.label,
    required this.description,
    required this.providerId,
  });

  final String label;
  final String description;
  final String providerId;

  factory ProviderConfig.fromJson(Map<String, Object?> json) {
    return ProviderConfig(
      label: (json['label'] as String?)?.trim() ?? 'Unknown',
      description: (json['description'] as String?)?.trim() ?? '',
      providerId: (json['providerId'] as String?)?.trim() ?? '',
    );
  }
}

class ProofRecord {
  const ProofRecord({
    required this.proofId,
    required this.providerId,
    required this.createdAtUtc,
    required this.integrityDigest,
    required this.targetHost,
    required this.encryptedArtifactB64,
    required this.nonceB64,
    required this.macB64,
    this.cloudProofId,
    this.shareToken,
    this.shareUrl,
    this.shareStatus = 'local_only',
  });

  final String proofId;
  final String providerId;
  final String createdAtUtc;
  final String integrityDigest;
  final String targetHost;
  final String encryptedArtifactB64;
  final String nonceB64;
  final String macB64;
  final String? cloudProofId;
  final String? shareToken;
  final String? shareUrl;
  final String shareStatus;

  ProofRecord copyWith({
    String? cloudProofId,
    String? shareToken,
    String? shareUrl,
    String? shareStatus,
  }) {
    return ProofRecord(
      proofId: proofId,
      providerId: providerId,
      createdAtUtc: createdAtUtc,
      integrityDigest: integrityDigest,
      targetHost: targetHost,
      encryptedArtifactB64: encryptedArtifactB64,
      nonceB64: nonceB64,
      macB64: macB64,
      cloudProofId: cloudProofId ?? this.cloudProofId,
      shareToken: shareToken ?? this.shareToken,
      shareUrl: shareUrl ?? this.shareUrl,
      shareStatus: shareStatus ?? this.shareStatus,
    );
  }

  Map<String, Object?> toDbMap() {
    return <String, Object?>{
      'proof_id': proofId,
      'provider_id': providerId,
      'created_at_utc': createdAtUtc,
      'integrity_digest': integrityDigest,
      'target_host': targetHost,
      'encrypted_artifact_b64': encryptedArtifactB64,
      'nonce_b64': nonceB64,
      'mac_b64': macB64,
      'cloud_proof_id': cloudProofId,
      'share_token': shareToken,
      'share_url': shareUrl,
      'share_status': shareStatus,
    };
  }

  factory ProofRecord.fromDbMap(Map<String, Object?> map) {
    return ProofRecord(
      proofId: map['proof_id'] as String,
      providerId: map['provider_id'] as String,
      createdAtUtc: map['created_at_utc'] as String,
      integrityDigest: map['integrity_digest'] as String? ?? '',
      targetHost: map['target_host'] as String? ?? '',
      encryptedArtifactB64: map['encrypted_artifact_b64'] as String,
      nonceB64: map['nonce_b64'] as String,
      macB64: map['mac_b64'] as String,
      cloudProofId: map['cloud_proof_id'] as String?,
      shareToken: map['share_token'] as String?,
      shareUrl: map['share_url'] as String?,
      shareStatus: map['share_status'] as String? ?? 'local_only',
    );
  }
}

class ShareCreateResult {
  const ShareCreateResult({
    required this.token,
    required this.url,
    required this.expiresAtUtc,
  });

  final String token;
  final String url;
  final String expiresAtUtc;

  factory ShareCreateResult.fromJson(Map<String, Object?> json) {
    return ShareCreateResult(
      token: json['token'] as String,
      url: json['url'] as String,
      expiresAtUtc: json['expiresAtUtc'] as String,
    );
  }
}

class SharePolicyPreset {
  const SharePolicyPreset({
    required this.id,
    required this.label,
    required this.description,
    required this.expiresInMinutes,
    required this.oneTimeView,
    required this.maxViews,
  });

  final String id;
  final String label;
  final String description;
  final int expiresInMinutes;
  final bool oneTimeView;
  final int? maxViews;
}

class ShareRecipe {
  const ShareRecipe({
    required this.id,
    required this.label,
    required this.category,
    required this.providerIds,
    required this.selection,
    this.description = '',
  });

  final String id;
  final String label;
  final String category;
  final List<String> providerIds;
  final ShareSelection selection;
  final String description;

  factory ShareRecipe.fromJson(Map<String, Object?> json) {
    final providerIds = (json['providerIds'] as List<Object?>? ?? const [])
        .whereType<String>()
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    final rawSelection = json['selection'];
    return ShareRecipe(
      id: (json['id'] as String?)?.trim() ?? '',
      label: (json['label'] as String?)?.trim() ?? 'Recipe',
      category: (json['category'] as String?)?.trim() ?? 'General',
      providerIds: providerIds,
      description: (json['description'] as String?)?.trim() ?? '',
      selection: rawSelection is Map<String, Object?>
          ? ShareSelection.fromJson(rawSelection)
          : const ShareSelection(),
    );
  }
}

class ShareViewResponse {
  const ShareViewResponse({
    required this.status,
    required this.message,
    required this.verification,
    required this.scopedClaims,
    required this.receipt,
  });

  final String status;
  final String message;
  final Map<String, Object?> verification;
  // Server-projected claims. Has shape:
  //   { "fields": {label: value, ...},
  //     "predicates": [ {label, expression, satisfied, evaluable, reason?} ] }
  // Older shares without selection still return a flat field map.
  final Map<String, Object?> scopedClaims;
  final Map<String, Object?> receipt;

  factory ShareViewResponse.fromJson(Map<String, Object?> json) {
    return ShareViewResponse(
      status: json['status'] as String? ?? 'invalid',
      message: json['message'] as String? ?? '',
      verification:
          (json['verification'] as Map<String, Object?>?) ??
          const <String, Object?>{},
      scopedClaims:
          (json['scopedClaims'] as Map<String, Object?>?) ??
          const <String, Object?>{},
      receipt:
          (json['receipt'] as Map<String, Object?>?) ??
          const <String, Object?>{},
    );
  }

  Map<String, Object?> get revealedFields {
    final fields = scopedClaims['fields'];
    if (fields is Map<String, Object?>) return fields;
    // Backward compat: legacy shares stored claims flat.
    if (scopedClaims.containsKey('predicates') ||
        scopedClaims.containsKey('fields')) {
      return const <String, Object?>{};
    }
    return scopedClaims;
  }

  List<Map<String, Object?>> get revealedPredicates {
    final raw = scopedClaims['predicates'];
    if (raw is List) {
      return raw.whereType<Map<String, Object?>>().toList(growable: false);
    }
    return const <Map<String, Object?>>[];
  }

  String prettyScopedClaims() {
    return const JsonEncoder.withIndent('  ').convert(scopedClaims);
  }
}

class ReceiptVerifyResult {
  const ReceiptVerifyResult({
    required this.ok,
    required this.message,
    this.payload,
  });

  final bool ok;
  final String message;
  final Map<String, Object?>? payload;

  factory ReceiptVerifyResult.fromJson(Map<String, Object?> json) {
    final raw = json['payload'];
    return ReceiptVerifyResult(
      ok: json['ok'] == true,
      message: (json['message'] as String?) ?? '',
      payload: raw is Map<String, Object?> ? raw : null,
    );
  }
}
