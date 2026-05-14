import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppConfig {
  const AppConfig._();

  static String get verifierUrl =>
      _string('PROOF_VERIFIER_URL', fallback: 'http://localhost:7047');
  static String get shareServiceUrl => _string(
    'ZK_BACKPACK_SHARE_SERVICE_URL',
    fallback: 'http://localhost:8080',
  );
  static int get requestTimeoutMs =>
      _int('PROOF_REQUEST_TIMEOUT_MS', fallback: 300000);
  static bool get preferHighBandwidth =>
      _bool('PROOF_PREFER_HIGH_BANDWIDTH', fallback: false);
  static bool get enableLogging =>
      _bool('PROOF_ENABLE_LOGGING', fallback: true);
  static bool get includeTelemetry =>
      _bool('PROOF_INCLUDE_TELEMETRY_IN_PROOF', fallback: true);
  static bool get enforceNativeCore =>
      _bool('PROOF_ENFORCE_NATIVE_CORE', fallback: true);
  static List<String> get trustedNotaryKeys =>
      _csvList('PROOF_TRUSTED_NOTARY_KEYS_B64');

  static String _string(String key, {required String fallback}) {
    String? value;
    try {
      value = dotenv.env[key]?.trim();
    } catch (_) {
      value = null;
    }
    if (value == null || value.isEmpty) {
      return fallback;
    }
    return value;
  }

  static int _int(String key, {required int fallback}) {
    String? value;
    try {
      value = dotenv.env[key]?.trim();
    } catch (_) {
      value = null;
    }
    if (value == null || value.isEmpty) {
      return fallback;
    }
    return int.tryParse(value) ?? fallback;
  }

  static bool _bool(String key, {required bool fallback}) {
    String? value;
    try {
      value = dotenv.env[key]?.trim().toLowerCase();
    } catch (_) {
      value = null;
    }
    if (value == null || value.isEmpty) {
      return fallback;
    }
    return value == 'true';
  }

  static List<String> _csvList(String key) {
    String? value;
    try {
      value = dotenv.env[key];
    } catch (_) {
      value = null;
    }
    if (value == null || value.trim().isEmpty) {
      return const <String>[];
    }
    return value
        .split(',')
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
  }
}
