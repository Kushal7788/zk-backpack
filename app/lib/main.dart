import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:mobile_proof_plugin/mobile_proof_plugin.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'src/app_config.dart';
import 'src/local_store.dart';
import 'src/models.dart';
import 'src/selection_evaluator.dart';
import 'src/share_selection.dart';
import 'src/share_service_client.dart';

const _brandLogoAssetPath = 'assets/branding/backpack_logo.png';
const _sharePolicyPresets = <SharePolicyPreset>[
  SharePolicyPreset(
    id: 'one_time',
    label: 'One-time',
    description: 'Best for a single verifier. Blocks after the first view.',
    expiresInMinutes: 60,
    oneTimeView: true,
    maxViews: 1,
  ),
  SharePolicyPreset(
    id: 'interview',
    label: 'Interview',
    description: 'Valid for one day and up to 10 views.',
    expiresInMinutes: 1440,
    oneTimeView: false,
    maxViews: 10,
  ),
  SharePolicyPreset(
    id: 'demo',
    label: 'Demo',
    description: 'Valid for seven days and up to 100 views.',
    expiresInMinutes: 10080,
    oneTimeView: false,
    maxViews: 100,
  ),
];

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
  static const _shareRecipesAssetPath = 'assets/share_recipes.json';
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
  List<ShareRecipe> _shareRecipes = const <ShareRecipe>[];
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
      await _loadShareRecipes();
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

  Future<void> _loadShareRecipes() async {
    final raw = await rootBundle.loadString(_shareRecipesAssetPath);
    final decoded = jsonDecode(raw) as Map<String, Object?>;
    final recipes = (decoded['recipes'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .map(ShareRecipe.fromJson)
        .where((recipe) => recipe.id.isNotEmpty && !recipe.selection.isEmpty)
        .toList(growable: false);
    if (!mounted) {
      return;
    }
    setState(() {
      _shareRecipes = recipes;
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
      final decoded = jsonDecode(decryptedJson);
      final revealedBody = resolveRevealedBody(decoded);
      if (revealedBody.isEmpty) {
        _showErrorSnack('This proof has no revealed fields to share.');
        return;
      }
      if (!mounted) {
        return;
      }
      final ShareDraft? draft = await showModalBottomSheet<ShareDraft>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (sheetContext) {
          final recipes = _shareRecipes
              .where((recipe) => recipe.providerIds.contains(record.providerId))
              .toList(growable: false);
          return _ShareSelectionSheet(
            revealedBody: revealedBody,
            recipes: recipes,
          );
        },
      );
      if (draft == null) {
        return;
      }
      final selection = draft.selection;
      final policy = draft.policy;
      if (selection.isEmpty) {
        _showErrorSnack('Pick at least one field or predicate to share.');
        return;
      }
      _showInfoSnack('Uploading encrypted proof...');
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
        policyTemplate: 'selection',
        expiresInMinutes: policy.expiresInMinutes,
        oneTimeView: policy.oneTimeView,
        maxViews: policy.maxViews,
        selection: selection,
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
          final mediaWidth = MediaQuery.of(context).size.width;
          final double qrSide = (mediaWidth.clamp(220.0, 320.0) - 80)
              .toDouble();
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
                            width: qrSide,
                            height: qrSide,
                            child: QrImageView(
                              data: shareResult.url,
                              backgroundColor: Colors.white,
                            ),
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
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: scheme.primary,
                                decoration: TextDecoration.underline,
                              ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            policy.label,
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _sharePolicySummary(
                              policy,
                              expiresAtUtc: shareResult.expiresAtUtc,
                            ),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
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

  Future<void> _confirmAndDelete(ProofRecord record) async {
    final providerLabel = _providerLabel(record.providerId);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Delete proof?'),
          content: Text(
            'This will permanently remove the proof from "$providerLabel" on this device. '
            'Active share links will keep working until they expire or you revoke them.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton.tonal(
              style: FilledButton.styleFrom(
                foregroundColor: Theme.of(
                  dialogContext,
                ).colorScheme.onErrorContainer,
                backgroundColor: Theme.of(
                  dialogContext,
                ).colorScheme.errorContainer,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }
    try {
      await _store.deleteProof(record.proofId);
      await _reloadProofs();
      _showInfoSnack('Proof removed from this device.');
    } catch (error) {
      _showErrorSnack('Could not delete proof: $error');
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
                  value: prettifyValue(entry.value),
                ),
              )
              .toList(growable: false);
        }
      }
    }
    final candidate = _firstNonEmptyMap(<Object?>[
      decoded['revealedData'],
      decoded['revealed'],
      decoded['claims'],
      decoded['scopedClaims'],
    ]);
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
                (endpoint['host'] as String?)?.trim() ?? fallbackHost.trim();
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

  String _prettifyKey(String key) => prettifyKey(key);

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
      SnackBar(duration: const Duration(seconds: 2), content: Text(message)),
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
                                  crossAxisAlignment: CrossAxisAlignment.start,
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
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodySmall,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
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
                                  style: Theme.of(context).textTheme.bodySmall,
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
                          color: Theme.of(context).colorScheme.primaryContainer
                              .withValues(alpha: 0.35),
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
                      child: Image(image: AssetImage(_brandLogoAssetPath)),
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
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                if (_providerById[proof.providerId]?.description
                                        .trim()
                                        .isNotEmpty ==
                                    true) ...<Widget>[
                                  const SizedBox(height: 2),
                                  Text(
                                    _providerById[proof.providerId]!
                                        .description,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
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
                        onPressed: () => _confirmAndDelete(proof),
                        style: IconButton.styleFrom(
                          minimumSize: const Size(34, 34),
                          padding: const EdgeInsets.all(6),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                        ),
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
                  color: Theme.of(
                    context,
                  ).colorScheme.surface.withValues(alpha: 0.75),
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
                if (result.revealedFields.isNotEmpty) ...<Widget>[
                  Text(
                    'Revealed Fields',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  ...result.revealedFields.entries.map(
                    (entry) => Padding(
                      padding: const EdgeInsets.only(bottom: 7),
                      child: _LabeledValueRow(
                        label: prettifyKey(entry.key),
                        value: prettifyValue(entry.value),
                      ),
                    ),
                  ),
                ],
                if (result.revealedPredicates.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    'Predicates',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  ...result.revealedPredicates.map(
                    (predicate) => Padding(
                      padding: const EdgeInsets.only(bottom: 7),
                      child: _PredicateRow(predicate: predicate),
                    ),
                  ),
                ],
                if (result.revealedFields.isEmpty &&
                    result.revealedPredicates.isEmpty) ...<Widget>[
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
                if ((result.receipt['signature'] as String?)?.isNotEmpty ==
                    true) ...<Widget>[
                  const SizedBox(height: 14),
                  _ReceiptVerifyTile(
                    signature: result.receipt['signature'] as String,
                    shareClient: _shareClient,
                  ),
                ],
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
      child: Padding(padding: const EdgeInsets.all(14), child: child),
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

String _printableValue(Object? value) {
  if (value == null) return '';
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  return jsonEncode(value);
}

String prettifyKey(String key) {
  var cleaned = key.trim();
  // Repair labels that were stored by the buggy pre-fix version: the
  // camelCase split used replaceAll with `$1 $2`, which Dart treats as
  // literal text rather than a back-reference. Strip the leftover
  // `$1 $2` token so historical share records still display readably.
  cleaned = cleaned.replaceAll(RegExp(r'\$1\s*\$2'), '');
  if (cleaned.startsWith(r'$.')) cleaned = cleaned.substring(2);
  final parts = cleaned
      .split('.')
      .where((part) => part.trim().isNotEmpty)
      .toList(growable: false);
  final source = parts.isEmpty ? cleaned : parts.last;
  final words = source
      .replaceAll(RegExp(r'[^a-zA-Z0-9]+'), ' ')
      .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .split(' ')
      .where((word) => word.trim().isNotEmpty)
      .map((word) => '${word[0].toUpperCase()}${word.substring(1)}');
  return words.join(' ');
}

String prettifyValue(Object? value) {
  if (value == null) return '';
  if (value is num || value is bool) return value.toString();
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    final humanDate = _humanizeIsoDate(trimmed);
    if (humanDate != null) return humanDate;
    return trimmed;
  }
  return jsonEncode(value);
}

String? _humanizeIsoDate(String input) {
  // Match an ISO-8601 date or datetime. Accepts:
  //   2024-03-09
  //   2024-03-09T15:26:40Z
  //   2024-03-09T15:26:40.023Z
  //   2024-03-09T15:26:40.023+05:30
  final pattern = RegExp(
    r'^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2}(\.\d{1,6})?)?(Z|[+-]\d{2}:?\d{2})?)?$',
  );
  if (!pattern.hasMatch(input)) return null;
  final parsed = DateTime.tryParse(input);
  if (parsed == null) return null;
  final local = parsed.toLocal();
  const months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final dateOnly = !input.contains('T');
  final month = months[local.month - 1];
  if (dateOnly) {
    return '$month ${local.day}, ${local.year}';
  }
  final hour12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final ampm = local.hour < 12 ? 'AM' : 'PM';
  return '$month ${local.day}, ${local.year}, $hour12:$minute $ampm';
}

String _sharePolicySummary(SharePolicyPreset policy, {String? expiresAtUtc}) {
  final parts = <String>[];
  if (policy.oneTimeView) {
    parts.add('One-time link');
  }
  if (policy.maxViews != null) {
    parts.add(
      'Up to ${policy.maxViews} view${policy.maxViews == 1 ? '' : 's'}',
    );
  }
  if (expiresAtUtc != null && expiresAtUtc.trim().isNotEmpty) {
    parts.add('Expires ${_humanizeIsoDate(expiresAtUtc) ?? expiresAtUtc}');
  } else {
    parts.add('Expires in ${_formatPolicyDuration(policy.expiresInMinutes)}');
  }
  return parts.join(' · ');
}

String _formatPolicyDuration(int minutes) {
  if (minutes % 1440 == 0) {
    final days = minutes ~/ 1440;
    return '$days day${days == 1 ? '' : 's'}';
  }
  if (minutes % 60 == 0) {
    final hours = minutes ~/ 60;
    return '$hours hour${hours == 1 ? '' : 's'}';
  }
  return '$minutes minute${minutes == 1 ? '' : 's'}';
}

class ShareDraft {
  const ShareDraft({required this.selection, required this.policy});

  final ShareSelection selection;
  final SharePolicyPreset policy;
}

class _ShareSelectionSheet extends StatefulWidget {
  const _ShareSelectionSheet({
    required this.revealedBody,
    required this.recipes,
  });

  final Map<String, Object?> revealedBody;
  final List<ShareRecipe> recipes;

  @override
  State<_ShareSelectionSheet> createState() => _ShareSelectionSheetState();
}

class _ShareSelectionSheetState extends State<_ShareSelectionSheet> {
  late final List<String> _orderedPaths;
  late final Map<String, bool> _fieldSelected;
  final List<RevealPredicate> _predicates = <RevealPredicate>[];
  SharePolicyPreset _selectedPolicy = _sharePolicyPresets[1];
  String? _selectedRecipeId;
  int _predicateCounter = 0;

  @override
  void initState() {
    super.initState();
    _orderedPaths = widget.revealedBody.keys.toList(growable: false);
    _fieldSelected = <String, bool>{
      for (final path in _orderedPaths) path: false,
    };
  }

  bool get _hasDob => _orderedPaths.any(_looksLikeDob);
  bool _looksLikeDob(String path) {
    final lower = path.toLowerCase();
    return lower.contains('dob') ||
        lower.endsWith('.birth') ||
        lower.contains('birthdate') ||
        lower.contains('dateofbirth');
  }

  String? get _suggestedDobPath {
    for (final path in _orderedPaths) {
      if (_looksLikeDob(path)) return path;
    }
    return null;
  }

  void _addPredicate(RevealPredicate predicate) {
    setState(() {
      _selectedRecipeId = null;
      _predicates.add(predicate);
    });
  }

  String? _resolveRecipePath(String path) {
    final raw = path.trim();
    if (raw.isEmpty) return null;
    final candidates = <String>[
      raw,
      if (raw.startsWith(r'$.')) raw.substring(2),
      if (raw.startsWith(r'$')) raw.substring(1),
    ];
    for (final prefix in const <String>[
      'responseData.',
      'payload.response.revealedBody.',
      'revealedBody.',
      'data.',
    ]) {
      final current = candidates.toList(growable: false);
      for (final candidate in current) {
        if (candidate.startsWith(prefix)) {
          candidates.add(candidate.substring(prefix.length));
        }
      }
    }
    for (final candidate in candidates) {
      if (widget.revealedBody.containsKey(candidate)) return candidate;
      if (_fieldSelected.containsKey(candidate)) return candidate;
      if (lookupValue(widget.revealedBody, candidate) != null) return candidate;
    }
    final cleaned = raw
        .replaceFirst(RegExp(r'^\$\.?'), '')
        .split('.')
        .where((part) => part.trim().isNotEmpty)
        .toList(growable: false);
    if (cleaned.isEmpty) return null;
    final leaf = cleaned.last.toLowerCase();
    for (final existing in _orderedPaths) {
      final lower = existing.toLowerCase();
      final existingLeaf = lower.split('.').last;
      if (existingLeaf == leaf || lower.endsWith('.$leaf')) {
        return existing;
      }
    }
    return null;
  }

  ShareSelection? _normalizedRecipeSelection(ShareRecipe recipe) {
    final fields = <RevealField>[];
    for (final field in recipe.selection.fields) {
      final resolved = _resolveRecipePath(field.path);
      if (resolved == null || !_fieldSelected.containsKey(resolved)) {
        return null;
      }
      fields.add(
        RevealField(
          path: resolved,
          label: field.label.isNotEmpty ? field.label : prettifyKey(resolved),
        ),
      );
    }
    final predicates = <RevealPredicate>[];
    for (final predicate in recipe.selection.predicates) {
      final resolved = _resolveRecipePath(predicate.sourcePath);
      if (resolved == null) return null;
      final normalized = RevealPredicate(
        id: predicate.id,
        label: predicate.label,
        sourcePath: resolved,
        transform: predicate.transform,
        op: predicate.op,
        value: predicate.value,
        value2: predicate.value2,
      );
      final evaluation = evaluatePredicate(normalized, widget.revealedBody);
      if (!evaluation.evaluable) return null;
      predicates.add(normalized);
    }
    final selection = ShareSelection(fields: fields, predicates: predicates);
    return selection.isEmpty ? null : selection;
  }

  String? _recipeUnavailableReason(ShareRecipe recipe) {
    return _normalizedRecipeSelection(recipe) == null
        ? 'Unavailable for this proof payload'
        : null;
  }

  void _applyRecipe(ShareRecipe recipe) {
    final selection = _normalizedRecipeSelection(recipe);
    if (selection == null) return;
    setState(() {
      _selectedRecipeId = recipe.id;
      for (final path in _orderedPaths) {
        _fieldSelected[path] = false;
      }
      for (final field in selection.fields) {
        if (_fieldSelected.containsKey(field.path)) {
          _fieldSelected[field.path] = true;
        }
      }
      _predicates
        ..clear()
        ..addAll(selection.predicates);
      _predicateCounter = _predicates.length;
    });
  }

  Future<void> _editPredicate({RevealPredicate? existing}) async {
    final RevealPredicate? built = await showDialog<RevealPredicate>(
      context: context,
      builder: (dialogContext) {
        return _PredicateEditorDialog(
          revealedBody: widget.revealedBody,
          paths: _orderedPaths,
          initial: existing,
          nextId: 'p${++_predicateCounter}',
        );
      },
    );
    if (built == null) return;
    setState(() {
      _selectedRecipeId = null;
      if (existing != null) {
        final index = _predicates.indexWhere((p) => p.id == existing.id);
        if (index >= 0) {
          _predicates[index] = built;
        } else {
          _predicates.add(built);
        }
      } else {
        _predicates.add(built);
      }
    });
  }

  ShareSelection _currentSelection() {
    final fields = <RevealField>[];
    for (final path in _orderedPaths) {
      if (_fieldSelected[path] == true) {
        fields.add(RevealField(path: path, label: prettifyKey(path)));
      }
    }
    return ShareSelection(fields: fields, predicates: _predicates);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selection = _currentSelection();
    final preview = evaluateSelection(selection, widget.revealedBody);
    final dobPath = _suggestedDobPath;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        top: 4,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Choose what to share',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 6),
              Text(
                'Only the fields and predicates you select will be shown to anyone who scans the QR.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 14),
              if (widget.recipes.isNotEmpty) ...<Widget>[
                Text(
                  'Proof recipes',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final recipe in widget.recipes)
                      Builder(
                        builder: (context) {
                          final unavailable = _recipeUnavailableReason(recipe);
                          final available = unavailable == null;
                          return ChoiceChip(
                            label: Text(recipe.label),
                            selected: _selectedRecipeId == recipe.id,
                            onSelected: available
                                ? (_) => _applyRecipe(recipe)
                                : null,
                          );
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _selectedRecipeId == null
                      ? 'Pick a recipe to prefill safe fields and conditions. Disabled recipes need fields this proof does not contain.'
                      : widget.recipes
                            .firstWhere(
                              (recipe) => recipe.id == _selectedRecipeId,
                            )
                            .description,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 14),
              ],
              Text(
                'Share policy',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final policy in _sharePolicyPresets)
                    ChoiceChip(
                      label: Text(policy.label),
                      selected: _selectedPolicy.id == policy.id,
                      onSelected: (_) {
                        setState(() {
                          _selectedPolicy = policy;
                        });
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _selectedPolicy.description,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(
                _sharePolicySummary(_selectedPolicy),
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: scheme.primary),
              ),
              const SizedBox(height: 14),
              Text(
                'Fields to reveal',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              ..._orderedPaths.map((path) {
                final value = widget.revealedBody[path];
                final selected = _fieldSelected[path] ?? false;
                return CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: selected,
                  onChanged: (next) {
                    setState(() {
                      _selectedRecipeId = null;
                      _fieldSelected[path] = next ?? false;
                    });
                  },
                  title: Text(prettifyKey(path)),
                  subtitle: Text(
                    prettifyValue(value),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              }),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Text(
                    'Predicates',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => _editPredicate(),
                    icon: const Icon(
                      Icons.add_circle_outline_rounded,
                      size: 18,
                    ),
                    label: const Text('Add predicate'),
                  ),
                ],
              ),
              if (_hasDob)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      for (final threshold in const [18, 21, 60])
                        ActionChip(
                          label: Text('Age ≥ $threshold'),
                          onPressed: () {
                            _addPredicate(
                              RevealPredicate(
                                id: 'p${++_predicateCounter}',
                                label: 'Age over $threshold',
                                sourcePath: dobPath!,
                                transform: 'dateToYearsTillNow',
                                op: '>=',
                                value: threshold,
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ),
              if (_predicates.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    'No predicates added.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ..._predicates.map((predicate) {
                final evaluation = evaluatePredicate(
                  predicate,
                  widget.revealedBody,
                );
                final color = !evaluation.evaluable
                    ? scheme.outline
                    : evaluation.satisfied
                    ? scheme.primary
                    : scheme.error;
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    leading: Icon(
                      !evaluation.evaluable
                          ? Icons.help_outline
                          : evaluation.satisfied
                          ? Icons.check_circle_rounded
                          : Icons.cancel_rounded,
                      color: color,
                    ),
                    title: Text(predicate.label),
                    subtitle: Text(
                      evaluation.reason ?? evaluation.expression,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    trailing: Wrap(
                      spacing: 4,
                      children: <Widget>[
                        IconButton(
                          tooltip: 'Edit',
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          onPressed: () => _editPredicate(existing: predicate),
                        ),
                        IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () {
                            setState(() {
                              _selectedRecipeId = null;
                              _predicates.removeWhere(
                                (p) => p.id == predicate.id,
                              );
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                );
              }),
              const SizedBox(height: 14),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Preview',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 4),
                      if (preview.fields.isEmpty && preview.predicates.isEmpty)
                        Text(
                          'Nothing selected yet.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ...preview.fields.map(
                        (field) => Text(
                          '• ${field.label}: ${_printableValue(field.value)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      ...preview.predicates.map(
                        (predicate) => Text(
                          '• ${predicate.label}: ${predicate.satisfied ? 'true' : (predicate.evaluable ? 'false' : 'unknown')}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: selection.isEmpty
                          ? null
                          : () => Navigator.of(context).pop(
                              ShareDraft(
                                selection: selection,
                                policy: _selectedPolicy,
                              ),
                            ),
                      child: const Text('Share QR'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PredicateEditorDialog extends StatefulWidget {
  const _PredicateEditorDialog({
    required this.revealedBody,
    required this.paths,
    required this.nextId,
    this.initial,
  });

  final Map<String, Object?> revealedBody;
  final List<String> paths;
  final String nextId;
  final RevealPredicate? initial;

  @override
  State<_PredicateEditorDialog> createState() => _PredicateEditorDialogState();
}

class _PredicateEditorDialogState extends State<_PredicateEditorDialog> {
  static const _transforms = <String, String>{
    'identity': 'value as-is',
    'dateToYearsTillNow': 'date → years since',
    'parseNumber': 'parse as number',
    'length': 'character count',
    'digitsOnly': 'digits only',
  };
  static const _operators = <String>[
    '==',
    '!=',
    '>',
    '>=',
    '<',
    '<=',
    'between',
    'contains',
    'startsWith',
    'endsWith',
  ];

  late String _path;
  late String _transform;
  late String _op;
  late TextEditingController _labelController;
  late TextEditingController _valueController;
  late TextEditingController _value2Controller;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _path = initial?.sourcePath ?? widget.paths.first;
    _transform = initial?.transform ?? _autoTransform(_path);
    _op = initial?.op ?? '>=';
    _labelController = TextEditingController(
      text: initial?.label ?? _autoLabel(),
    );
    _valueController = TextEditingController(
      text: initial?.value?.toString() ?? '',
    );
    _value2Controller = TextEditingController(
      text: initial?.value2?.toString() ?? '',
    );
  }

  String _autoTransform(String path) {
    final lower = path.toLowerCase();
    if (lower.contains('dob') ||
        lower.contains('birth') ||
        lower.contains('date') ||
        lower.contains('joined') ||
        lower.contains('createdat')) {
      return 'dateToYearsTillNow';
    }
    final value = widget.revealedBody[path];
    if (value is String && double.tryParse(value) != null) return 'parseNumber';
    return 'identity';
  }

  String _autoLabel() {
    final pretty = prettifyKey(_path);
    if (_transform == 'dateToYearsTillNow') return 'Years since $pretty';
    return '$pretty ${_op == 'contains' ? 'contains value' : 'satisfies condition'}';
  }

  @override
  void dispose() {
    _labelController.dispose();
    _valueController.dispose();
    _value2Controller.dispose();
    super.dispose();
  }

  Object _parseValue(String raw) {
    final trimmed = raw.trim();
    final asNum = num.tryParse(trimmed);
    if (asNum != null) return asNum;
    if (trimmed.toLowerCase() == 'true') return true;
    if (trimmed.toLowerCase() == 'false') return false;
    return trimmed;
  }

  @override
  Widget build(BuildContext context) {
    final isBetween = _op == 'between';
    return AlertDialog(
      title: Text(widget.initial == null ? 'Add Predicate' : 'Edit Predicate'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            DropdownButtonFormField<String>(
              initialValue: _path,
              decoration: const InputDecoration(labelText: 'Source field'),
              items: widget.paths
                  .map(
                    (path) => DropdownMenuItem<String>(
                      value: path,
                      child: Text(prettifyKey(path)),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (next) {
                if (next == null) return;
                setState(() {
                  _path = next;
                  _transform = _autoTransform(next);
                  _labelController.text = _autoLabel();
                });
              },
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _transform,
              decoration: const InputDecoration(labelText: 'Transform'),
              items: _transforms.entries
                  .map(
                    (entry) => DropdownMenuItem<String>(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (next) {
                if (next == null) return;
                setState(() {
                  _transform = next;
                });
              },
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _op,
              decoration: const InputDecoration(labelText: 'Operator'),
              items: _operators
                  .map(
                    (op) =>
                        DropdownMenuItem<String>(value: op, child: Text(op)),
                  )
                  .toList(growable: false),
              onChanged: (next) {
                if (next == null) return;
                setState(() {
                  _op = next;
                });
              },
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _valueController,
              decoration: InputDecoration(
                labelText: isBetween ? 'Lower bound' : 'Compared value',
              ),
            ),
            if (isBetween) ...<Widget>[
              const SizedBox(height: 8),
              TextField(
                controller: _value2Controller,
                decoration: const InputDecoration(labelText: 'Upper bound'),
              ),
            ],
            const SizedBox(height: 8),
            TextField(
              controller: _labelController,
              decoration: const InputDecoration(labelText: 'Display label'),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final predicate = RevealPredicate(
              id: widget.initial?.id ?? widget.nextId,
              label: _labelController.text.trim().isEmpty
                  ? _autoLabel()
                  : _labelController.text.trim(),
              sourcePath: _path,
              transform: _transform,
              op: _op,
              value: _parseValue(_valueController.text),
              value2: isBetween ? _parseValue(_value2Controller.text) : null,
            );
            Navigator.of(context).pop(predicate);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _PredicateRow extends StatelessWidget {
  const _PredicateRow({required this.predicate});

  final Map<String, Object?> predicate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final satisfied = predicate['satisfied'] == true;
    final evaluable = predicate['evaluable'] != false;
    final label = (predicate['label'] as String?) ?? 'Predicate';
    final expression = (predicate['expression'] as String?) ?? '';
    final reason = (predicate['reason'] as String?) ?? '';
    final color = !evaluable
        ? scheme.outline
        : satisfied
        ? scheme.primary
        : scheme.error;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: <Widget>[
          Icon(
            !evaluable
                ? Icons.help_outline
                : satisfied
                ? Icons.check_circle_rounded
                : Icons.cancel_rounded,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(label, style: Theme.of(context).textTheme.labelMedium),
                const SizedBox(height: 3),
                Text(
                  reason.isNotEmpty ? reason : expression,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Text(
            !evaluable
                ? 'unknown'
                : satisfied
                ? 'true'
                : 'false',
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

class _ReceiptVerifyTile extends StatefulWidget {
  const _ReceiptVerifyTile({
    required this.signature,
    required this.shareClient,
  });

  final String signature;
  final ShareServiceClient shareClient;

  @override
  State<_ReceiptVerifyTile> createState() => _ReceiptVerifyTileState();
}

class _ReceiptVerifyTileState extends State<_ReceiptVerifyTile> {
  bool _busy = false;
  ReceiptVerifyResult? _result;

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final result = await widget.shareClient.verifyReceiptSignature(
        signature: widget.signature,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _result = ReceiptVerifyResult(ok: false, message: error.toString());
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final result = _result;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Receipt signature',
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              if (result != null)
                Icon(
                  result.ok
                      ? Icons.verified_user_rounded
                      : Icons.gpp_bad_rounded,
                  color: result.ok ? scheme.primary : scheme.error,
                ),
              if (result != null) const SizedBox(width: 6),
              Expanded(
                child: Text(
                  result == null
                      ? 'Tap to verify HMAC signature on the service receipt.'
                      : result.message.isNotEmpty
                      ? result.message
                      : (result.ok
                            ? 'Signature verified'
                            : 'Invalid signature'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(width: 6),
              FilledButton.tonal(
                onPressed: _busy ? null : _verify,
                child: Text(_busy ? '...' : 'Verify'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
