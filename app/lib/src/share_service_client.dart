import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'share_selection.dart';

class ShareServiceClient {
  ShareServiceClient({
    required this.baseUrl,
    required this.ownerId,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  final String baseUrl;
  final String ownerId;
  final http.Client _httpClient;

  Future<String> uploadProof({
    required ProofRecord record,
    required String artifactJson,
  }) async {
    final uri = Uri.parse('$baseUrl/proofs');
    final response = await _httpClient.post(
      uri,
      headers: _headers(),
      body: jsonEncode(<String, Object?>{
        'proofId': record.proofId,
        'providerId': record.providerId,
        'createdAtUtc': record.createdAtUtc,
        'integrityDigest': record.integrityDigest,
        'targetHost': record.targetHost,
        'artifact': jsonDecode(artifactJson),
      }),
    );
    final body = _readJsonBody(response);
    if (response.statusCode >= 300) {
      throw Exception(body['message'] ?? 'Upload failed');
    }
    return body['proofId'] as String;
  }

  Future<ShareCreateResult> createShare({
    required String proofId,
    required String policyTemplate,
    required int expiresInMinutes,
    required bool oneTimeView,
    required int? maxViews,
    ShareSelection? selection,
  }) async {
    final uri = Uri.parse('$baseUrl/shares');
    final response = await _httpClient.post(
      uri,
      headers: _headers(),
      body: jsonEncode(<String, Object?>{
        'proofId': proofId,
        'policyTemplate': policyTemplate,
        'expiresInMinutes': expiresInMinutes,
        'oneTimeView': oneTimeView,
        'maxViews': maxViews,
        if (selection != null && !selection.isEmpty)
          'selection': selection.toJson(),
      }),
    );
    final body = _readJsonBody(response);
    if (response.statusCode >= 300) {
      throw Exception(body['message'] ?? 'Share creation failed');
    }
    return ShareCreateResult.fromJson(body);
  }

  Future<void> revokeShare(String token) async {
    final uri = Uri.parse('$baseUrl/shares/$token/revoke');
    final response = await _httpClient.post(
      uri,
      headers: _headers(),
      body: jsonEncode(<String, Object?>{}),
    );
    if (response.statusCode >= 300) {
      final body = _readJsonBody(response);
      throw Exception(body['message'] ?? 'Revoke failed');
    }
  }

  Future<ShareViewResponse> viewSharedCredential({
    required String token,
  }) async {
    final uri = Uri.parse('$baseUrl/api/share/view?token=$token');
    final response = await _httpClient.get(uri, headers: _headers());
    final body = _readJsonBody(response);
    return ShareViewResponse.fromJson(body);
  }

  Future<ReceiptVerifyResult> verifyReceiptSignature({
    required String signature,
  }) async {
    final uri = Uri.parse('$baseUrl/api/share/receipt/verify');
    final response = await _httpClient.post(
      uri,
      headers: _headers(),
      body: jsonEncode(<String, Object?>{'signature': signature}),
    );
    final body = _readJsonBody(response);
    return ReceiptVerifyResult.fromJson(body);
  }

  Map<String, String> _headers() {
    return <String, String>{
      'content-type': 'application/json',
      'x-owner-id': ownerId,
    };
  }

  Map<String, Object?> _readJsonBody(http.Response response) {
    if (response.body.trim().isEmpty) {
      return const <String, Object?>{};
    }
    return (jsonDecode(response.body) as Map).cast<String, Object?>();
  }
}
