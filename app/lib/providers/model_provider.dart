import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local_model_repo.dart';
import '../data/settings_repo.dart';
import '../models/manifest.dart';

/// Status of the model selection state machine.
enum ModelSelectionStatus { idle, loading, ready, error }

/// Where a library model entry came from.
enum ModelSource {
  /// Installed from a remote package into the managed models directory.
  remote,

  /// Discovered through a user-configured custom path.
  custom,
}

/// A discoverable model entry in the local library.
class ManifestEntry {
  const ManifestEntry({
    required this.id,
    required this.name,
    required this.directoryPath,
    this.manifest,
    this.source = ModelSource.custom,
    this.addedAt,
    this.sourceUrl,
  });

  final String id;
  final String name;
  final String directoryPath;
  final Manifest? manifest;
  final ModelSource source;

  /// When the model appeared in the library: install-sidecar timestamp
  /// for remote installs, directory mtime otherwise. `null` when the
  /// filesystem stat failed.
  final DateTime? addedAt;

  /// Download URL recorded at install time (remote installs only).
  final String? sourceUrl;

  ManifestEntry copyWith({Manifest? manifest}) {
    return ManifestEntry(
      id: id,
      name: name,
      directoryPath: directoryPath,
      manifest: manifest ?? this.manifest,
      source: source,
      addedAt: addedAt,
      sourceUrl: sourceUrl,
    );
  }
}

/// Immutable snapshot of the model library selection.
class ModelState {
  const ModelState({
    this.selectedModelPath,
    this.availableModels = const [],
    this.status = ModelSelectionStatus.idle,
    this.errorMessage,
  });

  final String? selectedModelPath;
  final List<ManifestEntry> availableModels;
  final ModelSelectionStatus status;
  final String? errorMessage;

  ModelState copyWith({
    String? selectedModelPath,
    List<ManifestEntry>? availableModels,
    ModelSelectionStatus? status,
    String? errorMessage,
    bool clearError = false,
    bool clearSelection = false,
  }) {
    return ModelState(
      selectedModelPath: clearSelection
          ? null
          : (selectedModelPath ?? this.selectedModelPath),
      availableModels: availableModels ?? this.availableModels,
      status: status ?? this.status,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Abstract model repository used by the notifier.
///
/// Wraps [LocalModelRepo] so the notifier stays testable without touching
/// the filesystem.
abstract class ModelRepository {
  Future<List<ManifestEntry>> listModels();
}

/// Filesystem-backed implementation of [ModelRepository].
class LocalModelRepository implements ModelRepository {
  LocalModelRepository(this._repo, {required this.settings});
  final LocalModelRepo _repo;

  /// Settings used to resolve custom model paths.
  ///
  /// Mutable so [modelRepositoryProvider] can rebind the real persisted
  /// settings once they finish loading on cold start, without recreating
  /// this repository (and thus invalidating [modelProvider] mid-load).
  /// Consumers reach `customModelPaths` / `lastSelectedModelPath`
  /// through this field at call time, so they always see the latest
  /// values without a provider rebuild.
  SettingsRepo settings;

  @override
  Future<List<ManifestEntry>> listModels() async {
    final customPaths = List<String>.from(settings.customModelPaths);

    String? managedRoot;
    try {
      managedRoot = _normalize(await _repo.managedRootPath());
    } catch (_) {
      // Path provider unavailable (e.g. tests) — classify as custom.
    }

    final dirs = await _repo.listInstalledModels(customPaths: customPaths);
    final entries = <ManifestEntry>[];
    for (final dir in dirs) {
      Manifest? manifest;
      try {
        manifest = await _repo.readManifest(dir);
      } catch (_) {
        // Skip directories without a parseable manifest.
      }

      final normalizedDir = _normalize(dir.path);
      var source = ModelSource.custom;
      if (managedRoot != null && _parentPath(normalizedDir) == managedRoot) {
        source = ModelSource.remote;
      }

      DateTime? addedAt;
      String? sourceUrl;
      if (source == ModelSource.remote) {
        final meta = await _repo.readInstallMeta(dir);
        addedAt = meta?.installedAt;
        sourceUrl = meta?.sourceUrl;
      }
      if (addedAt == null) {
        try {
          addedAt = (await dir.stat()).modified;
        } catch (_) {
          // Stat failed — leave addedAt null.
        }
      }

      entries.add(
        ManifestEntry(
          id: manifest?.id ?? dir.path.split(RegExp(r'[/\\]')).last,
          name: manifest?.name ?? dir.path.split(RegExp(r'[/\\]')).last,
          directoryPath: dir.path,
          manifest: manifest,
          source: source,
          addedAt: addedAt,
          sourceUrl: sourceUrl,
        ),
      );
    }
    // Stable, user-friendly ordering — also keeps the "locate recent"
    // scroll offset deterministic across rescans.
    entries.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return entries;
  }

  static String _normalize(String path) {
    var p = path.replaceAll('\\', '/');
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  static String _parentPath(String normalized) {
    final idx = normalized.lastIndexOf('/');
    return idx <= 0 ? normalized : normalized.substring(0, idx);
  }
}

/// Provider for the model repository implementation.
///
/// Returns a [LocalModelRepository] bound to the persisted [SettingsRepo].
/// On cold start, persisted settings are loaded asynchronously from
/// disk; we must not let that load *invalidate* this provider, because
/// [modelProvider] (a `StateNotifierProvider`) watches us and would
/// otherwise dispose its notifier mid-load. Once that race fired, the
/// Library page would stay stuck on the spinner until a manual refresh
/// or page switch — see the regression test in
/// `test/pages_library_page_test.dart`.
///
/// Instead we keep a single [LocalModelRepository] instance for the
/// provider's lifetime. While settings are still loading the repository
/// uses a temporary [SettingsRepo.empty]. The first time settings
/// transition to data we rebind the repository's `settings` field in
/// place; subsequent reads always see the real customModelPaths because
/// [LocalModelRepository.listModels] reads them at call time. Because
/// the provider's value never changes, dependents stay stable and the
/// Library page's `ref.listen(settingsRepoProvider, …)` can re-trigger
/// a single, deterministic rescan.
final modelRepositoryProvider = Provider<ModelRepository>((ref) {
  final repo = LocalModelRepository(
    LocalModelRepo(),
    settings: SettingsRepo.empty(),
  );
  var captured = false;
  void capture(AsyncValue<SettingsRepo> next) {
    if (captured) return;
    final s = next.asData?.value;
    if (s != null) {
      repo.settings = s;
      captured = true;
    }
  }

  // Pick up the initial state in case settings are already loaded.
  capture(ref.read(settingsRepoProvider));
  // And the eventual loading → data transition on cold start.
  ref.listen<AsyncValue<SettingsRepo>>(settingsRepoProvider, (_, next) {
    capture(next);
  });
  return repo;
});

/// State notifier owning model discovery and selection.
class ModelNotifier extends StateNotifier<ModelState> {
  ModelNotifier(this._repo) : super(const ModelState());

  final ModelRepository _repo;

  /// In-flight scan future, used to coalesce concurrent
  /// [loadAvailableModels] calls into a single filesystem scan.
  Future<void>? _inFlight;

  /// Set when [refreshModels] is called while a scan is in flight; the
  /// finishing scan kicks off one follow-up scan (latest-wins).
  bool _refreshPending = false;

  /// Discover installed models and populate [availableModels].
  ///
  /// Concurrent calls are coalesced: HomePage's narrow-shell warm-up,
  /// LibraryPage's initial load and route-return refreshes can all fire
  /// close together on cold start, but only one scan runs; later calls
  /// return the same in-flight future.
  Future<void> loadAvailableModels() {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    // Synchronous status flip so callers (and the narrow-shell Home
    // status text) observe `loading` immediately after the call.
    state = state.copyWith(
      status: ModelSelectionStatus.loading,
      clearError: true,
    );
    final future = _scan();
    _inFlight = future;
    return future;
  }

  Future<void> _scan() async {
    try {
      final models = await _repo.listModels();
      if (!mounted) return;
      state = state.copyWith(
        availableModels: models,
        status: ModelSelectionStatus.ready,
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        status: ModelSelectionStatus.error,
        errorMessage: e.toString(),
      );
    } finally {
      _inFlight = null;
      if (_refreshPending) {
        _refreshPending = false;
        if (mounted) unawaited(loadAvailableModels());
      }
    }
  }

  /// Refresh the model list. Semantically identical to [loadAvailableModels]
  /// but named for the user-facing "refresh" action so callers and tests can
  /// express intent without coupling to the discovery verb.
  ///
  /// Latest-wins: if a scan is already running, this marks a follow-up
  /// scan to run once the current one finishes (so changes that landed
  /// mid-scan are picked up) instead of piling on a parallel scan.
  Future<void> refreshModels() {
    final inFlight = _inFlight;
    if (inFlight != null) {
      _refreshPending = true;
      return inFlight;
    }
    return loadAvailableModels();
  }

  /// Select a model by its directory path (or direct `.model3.json` path).
  ///
  /// If [path] points to a directory, resolves the `.model3.json` file inside
  /// it so the [ViewerPage] can pass it directly to the Rust renderer.
  /// If [path] already ends with `.model3.json` (or the directory scan finds
  /// nothing), the path is used as-is — the renderer will report a clear error
  /// if the file doesn't exist.
  Future<void> selectModel(String path) async {
    // Fast path: if the caller already passed a `.model3.json` file path,
    // use it directly without a filesystem scan (keeps the call synchronous
    // for common test patterns where the path is a fake/relative path).
    if (path.endsWith('.model3.json')) {
      state = state.copyWith(selectedModelPath: path, clearError: true);
      return;
    }
    // Directory path — scan for a `.model3.json` inside it.
    final dir = Directory(path);
    try {
      if (await dir.exists()) {
        final files = await dir
            .list()
            .where((e) => e is File && e.path.endsWith('.model3.json'))
            .toList();
        if (files.isNotEmpty) {
          state = state.copyWith(
            selectedModelPath: files.first.path,
            clearError: true,
          );
          return;
        }
      }
    } catch (_) {
      // Best effort — fall through with the original path.
    }
    state = state.copyWith(selectedModelPath: path, clearError: true);
  }

  /// Clear the current selection.
  void clearSelection() {
    state = state.copyWith(clearSelection: true, clearError: true);
  }
}

/// Provider for the model selection state.
final modelProvider = StateNotifierProvider<ModelNotifier, ModelState>((ref) {
  return ModelNotifier(ref.watch(modelRepositoryProvider));
});
