import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:mobile_proof_plugin/mobile_tlsn_plugin.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'src/app_config.dart';
import 'src/local_store.dart';
import 'src/models.dart';
import 'src/share_service_client.dart';

const _brandLogoAssetPath = 'assets/branding/backpack_logo.png';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  runApp(const ZkBackpackApp());
}

class ZkBackpackApp extends StatelessWidget {
  const ZkBackpackApp({super.key});

  @override
  Widget build(BuildContext context) {
    final light = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0E7490),
      brightness: Brightness.light,
    );
    final dark = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0E7490),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'ZK Backpack',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: _buildTheme(light),
      darkTheme: _buildTheme(dark),
      home: const ZkBackpackHomePage(),
    );
  }

  ThemeData _buildTheme(ColorScheme scheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surfaceContainerLowest,
      appBarTheme: AppBarTheme(
        elevation: 0,
        centerTitle: false,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primaryContainer,
        elevation: 0,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

class ZkBackpackHomePage extends StatefulWidget {
  const ZkBackpackHomePage({super.key});

  @override
  State<ZkBackpackHomePage> createState() => _ZkBackpackHomePageState();
}

class _ZkBackpackHomePageState extends State<ZkBackpackHomePage> {
  static const _providerCatalogAssetPath = 'assets/provider_catalog.json';
  static const _providerRegistryAssetPath =
      'packages/mobile_proof_plugin/assets/providers.json';

  final SecureLocalProofStore _store = SecureLocalProofStore();
  late final ShareServiceClient _shareClient = ShareServiceClient(
    baseUrl: AppConfig.shareServiceUrl,
    ownerId: 'demo-user-kushal',
  );
  final TextEditingController _shareTokenController = TextEditingController();

  List<ProviderConfig> _providers = const <ProviderConfig>[];
  Map<String, ProviderConfig> _providerById = const <String, ProviderConfig>{};
  ProviderConfig? _selectedProvider;
  List<ProofRecord> _proofs = const <ProofRecord>[];
  Map<String, _ProofPresentation> _proofPresentationById =
      const <String, _ProofPresentation>{};

  bool _running = false;
  bool _processingScan = false;
  bool _loadingVaultCards = false;
  int _tabIndex = 0;
  int _scanSessionVersion = 0;
  Set<String> _expandedProofIds = <String>{};
  String _statusMessage = 'Loading your backpack...';
  String _generationStep = '';
  double _generationPercent = 0;
  ShareViewResponse? _scanResult;
  String? _scanError;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _shareTokenController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      await _store.init();
      await _loadProviderCatalog();
      await _reloadProofs();
      _statusMessage = 'Ready';
    } catch (error) {
      _showErrorSnack('Could not initialize app: $error');
      _statusMessage = 'Setup failed';
    }
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  Future<void> _loadProviderCatalog() async {
    final raw = await rootBundle.loadString(_providerCatalogAssetPath);
    final decoded = jsonDecode(raw) as Map<String, Object?>;
    final providers = (decoded['providers'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .map(ProviderConfig.fromJson)
        .where((provider) => provider.providerId.isNotEmpty)
        .toList(growable: false);
    if (!mounted) {
      return;
    }
    setState(() {
      _providers = providers;
      _providerById = <String, ProviderConfig>{
        for (final provider in providers) provider.providerId: provider,
      };
      _selectedProvider = providers.isEmpty ? null : providers.first;
    });
  }

  Future<void> _reloadProofs() async {
    final proofs = await _store.listProofs();
    if (!mounted) {
      return;
    }
    setState(() {
      _proofs = proofs;
      _loadingVaultCards = true;
      _expandedProofIds = _expandedProofIds
          .where((proofId) => proofs.any((proof) => proof.proofId == proofId))
          .toSet();
    });
    await _loadProofPresentations(proofs);
  }

  Future<void> _loadProofPresentations(List<ProofRecord> proofs) async {
    final presentation = <String, _ProofPresentation>{};
    for (final proof in proofs) {
      try {
        final decrypted = await _store.decryptProofArtifactJson(proof);
        final decoded = jsonDecode(decrypted);
        final revealed = _extractRevealedEntries(decoded);
        presentation[proof.proofId] = _ProofPresentation(
          revealedEntries: revealed,
          targetEndpoint: _extractTargetEndpoint(
            decoded,
            fallbackHost: proof.targetHost,
          ),
          loadedSuccessfully: true,
        );
      } catch (_) {
        presentation[proof.proofId] = _ProofPresentation(
          revealedEntries: <_DisplayEntry>[],
          targetEndpoint: proof.targetHost,
          loadedSuccessfully: false,
        );
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _proofPresentationById = presentation;
      _loadingVaultCards = false;
    });
  }

  Future<void> _generateProof() async {
    final provider = _selectedProvider;
    if (provider == null) {
      _showErrorSnack('Please select a provider first.');
      return;
    }
    final verifierUrl = Uri.tryParse(AppConfig.verifierUrl.trim());
    if (verifierUrl == null) {
      _showErrorSnack('Verifier URL is invalid in app config.');
      return;
    }

    setState(() {
      _running = true;
      _generationPercent = 0;
      _generationStep = 'Preparing secure proof flow...';
      _statusMessage = 'Generating proof with ${provider.label}';
    });

    final client = MobileProofClient(bridge: MethodChannelNativeBridge());
    final progressSub = client.subscribeProgress().listen((progress) {
      if (!mounted) {
        return;
      }
      setState(() {
        _generationPercent = progress.percent.clamp(0, 1);
        _generationStep = progress.message.trim().isEmpty
            ? progress.phase.name
            : progress.message.trim();
      });
    });

    try {
      final artifact = await client.attestProvider(
        context: context,
        providerId: provider.providerId,
        providerRegistryAssetPath: _providerRegistryAssetPath,
        transportConfig: TransportConfig(
          deploymentMode: DeploymentMode.hosted,
          verifierUrl: verifierUrl,
          requestTimeoutMs: AppConfig.requestTimeoutMs,
          preferHighBandwidth: AppConfig.preferHighBandwidth,
          trustedNotaryKeys: AppConfig.trustedNotaryKeys,
          enableLogging: AppConfig.enableLogging,
          includeProofTelemetry: AppConfig.includeTelemetry,
          enforceNativeCore: AppConfig.enforceNativeCore,
        ),
      );
      final artifactJson = client.exportProof(
        ProofExportFormat.prettyJson,
        artifact: artifact,
      );
      final integrity = artifact.integrity ?? const <String, Object?>{};
      final transcriptSummary = artifact.transcriptSummary;
      final targetHost = (transcriptSummary['targetHost'] as String?) ?? '';
      final digest = (integrity['digestBase64'] as String?) ?? '';
      await _store.saveEncryptedProof(
        proofId: artifact.proofId,
        providerId: provider.providerId,
        createdAtUtc: artifact.createdAtUtc.toUtc().toIso8601String(),
        artifactJson: artifactJson,
        integrityDigest: digest,
        targetHost: targetHost,
      );
      await _reloadProofs();
      _showInfoSnack('Proof generated and saved in your backpack.');
      if (!mounted) {
        return;
      }
      setState(() {
        _tabIndex = 0;
        _statusMessage = 'Proof ready in vault';
      });
    } on ProofException catch (error) {
      _showErrorSnack('[${error.code.name}] ${error.message}');
      if (mounted) {
        setState(() {
          _statusMessage = 'Proof generation failed';
        });
      }
    } catch (error) {
      _showErrorSnack('Proof generation failed: $error');
      if (mounted) {
        setState(() {
          _statusMessage = 'Proof generation failed';
        });
      }
    } finally {
      await progressSub.cancel();
      await client.dispose();
      if (mounted) {
        setState(() {
          _running = false;
        });
      }
    }
  }

  Future<void> _uploadAndShare(ProofRecord record) async {
    try {
      _showInfoSnack('Preparing secure share...');
      final decryptedJson = await _store.decryptProofArtifactJson(record);
      final cloudProofId = await _shareClient.uploadProof(
        record: record,
        artifactJson: decryptedJson,
      );
      await _store.updateCloudShareState(
        proofId: record.proofId,
        cloudProofId: cloudProofId,
        shareStatus: 'uploaded',
      );
      final shareResult = await _shareClient.createShare(
        proofId: record.proofId,
        policyTemplate: 'masked',
        expiresInMinutes: 60,
        oneTimeView: false,
        maxViews: 10,
      );
      await _store.updateCloudShareState(
        proofId: record.proofId,
        shareToken: shareResult.token,
        shareUrl: shareResult.url,
        shareStatus: 'shared',
      );
      await _reloadProofs();
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (context) {
          final scheme = Theme.of(context).colorScheme;
          return Dialog(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        const CircleAvatar(
                          radius: 18,
                          backgroundImage: AssetImage(_brandLogoAssetPath),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Share Proof',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Center(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: SizedBox(
                            width: 210,
                            height: 210,
                            child: QrImageView(data: shareResult.url),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    InkWell(
                      onTap: () => _openExternalLink(shareResult.url),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        child: Text(
                          shareResult.url,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.primary,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Done'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    } catch (error) {
      _showErrorSnack('Share failed: $error');
    }
  }

  Future<void> _revokeShare(ProofRecord record) async {
    final token = record.shareToken;
    if (token == null || token.isEmpty) {
      return;
    }
    try {
      await _shareClient.revokeShare(token);
      await _store.updateCloudShareState(
        proofId: record.proofId,
        shareStatus: 'revoked',
      );
      await _reloadProofs();
      _showInfoSnack('Share access revoked.');
    } catch (error) {
      _showErrorSnack('Could not revoke share: $error');
    }
  }

  Future<void> _openShareInBrowserView(String token) async {
    final activeSessionVersion = _scanSessionVersion;
    setState(() {
      _processingScan = true;
      _scanResult = null;
      _scanError = null;
    });
    try {
      final response = await _shareClient.viewSharedCredential(token: token);
      if (!mounted) {
        return;
      }
      if (activeSessionVersion != _scanSessionVersion) {
        return;
      }
      setState(() {
        _scanResult = response;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      if (activeSessionVersion != _scanSessionVersion) {
        return;
      }
      setState(() {
        _scanError = error.toString();
      });
    } finally {
      if (mounted && activeSessionVersion == _scanSessionVersion) {
        setState(() {
          _processingScan = false;
        });
      }
    }
  }

  void _resetScanTabState() {
    _scanSessionVersion += 1;
    _shareTokenController.clear();
    _scanResult = null;
    _scanError = null;
    _processingScan = false;
  }

  void _onDestinationSelected(int index) {
    setState(() {
      if (_tabIndex == 2 && index != 2) {
        _resetScanTabState();
      }
      _tabIndex = index;
    });
  }

  String _extractToken(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri != null && uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.last;
    }
    return raw.trim();
  }

  Future<void> _openExternalLink(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null) {
      _showErrorSnack('Invalid share URL');
      return;
    }
    await Clipboard.setData(ClipboardData(text: rawUrl.trim()));
    _showInfoSnack('Link copied to clipboard');
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      _showErrorSnack('Could not open the share link');
    }
  }

  List<_DisplayEntry> _extractRevealedEntries(Object? decoded) {
    if (decoded is! Map<String, Object?>) {
      return const <_DisplayEntry>[];
    }
    final payload = decoded['payload'];
    if (payload is Map<String, Object?>) {
      final response = payload['response'];
      if (response is Map<String, Object?>) {
        final revealedBody = response['revealedBody'];
        if (revealedBody is Map<String, Object?> && revealedBody.isNotEmpty) {
          return revealedBody.entries
              .take(20)
              .map(
                (entry) => _DisplayEntry(
                  label: _prettifyKey(entry.key),
                  value: _printableValue(entry.value),
                ),
              )
              .toList(growable: false);
        }
      }
    }
    final candidate = _firstNonEmptyMap(
      <Object?>[
        decoded['revealedData'],
        decoded['revealed'],
        decoded['claims'],
        decoded['scopedClaims'],
      ],
    );
    final source = candidate ?? decoded;
    final flattened = <String, String>{};
    _flattenValues(source, flattened, prefix: '');
    if (flattened.isEmpty) {
      return const <_DisplayEntry>[];
    }
    return flattened.entries
        .take(14)
        .map((entry) {
          return _DisplayEntry(
            label: _prettifyKey(entry.key),
            value: entry.value,
          );
        })
        .toList(growable: false);
  }

  String _extractTargetEndpoint(
    Object? decoded, {
    required String fallbackHost,
  }) {
    if (decoded is Map<String, Object?>) {
      final payload = decoded['payload'];
      if (payload is Map<String, Object?>) {
        final request = payload['request'];
        if (request is Map<String, Object?>) {
          final endpoint = request['endpoint'];
          if (endpoint is Map<String, Object?>) {
            final method = (endpoint['method'] as String?)?.trim() ?? '';
            final host =
                (endpoint['host'] as String?)?.trim() ??
                fallbackHost.trim();
            final path = (endpoint['path'] as String?)?.trim() ?? '';
            final uri = '$host$path'.trim();
            if (uri.isNotEmpty) {
              return method.isEmpty ? uri : '$method $uri';
            }
          }
        }
      }
    }
    if (fallbackHost.trim().isNotEmpty) {
      return fallbackHost.trim();
    }
    return 'Not available';
  }

  Map<String, Object?>? _firstNonEmptyMap(List<Object?> values) {
    for (final value in values) {
      if (value is Map<String, Object?> && value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  void _flattenValues(
    Object? value,
    Map<String, String> out, {
    required String prefix,
  }) {
    if (value is Map<String, Object?>) {
      value.forEach((key, nested) {
        final next = prefix.isEmpty ? key : '$prefix.$key';
        _flattenValues(nested, out, prefix: next);
      });
      return;
    }
    if (value is List<Object?>) {
      final printable = value.map(_printableValue).join(', ');
      if (printable.trim().isNotEmpty) {
        out[prefix] = printable;
      }
      return;
    }
    if (value == null) {
      return;
    }
    out[prefix] = _printableValue(value);
  }

  String _printableValue(Object? value) {
    if (value == null) {
      return '';
    }
    if (value is String) {
      return value.trim();
    }
    if (value is num || value is bool) {
      return value.toString();
    }
    return jsonEncode(value);
  }

  String _prettifyKey(String key) {
    var cleaned = key.trim();
    if (cleaned.startsWith(r'$.')) {
      cleaned = cleaned.substring(2);
    }
    final pathParts = cleaned
        .split('.')
        .where((part) => part.trim().isNotEmpty)
        .toList(growable: false);
    final source = pathParts.isEmpty ? cleaned : pathParts.last;
    final words = source
        .replaceAll(RegExp(r'[^a-zA-Z0-9]+'), ' ')
        .replaceAll(RegExp(r'([a-z])([A-Z])'), r'$1 $2')
        .split(' ')
        .where((word) => word.trim().isNotEmpty)
        .map((word) => '${word[0].toUpperCase()}${word.substring(1)}');
    return words.join(' ');
  }

  String _providerLabel(String providerId) {
    return _providerById[providerId]?.label ?? providerId;
  }

  void _toggleProofExpanded(String proofId) {
    setState(() {
      if (_expandedProofIds.contains(proofId)) {
        _expandedProofIds.remove(proofId);
      } else {
        _expandedProofIds.add(proofId);
      }
    });
  }

  String _formatDate(String rawUtc) {
    final parsed = DateTime.tryParse(rawUtc);
    if (parsed == null) {
      return rawUtc;
    }
    final local = parsed.toLocal();
    return '${local.year}-${_two(local.month)}-${_two(local.day)} ${_two(local.hour)}:${_two(local.minute)}';
  }

  String _two(int value) => value.toString().padLeft(2, '0');

  void _showInfoSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(message),
      ),
    );
  }

  void _showErrorSnack(String message) {
    if (!mounted) {
      return;
    }
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        backgroundColor: scheme.errorContainer,
        content: Text(
          message,
          style: TextStyle(color: scheme.onErrorContainer),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        title: Row(
          children: <Widget>[
            const CircleAvatar(
              radius: 16,
              backgroundImage: AssetImage(_brandLogoAssetPath),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'ZK Backpack',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  _statusMessage,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: _onDestinationSelected,
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.backpack_outlined),
            label: 'Vault',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            label: 'Generate',
          ),
          NavigationDestination(
            icon: Icon(Icons.qr_code_scanner_rounded),
            label: 'Scan',
          ),
        ],
      ),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: Padding(
            key: ValueKey<int>(_tabIndex),
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
            child: _buildCurrentTab(),
          ),
        ),
      ),
    );
  }

  Widget _buildCurrentTab() {
    if (_tabIndex == 0) {
      return _buildVaultTab();
    }
    if (_tabIndex == 1) {
      return _buildGenerateTab();
    }
    return _buildScanTab();
  }

  Widget _buildGenerateTab() {
    final provider = _selectedProvider;
    return SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              children: <Widget>[
                      _SectionCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              'Create a fresh proof',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              'Select a provider and generate. Your proof is encrypted and saved in Vault.',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 18),
                            DropdownButtonFormField<ProviderConfig>(
                              initialValue: provider,
                              decoration: const InputDecoration(
                                labelText: 'Provider',
                                prefixIcon: Icon(Icons.inventory_2_outlined),
                              ),
                              selectedItemBuilder: (context) {
                                return _providers
                                    .map(
                                      (item) => Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                          item.label,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    )
                                    .toList(growable: false);
                              },
                              items: _providers
                                  .map(
                                    (item) => DropdownMenuItem<ProviderConfig>(
                                      value: item,
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: <Widget>[
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              mainAxisSize: MainAxisSize.min,
                                              children: <Widget>[
                                                Text(item.label),
                                                const SizedBox(height: 2),
                                                Text(
                                                  item.description,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  )
                                  .toList(growable: false),
                              onChanged: _running
                                  ? null
                                  : (value) {
                                      setState(() {
                                        _selectedProvider = value;
                                      });
                                    },
                            ),
                            if (provider != null) ...<Widget>[
                              const SizedBox(height: 14),
                              Container(
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                padding: const EdgeInsets.all(12),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Icon(
                                      Icons.info_outline_rounded,
                                      size: 16,
                                      color: Theme.of(context).colorScheme.primary,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        provider.description,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            const SizedBox(height: 14),
                            Container(
                              width: double.infinity,
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primaryContainer.withValues(
                                  alpha: 0.35,
                                ),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.all(12),
                              child: Text(
                                'Generate starts a secure provider session and stores your proof locally.',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                            const SizedBox(height: 18),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed: _running ? null : _generateProof,
                                icon: const Icon(Icons.auto_awesome),
                                label: Text(
                                  _running ? 'Generating...' : 'Generate Proof',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_running) ...<Widget>[
                        const SizedBox(height: 14),
                        _SectionCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                'Working on your proof',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 12),
                              LinearProgressIndicator(value: _generationPercent),
                              const SizedBox(height: 10),
                              Text(
                                _generationStep.isEmpty
                                    ? 'Securing session...'
                                    : _generationStep,
                              ),
                            ],
                          ),
                        ),
                      ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVaultTab() {
    if (_proofs.isEmpty) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: _SectionCard(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    width: 66,
                    height: 66,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: const Padding(
                      padding: EdgeInsets.all(12),
                      child: Image(
                        image: AssetImage(_brandLogoAssetPath),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Your backpack is empty',
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Create your first proof to start building your secure vault.',
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () {
                      setState(() {
                        _tabIndex = 1;
                      });
                    },
                    icon: const Icon(Icons.auto_awesome_rounded),
                    label: const Text('Generate Proof'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Stack(
      children: <Widget>[
        ListView.separated(
          itemCount: _proofs.length,
          separatorBuilder: (context, index) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final proof = _proofs[index];
            final view = _proofPresentationById[proof.proofId];
            final providerLabel = _providerLabel(proof.providerId);
            final expanded = _expandedProofIds.contains(proof.proofId);
            return _SectionCard(
              child: Column(
                children: <Widget>[
                  InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => _toggleProofExpanded(proof.proofId),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  providerLabel,
                                  style: Theme.of(context).textTheme.titleMedium,
                                ),
                                if (_providerById[proof.providerId]
                                        ?.description
                                        .trim()
                                        .isNotEmpty ==
                                    true) ...<Widget>[
                                  const SizedBox(height: 2),
                                  Text(
                                    _providerById[proof.providerId]!.description,
                                    style: Theme.of(context).textTheme.bodySmall,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                                const SizedBox(height: 3),
                                Text(
                                  expanded
                                      ? 'Tap to collapse details'
                                      : 'Tap to view proof details',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          _ShareStatusPill(status: proof.shareStatus),
                          const SizedBox(width: 8),
                          Icon(
                            expanded
                                ? Icons.keyboard_arrow_up_rounded
                                : Icons.keyboard_arrow_down_rounded,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      IconButton.filledTonal(
                        tooltip: 'Upload and share',
                        onPressed: () => _uploadAndShare(proof),
                        style: IconButton.styleFrom(
                          minimumSize: const Size(34, 34),
                          padding: const EdgeInsets.all(6),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.share_rounded, size: 18),
                      ),
                      const SizedBox(width: 6),
                      IconButton.filledTonal(
                        tooltip: 'Revoke share',
                        onPressed:
                            proof.shareStatus == 'shared' &&
                                proof.shareToken != null
                            ? () => _revokeShare(proof)
                            : null,
                        style: IconButton.styleFrom(
                          minimumSize: const Size(34, 34),
                          padding: const EdgeInsets.all(6),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.block_rounded, size: 18),
                      ),
                      const SizedBox(width: 6),
                      IconButton.filledTonal(
                        tooltip: 'Delete proof',
                        onPressed: () async {
                          await _store.deleteProof(proof.proofId);
                          await _reloadProofs();
                          _showInfoSnack('Proof removed from this device.');
                        },
                        style: IconButton.styleFrom(
                          minimumSize: const Size(34, 34),
                          padding: const EdgeInsets.all(6),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.delete_outline_rounded, size: 18),
                      ),
                    ],
                  ),
                  if (expanded) ...<Widget>[
                    const SizedBox(height: 10),
                    _LabeledValueRow(
                      label: 'Created Time',
                      value: _formatDate(proof.createdAtUtc),
                    ),
                    const SizedBox(height: 7),
                    _LabeledValueRow(
                      label: 'Request Target Endpoint',
                      value: view?.targetEndpoint ?? proof.targetHost,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Revealed Data',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    if (view == null || !view.loadedSuccessfully)
                      Text(
                        'Revealed data unavailable for this proof.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      )
                    else if (view.revealedEntries.isEmpty)
                      Text(
                        'No revealed data for this proof.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      )
                    else
                      ...view.revealedEntries.map(
                        (entry) => Padding(
                          padding: const EdgeInsets.only(bottom: 7),
                          child: _LabeledValueRow(
                            label: entry.label,
                            value: entry.value,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            );
          },
        ),
        if (_loadingVaultCards)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface.withValues(
                    alpha: 0.75,
                  ),
                ),
                child: const Center(child: CircularProgressIndicator()),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildScanTab() {
    final result = _scanResult;
    return ListView(
      children: <Widget>[
        _SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Verify a shared proof',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 6),
              Text(
                'Paste a share link or token to verify the credential.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _shareTokenController,
                decoration: const InputDecoration(
                  labelText: 'Share URL or token',
                  prefixIcon: Icon(Icons.link),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _processingScan
                    ? null
                    : () {
                        final raw = _shareTokenController.text.trim();
                        if (raw.isEmpty) {
                          _showErrorSnack('Paste a token or share URL first.');
                          return;
                        }
                        final token = _extractToken(raw);
                        unawaited(_openShareInBrowserView(token));
                      },
                icon: const Icon(Icons.verified),
                label: const Text('Verify Token'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (_processingScan)
          const _SectionCard(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
        if (_scanError != null)
          _SectionCard(
            child: Text(
              _scanError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (result != null)
          _SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(
                      result.status.toLowerCase() == 'valid'
                          ? Icons.verified_rounded
                          : Icons.warning_amber_rounded,
                      color: result.status.toLowerCase() == 'valid'
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      result.status.toUpperCase(),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(result.message),
                const SizedBox(height: 12),
                Text(
                  'Revealed Claims',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                ..._extractRevealedEntries(result.scopedClaims).map(
                  (entry) => Padding(
                    padding: const EdgeInsets.only(bottom: 7),
                    child: _LabeledValueRow(
                      label: entry.label,
                      value: entry.value,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: child,
      ),
    );
  }
}

class _ShareStatusPill extends StatelessWidget {
  const _ShareStatusPill({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    late Color background;
    late Color foreground;
    if (status == 'shared') {
      background = scheme.secondaryContainer;
      foreground = scheme.onSecondaryContainer;
    } else if (status == 'revoked') {
      background = scheme.errorContainer;
      foreground = scheme.onErrorContainer;
    } else {
      background = scheme.surfaceContainerHighest;
      foreground = scheme.onSurfaceVariant;
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          status.replaceAll('_', ' '),
          style: TextStyle(
            color: foreground,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

class _LabeledValueRow extends StatelessWidget {
  const _LabeledValueRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 3),
          Text(value, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _DisplayEntry {
  const _DisplayEntry({required this.label, required this.value});

  final String label;
  final String value;
}

class _ProofPresentation {
  const _ProofPresentation({
    required this.revealedEntries,
    required this.targetEndpoint,
    required this.loadedSuccessfully,
  });

  final List<_DisplayEntry> revealedEntries;
  final String targetEndpoint;
  final bool loadedSuccessfully;
}
