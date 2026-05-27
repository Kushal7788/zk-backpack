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
const _categoryOrder = <String>[
  'Identity',
  'Professional',
  'Social',
  'General',
];
const _ink = Color(0xFF102A2D);
const _mutedInk = Color(0xFF60777A);
const _paper = Color(0xFFF9FCFB);
const _panel = Color(0xFFF4FAF9);
const _teal = Color(0xFF0E7490);
const _tealDark = Color(0xFF0B657B);
const _mint = Color(0xFFE7F5EF);
const _green = Color(0xFF0D7943);
const _line = Color(0xFFCFE2E4);
const _quietChip = Color(0xFFEAF0F0);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  runApp(const ZkBackpackApp());
}

class ZkBackpackApp extends StatelessWidget {
  const ZkBackpackApp({super.key});

  @override
  Widget build(BuildContext context) {
    final light =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF0E7490),
          brightness: Brightness.light,
        ).copyWith(
          primary: _teal,
          onPrimary: Colors.white,
          primaryContainer: _mint,
          onPrimaryContainer: _green,
          secondary: _green,
          surface: Colors.white,
          surfaceContainerLowest: _paper,
          surfaceContainerHighest: _panel,
          outline: _line,
          outlineVariant: _line,
          onSurface: _ink,
          onSurfaceVariant: _mutedInk,
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
      textTheme: ThemeData(colorScheme: scheme, useMaterial3: true).textTheme
          .apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface),
      appBarTheme: AppBarTheme(
        elevation: 0,
        centerTitle: false,
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface.withValues(alpha: 0.92),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 54),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 54),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          side: BorderSide(color: scheme.outlineVariant),
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        side: BorderSide.none,
        labelStyle: TextStyle(
          color: scheme.onSurface,
          fontWeight: FontWeight.w700,
        ),
        selectedColor: scheme.primary,
        backgroundColor: _quietChip,
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
      _showErrorSnack('Choose a source first.');
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
      _generationStep = 'Opening a secure session...';
      _statusMessage = 'Adding proof from ${provider.label}';
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
      _showInfoSnack('Proof saved in your backpack.');
      if (!mounted) {
        return;
      }
      setState(() {
        _tabIndex = 0;
        _statusMessage = 'Proof ready';
      });
    } on ProofException catch (error) {
      _showErrorSnack('[${error.code.name}] ${error.message}');
      if (mounted) {
        setState(() {
          _statusMessage = 'Could not add proof';
        });
      }
    } catch (error) {
      _showErrorSnack('Could not add proof: $error');
      if (mounted) {
        setState(() {
          _statusMessage = 'Could not add proof';
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
      _showInfoSnack('Preparing share...');
      final decryptedJson = await _store.decryptProofArtifactJson(record);
      final decoded = jsonDecode(decryptedJson);
      final revealedBody = resolveRevealedBody(decoded);
      if (revealedBody.isEmpty) {
        _showErrorSnack('This proof has no saved details to share.');
        return;
      }
      if (!mounted) {
        return;
      }
      final ShareDraft? draft = await showModalBottomSheet<ShareDraft>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: false,
        backgroundColor: Colors.transparent,
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
        _showErrorSnack('Choose at least one detail or check to share.');
        return;
      }
      _showInfoSnack('Creating private link...');
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
            elevation: 0,
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 28,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 390),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(34),
                  border: Border.all(color: _line),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: _teal.withValues(alpha: 0.14),
                      blurRadius: 42,
                      offset: const Offset(0, 18),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          const _LogoMark(size: 44),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  'Share QR ready',
                                  style: Theme.of(context).textTheme.titleLarge
                                      ?.copyWith(
                                        color: _ink,
                                        fontWeight: FontWeight.w900,
                                      ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Only selected details are released',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: _mutedInk),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Center(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: _panel,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: _line),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(8),
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
                        ),
                      ),
                      const SizedBox(height: 14),
                      InkWell(
                        onTap: () => _openExternalLink(shareResult.url),
                        borderRadius: BorderRadius.circular(18),
                        child: Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: _quietChip,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          child: Text(
                            shareResult.url,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: scheme.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: _mint,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: _line),
                        ),
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            const Icon(Icons.lock_clock_rounded, color: _green),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    policy.label,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelLarge
                                        ?.copyWith(
                                          color: _ink,
                                          fontWeight: FontWeight.w900,
                                        ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _sharePolicySummary(
                                      policy,
                                      expiresAtUtc: shareResult.expiresAtUtc,
                                    ),
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(color: _mutedInk),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Done'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
    } catch (error) {
      _showErrorSnack('Could not create share: $error');
    }
  }

  Future<void> _confirmAndDelete(ProofRecord record) async {
    final providerLabel = _providerLabel(record.providerId);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Remove proof?'),
          content: Text(
            'This will permanently remove the proof from "$providerLabel" on this device. '
            'Existing share links will keep working until they expire or you revoke them.',
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
      _showErrorSnack('Could not remove proof: $error');
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
      _showInfoSnack('Share link revoked.');
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

  String _providerCategory(String providerId) {
    final category = _providerById[providerId]?.category.trim();
    return category == null || category.isEmpty ? 'General' : category;
  }

  IconData _iconForKey(String iconKey) {
    switch (iconKey) {
      case 'identity':
        return Icons.badge_outlined;
      case 'work':
        return Icons.business_center_outlined;
      case 'money':
        return Icons.account_balance_wallet_outlined;
      case 'food':
        return Icons.receipt_long_outlined;
      case 'travel':
        return Icons.airport_shuttle_outlined;
      case 'reputation':
        return Icons.workspace_premium_outlined;
      default:
        return Icons.inventory_2_outlined;
    }
  }

  IconData _iconForCategory(String category) {
    switch (category) {
      case 'Identity':
        return Icons.badge_outlined;
      case 'Professional':
        return Icons.business_center_outlined;
      case 'Social':
        return Icons.groups_2_outlined;
    }
    for (final provider in _providers) {
      if (provider.category == category) {
        return _iconForKey(provider.iconKey);
      }
    }
    return Icons.inventory_2_outlined;
  }

  List<String> _orderedCategoryKeys(Iterable<String> categories) {
    final unique = categories
        .where((category) => category.trim().isNotEmpty)
        .toSet()
        .toList(growable: false);
    unique.sort((a, b) {
      final aIndex = _categoryOrder.indexOf(a);
      final bIndex = _categoryOrder.indexOf(b);
      if (aIndex >= 0 && bIndex >= 0) return aIndex.compareTo(bIndex);
      if (aIndex >= 0) return -1;
      if (bIndex >= 0) return 1;
      return a.compareTo(b);
    });
    return unique;
  }

  Map<String, List<ProviderConfig>> _providersByCategory() {
    final grouped = <String, List<ProviderConfig>>{};
    for (final provider in _providers) {
      grouped
          .putIfAbsent(provider.category, () => <ProviderConfig>[])
          .add(provider);
    }
    return grouped;
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
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[Color(0xFFE7F4F5), Color(0xFFF7FBFA)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  18,
                  22,
                  18,
                  bottomInset > 0 ? 8 : 18,
                ),
                child: Column(
                  children: <Widget>[
                    _BackpackHeader(
                      status: _running ? _statusMessage : 'Local first',
                    ),
                    const SizedBox(height: 24),
                    _BackpackTabs(
                      selectedIndex: _tabIndex,
                      onChanged: _onDestinationSelected,
                    ),
                    const SizedBox(height: 24),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: KeyedSubtree(
                          key: ValueKey<int>(_tabIndex),
                          child: _buildCurrentTab(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
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
    final groupedProviders = _providersByCategory();
    final categories = _orderedCategoryKeys(groupedProviders.keys);
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
                        'Generate a proof',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              color: _ink,
                              fontWeight: FontWeight.w900,
                            ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Choose a source. The proof is encrypted in your backpack and shared only when you ask.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 18),
                      for (final category in categories) ...<Widget>[
                        _CategoryHeader(
                          icon: _iconForCategory(category),
                          title: category,
                          subtitle:
                              '${groupedProviders[category]!.length} source${groupedProviders[category]!.length == 1 ? '' : 's'}',
                        ),
                        const SizedBox(height: 8),
                        ...groupedProviders[category]!.map(
                          (item) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _ProviderChoiceTile(
                              provider: item,
                              selected: provider?.providerId == item.providerId,
                              enabled: !_running,
                              icon: _iconForKey(item.iconKey),
                              onTap: () {
                                setState(() {
                                  _selectedProvider = item;
                                });
                              },
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
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
                      const SizedBox(height: 18),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _running ? null : _generateProof,
                          icon: const Icon(Icons.auto_awesome_rounded),
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
                          'Adding proof',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w900,
                                color: _ink,
                              ),
                        ),
                        const SizedBox(height: 12),
                        LinearProgressIndicator(value: _generationPercent),
                        const SizedBox(height: 10),
                        Text(
                          _generationStep.isEmpty
                              ? 'Opening a secure session...'
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
      return ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: <Widget>[
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: _SectionCard(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const _LogoMark(size: 70),
                      const SizedBox(height: 18),
                      Text(
                        'Your backpack is empty',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              fontWeight: FontWeight.w900,
                              color: _ink,
                            ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Generate your first proof and keep it encrypted locally until you choose to share.',
                        style: Theme.of(context).textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
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
          ),
        ],
      );
    }
    return Stack(
      children: <Widget>[
        ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: <Widget>[
            for (final proof in _proofs) ...<Widget>[
              _ProofVaultCard(
                record: proof,
                providerLabel: _providerLabel(proof.providerId),
                providerDescription:
                    _providerById[proof.providerId]?.description ?? '',
                category: _providerCategory(proof.providerId),
                view: _proofPresentationById[proof.proofId],
                expanded: _expandedProofIds.contains(proof.proofId),
                createdLabel: _formatDate(proof.createdAtUtc),
                onToggle: () => _toggleProofExpanded(proof.proofId),
                onShare: () => _uploadAndShare(proof),
                onRevoke:
                    proof.shareStatus == 'shared' && proof.shareToken != null
                    ? () => _revokeShare(proof)
                    : null,
                onDelete: () => _confirmAndDelete(proof),
              ),
              const SizedBox(height: 18),
            ],
          ],
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
                'Scan a shared proof',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: _ink,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Paste a share link or token to verify the proof and review only the released details.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _shareTokenController,
                decoration: const InputDecoration(
                  labelText: 'Share link or token',
                  prefixIcon: Icon(Icons.link_rounded),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _processingScan
                    ? null
                    : () {
                        final raw = _shareTokenController.text.trim();
                        if (raw.isEmpty) {
                          _showErrorSnack('Paste a share link first.');
                          return;
                        }
                        final token = _extractToken(raw);
                        unawaited(_openShareInBrowserView(token));
                      },
                icon: const Icon(Icons.verified),
                label: const Text('Verify Proof'),
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
        if (result != null) _buildVerifyResultCard(result),
      ],
    );
  }

  Widget _buildVerifyResultCard(ShareViewResponse result) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = result.status.toLowerCase();
    final isValid = status == 'valid';
    final statusColor = isValid ? scheme.primary : scheme.error;
    final verifiedAt = _certificateVerifiedAt(result);
    final fallbackEntries =
        result.revealedFields.isEmpty && result.revealedPredicates.isEmpty
        ? _extractRevealedEntries(result.scopedClaims)
        : const <_DisplayEntry>[];

    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: isValid
                  ? scheme.primaryContainer.withValues(alpha: 0.28)
                  : scheme.errorContainer.withValues(alpha: 0.42),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: statusColor.withValues(alpha: 0.28)),
            ),
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  isValid
                      ? Icons.workspace_premium_rounded
                      : Icons.report_problem_rounded,
                  color: statusColor,
                  size: 28,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Proof certificate',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _shareViewStatusLabel(result.status),
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: statusColor,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _certificateMessage(result),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: _panel,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: _line),
            ),
            padding: const EdgeInsets.all(14),
            child: Column(
              children: <Widget>[
                _CertificateDetailRow(
                  icon: Icons.public_rounded,
                  label: 'Data source',
                  value: _certificateSource(result),
                ),
                const Divider(height: 18, color: _line),
                _CertificateDetailRow(
                  icon: Icons.schedule_rounded,
                  label: 'Verified at',
                  value: verifiedAt.timestamp,
                  subtitle: verifiedAt.relative,
                ),
                const Divider(height: 18, color: _line),
                _CertificateDetailRow(
                  icon: Icons.lock_open_rounded,
                  label: 'Access',
                  value: _certificateAccessSummary(result),
                ),
                const Divider(height: 18, color: _line),
                _CertificateDetailRow(
                  icon: Icons.visibility_rounded,
                  label: 'Shows',
                  value: _certificateRevealSummary(result, fallbackEntries),
                ),
              ],
            ),
          ),
          if (result.revealedFields.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            Text('Shared details', style: theme.textTheme.titleSmall),
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
            const SizedBox(height: 8),
            Text('Private checks', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            ...result.revealedPredicates.map(
              (predicate) => Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: _PredicateRow(predicate: predicate),
              ),
            ),
          ],
          if (fallbackEntries.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            Text('Shared details', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            ...fallbackEntries.map(
              (entry) => Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: _LabeledValueRow(label: entry.label, value: entry.value),
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
    );
  }

  String _certificateMessage(ShareViewResponse result) {
    final message = result.message.trim();
    if (result.status.toLowerCase() == 'valid' &&
        message.toLowerCase() == 'verified credential') {
      return 'This proof is valid and the details below are safe to review.';
    }
    if (message.isNotEmpty) return message;
    return result.status.toLowerCase() == 'valid'
        ? 'This proof is valid.'
        : 'This proof could not be verified.';
  }

  String _certificateSource(ShareViewResponse result) {
    final verifierResult = result.receipt['verifierResult'];
    final verification = result.verification;
    final candidates = <Object?>[
      result.share['sourceDomain'],
      result.share['dataSource'],
      result.share['domain'],
      result.share['targetHost'],
      result.receipt['sourceDomain'],
      result.receipt['dataSource'],
      result.receipt['domain'],
      if (verifierResult is Map<String, Object?>) verifierResult['targetHost'],
      if (verifierResult is Map<String, Object?>) verifierResult['host'],
      if (verifierResult is Map<String, Object?>)
        verifierResult['sourceDomain'],
      if (verifierResult is Map<String, Object?>) verifierResult['dataSource'],
      verification['sourceDomain'],
      verification['dataSource'],
      verification['domain'],
      verification['targetHost'],
      verification['host'],
    ];
    for (final value in candidates) {
      final source = _providerDomainValue(value);
      if (source.isNotEmpty) return source;
    }
    return 'Not shown';
  }

  _CertificateTimestamp _certificateVerifiedAt(ShareViewResponse result) {
    final checkedAt = _firstStringValue(<Object?>[
      result.receipt['verifiedAt'],
      result.verification['verifiedAt'],
      result.share['verifiedAt'],
    ]);
    if (checkedAt.isEmpty) {
      return const _CertificateTimestamp(timestamp: 'Just now', relative: '');
    }
    final parsed = DateTime.tryParse(checkedAt);
    if (parsed == null) {
      return _CertificateTimestamp(timestamp: checkedAt, relative: '');
    }
    return _CertificateTimestamp(
      timestamp: _humanizeIsoDate(checkedAt) ?? checkedAt,
      relative: _relativeAgeLabel(parsed),
    );
  }

  String _certificateAccessSummary(ShareViewResponse result) {
    final share = result.share;
    final parts = <String>[];
    final maxViews = _intValue(share['maxViews']);
    final views = _intValue(share['views']);
    final expiresAtUtc = _stringValue(share['expiresAtUtc']);

    if (share['oneTimeView'] == true) {
      parts.add('One-time link');
    } else if (maxViews != null) {
      final viewed = views == null ? '' : '$views/';
      parts.add('$viewed$maxViews views');
    }
    if (expiresAtUtc.isNotEmpty) {
      parts.add('Until ${_humanizeIsoDate(expiresAtUtc) ?? expiresAtUtc}');
    }
    if (parts.isNotEmpty) return parts.join(' · ');
    return result.status.toLowerCase() == 'valid' ? 'Open now' : 'Closed';
  }

  String _certificateRevealSummary(
    ShareViewResponse result,
    List<_DisplayEntry> fallbackEntries,
  ) {
    final fieldCount = result.revealedFields.isNotEmpty
        ? result.revealedFields.length
        : fallbackEntries.length;
    final checkCount = result.revealedPredicates.length;
    final parts = <String>[];
    if (fieldCount > 0) {
      parts.add('$fieldCount detail${fieldCount == 1 ? '' : 's'}');
    }
    if (checkCount > 0) {
      parts.add('$checkCount check${checkCount == 1 ? '' : 's'}');
    }
    return parts.isEmpty ? 'No details shown' : parts.join(' + ');
  }

  String _stringValue(Object? value) {
    if (value == null) return '';
    if (value is String) return value.trim();
    return value.toString().trim();
  }

  String _firstStringValue(List<Object?> values) {
    for (final value in values) {
      final text = _stringValue(value);
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  String _relativeAgeLabel(DateTime dateTime) {
    final local = dateTime.toLocal();
    var difference = DateTime.now().difference(local);
    if (difference.isNegative) {
      difference = Duration.zero;
    }
    final minutes = difference.inMinutes;
    if (minutes <= 0) return 'Just now';
    if (minutes <= 60) {
      return '$minutes min${minutes == 1 ? '' : 's'} ago';
    }
    final hours = difference.inHours;
    if (hours < 24) {
      return '$hours hour${hours == 1 ? '' : 's'} ago';
    }
    final days = difference.inDays;
    return '$days day${days == 1 ? '' : 's'} ago';
  }

  String _providerDomainValue(Object? value) {
    var source = _stringValue(value);
    if (source.isEmpty) return '';
    source = source.replaceFirst(
      RegExp(
        r'^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+',
        caseSensitive: false,
      ),
      '',
    );
    final uri = Uri.tryParse(
      source.contains('://') ? source : 'https://$source',
    );
    if (uri != null && uri.host.trim().isNotEmpty) {
      return uri.host.trim().toLowerCase();
    }
    return source
        .split('/')
        .first
        .split('?')
        .first
        .split('#')
        .first
        .toLowerCase();
  }

  int? _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

class _BackpackHeader extends StatelessWidget {
  const _BackpackHeader({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        const _LogoMark(size: 58),
        const SizedBox(width: 18),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'ZK Backpack',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.headlineSmall?.copyWith(
                  color: _ink,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Private proof vault',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleMedium?.copyWith(
                  color: _mutedInk,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 160),
          child: _SoftPill(
            label: status,
            foreground: _tealDark,
            background: Colors.white.withValues(alpha: 0.45),
            border: _line,
            horizontalPadding: 18,
            verticalPadding: 11,
          ),
        ),
      ],
    );
  }
}

class _LogoMark extends StatelessWidget {
  const _LogoMark({this.size = 44});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _teal,
        borderRadius: BorderRadius.circular(size * 0.28),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: _teal.withValues(alpha: 0.14),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        'ZK',
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w900,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _BackpackTabs extends StatelessWidget {
  const _BackpackTabs({required this.selectedIndex, required this.onChanged});

  final int selectedIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final labels = const <String>['Vault', 'Generate', 'Scan'];
    return Container(
      height: 86,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(31),
        border: Border.all(color: _line, width: 1.5),
      ),
      padding: const EdgeInsets.all(7),
      child: Row(
        children: <Widget>[
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: i == labels.length - 1 ? 0 : 6),
                child: _BackpackTabButton(
                  label: labels[i],
                  selected: i == selectedIndex,
                  onTap: () => onChanged(i),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _BackpackTabButton extends StatelessWidget {
  const _BackpackTabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        height: double.infinity,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? _teal : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: selected ? Colors.white : _mutedInk,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}

class _SoftPill extends StatelessWidget {
  const _SoftPill({
    required this.label,
    this.foreground = _green,
    this.background = _mint,
    this.border,
    this.horizontalPadding = 14,
    this.verticalPadding = 8,
  });

  final String label;
  final Color foreground;
  final Color background;
  final Color? border;
  final double horizontalPadding;
  final double verticalPadding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: border == null ? null : Border.all(color: border!),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: verticalPadding,
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: _line.withValues(alpha: 0.82)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: _teal.withValues(alpha: 0.07),
            blurRadius: 34,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: Padding(padding: const EdgeInsets.all(22), child: child),
    );
  }
}

class _CertificateTimestamp {
  const _CertificateTimestamp({
    required this.timestamp,
    required this.relative,
  });

  final String timestamp;
  final String relative;
}

class _CertificateDetailRow extends StatelessWidget {
  const _CertificateDetailRow({
    required this.icon,
    required this.label,
    required this.value,
    this.subtitle = '',
  });

  final IconData icon;
  final String label;
  final String value;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: _line),
          ),
          child: Icon(icon, size: 19, color: _teal),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelMedium?.copyWith(
                  color: _mutedInk,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleSmall?.copyWith(
                  color: _ink,
                  fontWeight: FontWeight.w900,
                ),
              ),
              if (subtitle.isNotEmpty) ...<Widget>[
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(
                    color: _tealDark,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _CategoryHeader extends StatelessWidget {
  const _CategoryHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: _mint,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, size: 18, color: _teal),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: _mutedInk,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.1,
            ),
          ),
        ),
        Text(
          subtitle,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _ProviderChoiceTile extends StatelessWidget {
  const _ProviderChoiceTile({
    required this.provider,
    required this.selected,
    required this.enabled,
    required this.icon,
    required this.onTap,
  });

  final ProviderConfig provider;
  final bool selected;
  final bool enabled;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final borderColor = selected ? _teal : _line;
    final background = selected ? _mint : Colors.white.withValues(alpha: 0.72);
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(22),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: double.infinity,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: borderColor),
        ),
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: selected ? _teal : _quietChip,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Icon(
                icon,
                size: 22,
                color: selected ? Colors.white : _mutedInk,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    provider.label,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: _ink,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    provider.description,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: _mutedInk),
                  ),
                ],
              ),
            ),
            if (selected) ...<Widget>[
              const SizedBox(width: 8),
              Icon(Icons.check_circle_rounded, size: 22, color: _green),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProofVaultCard extends StatelessWidget {
  const _ProofVaultCard({
    required this.record,
    required this.providerLabel,
    required this.providerDescription,
    required this.category,
    required this.view,
    required this.expanded,
    required this.createdLabel,
    required this.onToggle,
    required this.onShare,
    required this.onRevoke,
    required this.onDelete,
  });

  final ProofRecord record;
  final String providerLabel;
  final String providerDescription;
  final String category;
  final _ProofPresentation? view;
  final bool expanded;
  final String createdLabel;
  final VoidCallback onToggle;
  final VoidCallback onShare;
  final VoidCallback? onRevoke;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final title = _proofCardTitle(providerLabel, category);
    final endpoint = _friendlyEndpoint(
      view?.targetEndpoint ?? record.targetHost,
    );
    final previewEntries =
        view?.revealedEntries.take(2).toList(growable: false) ??
        const <_DisplayEntry>[];
    final hasShared =
        record.shareStatus == 'shared' || record.shareToken != null;
    final hasUploaded =
        record.cloudProofId != null ||
        hasShared ||
        record.shareStatus == 'uploaded';
    final revoked = record.shareStatus == 'revoked';
    final compactActionStyle = FilledButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 10),
    );

    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(22),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          category.toUpperCase(),
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: _mutedInk,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 1.1,
                              ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          title,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                color: _ink,
                                fontWeight: FontWeight.w900,
                                height: 1.08,
                              ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          endpoint.isEmpty ? providerDescription : endpoint,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: _mutedInk,
                                fontWeight: FontWeight.w500,
                              ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      const _SoftPill(
                        label: 'Proof',
                        foreground: _tealDark,
                        background: Colors.white,
                        border: _line,
                        horizontalPadding: 16,
                        verticalPadding: 9,
                      ),
                      const SizedBox(height: 8),
                      IconButton(
                        tooltip: 'Delete proof',
                        onPressed: onDelete,
                        style: IconButton.styleFrom(
                          backgroundColor: _quietChip,
                          foregroundColor: _mutedInk,
                        ),
                        icon: const Icon(Icons.delete_outline_rounded),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: <Widget>[
              const _SoftPill(label: 'Local'),
              _SoftPill(
                label: 'Uploaded',
                foreground: hasUploaded ? _green : _mutedInk,
                background: hasUploaded ? _mint : _quietChip,
              ),
              _SoftPill(
                label: revoked ? 'Revoked' : 'Shared',
                foreground: hasShared && !revoked ? _green : _mutedInk,
                background: hasShared && !revoked ? _mint : _quietChip,
              ),
              _SoftPill(
                label: revoked ? 'Closed' : 'Revocable',
                foreground: revoked
                    ? Theme.of(context).colorScheme.error
                    : _mutedInk,
                background: revoked
                    ? Theme.of(context).colorScheme.errorContainer
                    : _quietChip,
              ),
            ],
          ),
          const SizedBox(height: 22),
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: _panel,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: _line),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: previewEntries.isEmpty
                ? _VaultPreviewRow(
                    label: 'Proof',
                    value: view?.loadedSuccessfully == false
                        ? 'Saved details unavailable'
                        : 'Encrypted locally',
                  )
                : Column(
                    children: <Widget>[
                      for (
                        var i = 0;
                        i < previewEntries.length;
                        i++
                      ) ...<Widget>[
                        _VaultPreviewRow(
                          label: previewEntries[i].label,
                          value: previewEntries[i].value,
                        ),
                        if (i != previewEntries.length - 1)
                          const Divider(height: 18, color: _line),
                      ],
                    ],
                  ),
          ),
          const SizedBox(height: 22),
          LayoutBuilder(
            builder: (context, constraints) {
              Widget shareButton() {
                return FilledButton.icon(
                  onPressed: onShare,
                  icon: const Icon(Icons.qr_code_2_rounded),
                  label: const Text('Share QR'),
                  style: compactActionStyle,
                );
              }

              Widget revokeButton() {
                return FilledButton.tonalIcon(
                  onPressed: onRevoke,
                  icon: const Icon(Icons.block_rounded),
                  label: Text(revoked ? 'Revoked' : 'Revoke'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _quietChip,
                    foregroundColor: _ink,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                );
              }

              if (constraints.maxWidth < 300) {
                return Column(
                  children: <Widget>[
                    SizedBox(width: double.infinity, child: shareButton()),
                    const SizedBox(height: 10),
                    SizedBox(width: double.infinity, child: revokeButton()),
                  ],
                );
              }

              return Row(
                children: <Widget>[
                  Expanded(child: shareButton()),
                  const SizedBox(width: 12),
                  Expanded(child: revokeButton()),
                ],
              );
            },
          ),
          if (expanded) ...<Widget>[
            const SizedBox(height: 18),
            _ProofLifecycleTimeline(record: record),
            const SizedBox(height: 10),
            _LabeledValueRow(label: 'Created', value: createdLabel),
            const SizedBox(height: 8),
            _LabeledValueRow(label: 'Source', value: endpoint),
            if (view != null && view!.revealedEntries.length > 2) ...<Widget>[
              const SizedBox(height: 8),
              for (final entry in view!.revealedEntries.skip(2))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _LabeledValueRow(
                    label: entry.label,
                    value: entry.value,
                  ),
                ),
            ],
          ],
        ],
      ),
    );
  }

  static String _proofCardTitle(String providerLabel, String category) {
    final lower = providerLabel.toLowerCase();
    if (lower.contains('aadhaar')) return 'Aadhaar age proof';
    if (lower.contains('gusto')) return 'Employment proof';
    if (lower.contains('deel')) return 'Income proof';
    if (lower.contains('kaggle')) return 'Reputation proof';
    if (lower.contains('uber')) return 'Travel activity proof';
    if (lower.contains('swiggy')) return 'Food order proof';
    return category == 'General' ? providerLabel : '$providerLabel proof';
  }

  static String _friendlyEndpoint(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed == 'Not available') return '';
    final withoutMethod = trimmed.replaceFirst(
      RegExp(
        r'^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+',
        caseSensitive: false,
      ),
      '',
    );
    return withoutMethod.replaceFirst(RegExp(r'^https?://'), '');
  }
}

class _VaultPreviewRow extends StatelessWidget {
  const _VaultPreviewRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: _mutedInk,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 16),
        Flexible(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: _ink,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ],
    );
  }
}

class _ProofLifecycleTimeline extends StatelessWidget {
  const _ProofLifecycleTimeline({required this.record});

  final ProofRecord record;

  @override
  Widget build(BuildContext context) {
    final status = record.shareStatus;
    final uploaded =
        record.cloudProofId != null ||
        status == 'uploaded' ||
        status == 'shared' ||
        status == 'revoked';
    final shared =
        record.shareToken != null || status == 'shared' || status == 'revoked';
    final revoked = status == 'revoked';
    final steps = <_LifecycleStepData>[
      _LifecycleStepData(
        label: 'Saved',
        icon: Icons.lock_outline_rounded,
        completed: true,
        current: status == 'local_only',
      ),
      _LifecycleStepData(
        label: 'Ready',
        icon: Icons.cloud_done_outlined,
        completed: uploaded,
        current: status == 'uploaded',
      ),
      _LifecycleStepData(
        label: 'Shared',
        icon: Icons.ios_share_rounded,
        completed: shared,
        current: status == 'shared',
      ),
      _LifecycleStepData(
        label: 'Revoked',
        icon: Icons.block_rounded,
        completed: revoked,
        current: revoked,
        destructive: true,
      ),
    ];
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      child: Row(
        children: <Widget>[
          for (var i = 0; i < steps.length; i++) ...<Widget>[
            Expanded(child: _LifecycleStep(data: steps[i])),
            if (i != steps.length - 1)
              Container(
                width: 12,
                height: 1,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
          ],
        ],
      ),
    );
  }
}

class _LifecycleStepData {
  const _LifecycleStepData({
    required this.label,
    required this.icon,
    required this.completed,
    required this.current,
    this.destructive = false,
  });

  final String label;
  final IconData icon;
  final bool completed;
  final bool current;
  final bool destructive;
}

class _LifecycleStep extends StatelessWidget {
  const _LifecycleStep({required this.data});

  final _LifecycleStepData data;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final activeColor = data.destructive ? scheme.error : scheme.primary;
    final color = data.completed ? activeColor : scheme.outline;
    final background = data.current
        ? activeColor.withValues(alpha: 0.14)
        : Colors.transparent;
    return Container(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(data.icon, size: 16, color: color),
          const SizedBox(height: 3),
          Text(
            data.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: data.current ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
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

String _shareViewStatusLabel(String status) {
  switch (status.toLowerCase()) {
    case 'valid':
      return 'Valid';
    case 'revoked':
      return 'Revoked';
    case 'expired':
      return 'Expired';
    case 'consumed':
      return 'Already used';
    case 'max_views_reached':
      return 'View limit reached';
    default:
      return 'Not valid';
  }
}

class ShareDraft {
  const ShareDraft({required this.selection, required this.policy});

  final ShareSelection selection;
  final SharePolicyPreset policy;
}

String _shareSelectionCountLabel(ShareSelection selection) {
  final parts = <String>[];
  if (selection.fields.isNotEmpty) {
    parts.add(
      '${selection.fields.length} field${selection.fields.length == 1 ? '' : 's'}',
    );
  }
  if (selection.predicates.isNotEmpty) {
    parts.add(
      '${selection.predicates.length} check${selection.predicates.length == 1 ? '' : 's'}',
    );
  }
  return parts.isEmpty ? 'Nothing selected' : parts.join(' + ');
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
  bool _customizeOpen = false;
  int _predicateCounter = 0;

  @override
  void initState() {
    super.initState();
    _orderedPaths = widget.revealedBody.keys.toList(growable: false);
    _fieldSelected = <String, bool>{
      for (final path in _orderedPaths) path: false,
    };
    _customizeOpen = widget.recipes.isEmpty;
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
      _customizeOpen = true;
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

  ShareRecipe? get _selectedRecipe {
    final selectedId = _selectedRecipeId;
    if (selectedId == null) return null;
    for (final recipe in widget.recipes) {
      if (recipe.id == selectedId) return recipe;
    }
    return null;
  }

  void _clearSelection() {
    setState(() {
      _selectedRecipeId = null;
      for (final path in _orderedPaths) {
        _fieldSelected[path] = false;
      }
      _predicates.clear();
      _customizeOpen = widget.recipes.isEmpty;
    });
  }

  String _recipeSummary(ShareRecipe recipe) {
    final selection = _normalizedRecipeSelection(recipe);
    if (selection == null) return 'Unavailable';
    return _shareSelectionCountLabel(selection);
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
      _customizeOpen = true;
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
    final selection = _currentSelection();
    final preview = evaluateSelection(selection, widget.revealedBody);
    final dobPath = _suggestedDobPath;
    final selectedRecipe = _selectedRecipe;
    return Padding(
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 12,
        top: 12,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(34),
          border: Border.all(color: _line),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: _teal.withValues(alpha: 0.15),
              blurRadius: 42,
              offset: const Offset(0, -12),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 14, 22, 22),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.86,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Center(
                  child: Container(
                    width: 48,
                    height: 5,
                    decoration: BoxDecoration(
                      color: _line,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Share proof',
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(
                                  color: _ink,
                                  fontWeight: FontWeight.w900,
                                  height: 1.05,
                                ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            selectedRecipe?.label ?? 'Private by default',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(color: _mutedInk),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    _SoftPill(
                      label: _shareSelectionCountLabel(selection),
                      foreground: selection.isEmpty ? _mutedInk : _green,
                      background: selection.isEmpty ? _quietChip : _mint,
                      horizontalPadding: 12,
                      verticalPadding: 7,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        if (widget.recipes.isNotEmpty) ...<Widget>[
                          Row(
                            children: <Widget>[
                              Text(
                                'Preset',
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(
                                      color: _ink,
                                      fontWeight: FontWeight.w900,
                                    ),
                              ),
                              const Spacer(),
                              TextButton.icon(
                                onPressed: selection.isEmpty
                                    ? null
                                    : _clearSelection,
                                icon: const Icon(
                                  Icons.refresh_rounded,
                                  size: 17,
                                ),
                                label: const Text('Clear'),
                                style: TextButton.styleFrom(
                                  foregroundColor: _mutedInk,
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 92,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: widget.recipes.length,
                              separatorBuilder: (context, index) =>
                                  const SizedBox(width: 10),
                              itemBuilder: (context, index) {
                                final recipe = widget.recipes[index];
                                final unavailable = _recipeUnavailableReason(
                                  recipe,
                                );
                                final available = unavailable == null;
                                return _ShareRecipeCard(
                                  label: recipe.label,
                                  summary: _recipeSummary(recipe),
                                  selected: _selectedRecipeId == recipe.id,
                                  enabled: available,
                                  onTap: available
                                      ? () => _applyRecipe(recipe)
                                      : null,
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 14),
                        ],
                        _SharePreviewPanel(
                          preview: preview,
                          policy: _selectedPolicy,
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'Link access',
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                color: _ink,
                                fontWeight: FontWeight.w900,
                              ),
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
                        const SizedBox(height: 6),
                        Text(
                          _sharePolicySummary(_selectedPolicy),
                          style: Theme.of(
                            context,
                          ).textTheme.labelSmall?.copyWith(color: _tealDark),
                        ),
                        const SizedBox(height: 14),
                        _ShareCustomizePanel(
                          expanded: _customizeOpen,
                          selectedFieldCount: selection.fields.length,
                          checkCount: selection.predicates.length,
                          onExpansionChanged: (next) {
                            setState(() {
                              _customizeOpen = next;
                            });
                          },
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                'Fields',
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(
                                      color: _ink,
                                      fontWeight: FontWeight.w900,
                                    ),
                              ),
                              const SizedBox(height: 8),
                              ..._orderedPaths.map((path) {
                                final value = widget.revealedBody[path];
                                final selected = _fieldSelected[path] ?? false;
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: _ShareSelectableRow(
                                    selected: selected,
                                    title: prettifyKey(path),
                                    subtitle: prettifyValue(value),
                                    tag: 'field',
                                    onTap: () {
                                      HapticFeedback.selectionClick();
                                      setState(() {
                                        _selectedRecipeId = null;
                                        _fieldSelected[path] = !selected;
                                      });
                                    },
                                  ),
                                );
                              }),
                              const SizedBox(height: 8),
                              Row(
                                children: <Widget>[
                                  Text(
                                    'Checks',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(
                                          color: _ink,
                                          fontWeight: FontWeight.w900,
                                        ),
                                  ),
                                  const Spacer(),
                                  TextButton.icon(
                                    onPressed: () => _editPredicate(),
                                    icon: const Icon(
                                      Icons.add_circle_outline_rounded,
                                      size: 18,
                                    ),
                                    label: const Text('Add check'),
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
                                      for (final threshold in const [
                                        18,
                                        21,
                                        60,
                                      ])
                                        ActionChip(
                                          label: Text('Age $threshold+'),
                                          onPressed: () {
                                            _addPredicate(
                                              RevealPredicate(
                                                id: 'p${++_predicateCounter}',
                                                label: 'Age $threshold+',
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
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 6,
                                  ),
                                  child: Text(
                                    'No checks added.',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(color: _mutedInk),
                                  ),
                                ),
                              ..._predicates.map((predicate) {
                                final evaluation = evaluatePredicate(
                                  predicate,
                                  widget.revealedBody,
                                );
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: _SharePredicateDraftCard(
                                    predicate: predicate,
                                    evaluation: evaluation,
                                    onEdit: () =>
                                        _editPredicate(existing: predicate),
                                    onRemove: () {
                                      setState(() {
                                        _selectedRecipeId = null;
                                        _predicates.removeWhere(
                                          (p) => p.id == predicate.id,
                                        );
                                      });
                                    },
                                  ),
                                );
                              }),
                            ],
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
                        child: const Text('Create Link'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ShareRecipeCard extends StatelessWidget {
  const _ShareRecipeCard({
    required this.label,
    required this.summary,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final String summary;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = enabled ? _ink : _mutedInk.withValues(alpha: 0.68);
    return Opacity(
      opacity: enabled ? 1 : 0.58,
      child: SizedBox(
        width: 156,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(20),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              decoration: BoxDecoration(
                color: selected ? _mint : _panel,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: selected ? _teal : _line),
              ),
              padding: const EdgeInsets.all(13),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: foreground,
                                fontWeight: FontWeight.w900,
                              ),
                        ),
                      ),
                      if (selected) ...<Widget>[
                        const SizedBox(width: 6),
                        const Icon(
                          Icons.check_circle_rounded,
                          color: _green,
                          size: 18,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: _mutedInk),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShareCustomizePanel extends StatelessWidget {
  const _ShareCustomizePanel({
    required this.expanded,
    required this.selectedFieldCount,
    required this.checkCount,
    required this.onExpansionChanged,
    required this.child,
  });

  final bool expanded;
  final int selectedFieldCount;
  final int checkCount;
  final ValueChanged<bool> onExpansionChanged;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final summary = selectedFieldCount == 0 && checkCount == 0
        ? 'Manual fields and checks'
        : <String>[
            if (selectedFieldCount > 0)
              '$selectedFieldCount field${selectedFieldCount == 1 ? '' : 's'}',
            if (checkCount > 0)
              '$checkCount check${checkCount == 1 ? '' : 's'}',
          ].join(' + ');
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _line),
      ),
      child: Column(
        children: <Widget>[
          InkWell(
            onTap: () => onExpansionChanged(!expanded),
            borderRadius: BorderRadius.circular(22),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: _mint,
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: const Icon(
                      Icons.tune_rounded,
                      color: _teal,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Customize',
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                color: _ink,
                                fontWeight: FontWeight.w900,
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(color: _mutedInk),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: _mutedInk,
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...<Widget>[
            const Divider(height: 1, color: _line),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
              child: child,
            ),
          ],
        ],
      ),
    );
  }
}

class _ShareSelectableRow extends StatelessWidget {
  const _ShareSelectableRow({
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.tag,
    required this.onTap,
  });

  final bool selected;
  final String title;
  final String subtitle;
  final String tag;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            color: selected ? _panel : Colors.white.withValues(alpha: 0.76),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: selected ? _line : _quietChip),
          ),
          padding: const EdgeInsets.all(14),
          child: Row(
            children: <Widget>[
              AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: selected ? _teal : _quietChip,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(
                  selected ? Icons.check_rounded : Icons.add_rounded,
                  color: selected ? Colors.white : _mutedInk,
                  size: 26,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: _ink,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle.isEmpty ? 'Selected detail' : subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: _mutedInk),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              _SoftPill(
                label: tag,
                foreground: selected ? _green : _mutedInk,
                background: selected ? _mint : _quietChip,
                horizontalPadding: 12,
                verticalPadding: 7,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SharePredicateDraftCard extends StatelessWidget {
  const _SharePredicateDraftCard({
    required this.predicate,
    required this.evaluation,
    required this.onEdit,
    required this.onRemove,
  });

  final RevealPredicate predicate;
  final PredicateResult evaluation;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = !evaluation.evaluable
        ? _mutedInk
        : evaluation.satisfied
        ? _green
        : scheme.error;
    final icon = !evaluation.evaluable
        ? Icons.help_outline_rounded
        : evaluation.satisfied
        ? Icons.check_rounded
        : Icons.close_rounded;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(icon, color: color, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        predicate.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: _ink,
                              fontWeight: FontWeight.w900,
                            ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const _SoftPill(
                      label: 'predicate',
                      foreground: _green,
                      background: _mint,
                      horizontalPadding: 12,
                      verticalPadding: 7,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  evaluation.reason ?? evaluation.expression,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: _mutedInk),
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    TextButton.icon(
                      onPressed: onEdit,
                      icon: const Icon(Icons.edit_outlined, size: 17),
                      label: const Text('Edit'),
                      style: TextButton.styleFrom(
                        foregroundColor: _tealDark,
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: onRemove,
                      icon: const Icon(Icons.close_rounded, size: 17),
                      label: const Text('Remove'),
                      style: TextButton.styleFrom(
                        foregroundColor: _mutedInk,
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SharePreviewPanel extends StatelessWidget {
  const _SharePreviewPanel({required this.preview, required this.policy});

  final SelectionEvaluation preview;
  final SharePolicyPreset policy;

  @override
  Widget build(BuildContext context) {
    final empty = preview.fields.isEmpty && preview.predicates.isEmpty;
    final rows = <_DisplayEntry>[
      for (final field in preview.fields)
        _DisplayEntry(label: field.label, value: _printableValue(field.value)),
      for (final predicate in preview.predicates)
        _DisplayEntry(
          label: predicate.label,
          value: predicate.satisfied
              ? 'true'
              : (predicate.evaluable ? 'false' : 'unknown'),
        ),
    ];
    final visibleRows = rows.take(5).toList(growable: false);
    final remaining = rows.length - visibleRows.length;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _line),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.visibility_outlined,
                  color: _teal,
                  size: 19,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Shared preview',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: _ink,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              _SoftPill(
                label: policy.label,
                foreground: _tealDark,
                background: Colors.white,
                border: _line,
                horizontalPadding: 12,
                verticalPadding: 7,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (empty)
            Text(
              'Nothing selected.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: _mutedInk),
            ),
          for (var i = 0; i < visibleRows.length; i++) ...<Widget>[
            _VaultPreviewRow(
              label: visibleRows[i].label,
              value: visibleRows[i].value,
            ),
            if (i != visibleRows.length - 1)
              const Divider(height: 18, color: _line),
          ],
          if (remaining > 0) ...<Widget>[
            const Divider(height: 18, color: _line),
            Text(
              '+$remaining more selected',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: _tealDark,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ],
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
      title: Text(widget.initial == null ? 'Add Check' : 'Edit Check'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            DropdownButtonFormField<String>(
              initialValue: _path,
              decoration: const InputDecoration(labelText: 'Source detail'),
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
              decoration: const InputDecoration(labelText: 'How to read it'),
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
              decoration: const InputDecoration(labelText: 'Rule'),
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
                labelText: isBetween ? 'Minimum value' : 'Required value',
              ),
            ),
            if (isBetween) ...<Widget>[
              const SizedBox(height: 8),
              TextField(
                controller: _value2Controller,
                decoration: const InputDecoration(labelText: 'Maximum value'),
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
    final label = (predicate['label'] as String?) ?? 'Check';
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
          Text('Receipt', style: Theme.of(context).textTheme.labelMedium),
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
                      ? 'Check that this receipt was issued by the service.'
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
                child: Text(_busy ? '...' : 'Check'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
