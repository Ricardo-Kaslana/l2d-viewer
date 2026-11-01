import 'dart:io' show FileSystemException;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/remote_package_repo.dart';
import '../data/settings_repo.dart';
import '../models/package_index.dart';
import '../util/log.dart';
import 'model_provider.dart';

enum RemoteStatus { idle, loading, ready, error }

/// Normalise a package source URL to a directory base so [Uri.resolve]
/// of a relative name (`index.json`, `version.url`) appends rather than
/// replaces the last path segment.
///
/// `Uri.resolve('index.json')` against `https://host/foo/bar` yields
/// `https://host/foo/index.json` (the last segment is replaced).
/// Forcing the path to end in `/` (`/foo/bar/`) makes the last segment
/// empty, so `resolve('index.json')` yields
/// `https://host/foo/bar/index.json`. This matches the convention that
/// `server/generate_index.py` writes `index.json` and the zips at the
/// server's output root.
///
/// Every resolve against the package source (index fetch, zip download,
/// sidecar `sourceUrl`) must go through this — mixing normalised and
/// raw bases makes the three resolve to different URLs.
Uri packageBaseUrl(Uri baseUrl) {
  if (baseUrl.path.isEmpty || baseUrl.path.endsWith('/')) return baseUrl;
  return baseUrl.replace(path: '${baseUrl.path}/');
}

/// A validated package source.
///
/// Users may paste either the directory containing `index.json` or the
/// `index.json` URL itself. Keep both forms unambiguous: the index URL is
/// fetched verbatim, while relative package URLs resolve against the
/// directory base.
class PackageSource {
  const PackageSource({required this.indexUrl, required this.baseUrl});

  final Uri indexUrl;
  final Uri baseUrl;
}

/// Short, path-free message for the UI. Detailed diagnostics stay in
/// debug-only type logging.
String userFacingRemoteError(Object error) {
  if (error is FileSystemException) return error.message;
  if (error is HttpException) return 'Remote request failed';
  if (error is ChecksumException) return 'Package checksum mismatch';
  if (error is UnsafeArchiveException) return 'Unsafe package archive';
  if (error is FormatException) return 'Invalid package data';
  return 'Unexpected error';
}

PackageSource? parsePackageSource(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;

  if (uri.path.toLowerCase().endsWith('.json')) {
    final slash = uri.path.lastIndexOf('/');
    final basePath = slash < 0 ? '/' : uri.path.substring(0, slash + 1);
    final base = Uri(
      scheme: uri.scheme,
      userInfo: uri.userInfo,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: basePath,
    );
    return PackageSource(indexUrl: uri.removeFragment(), baseUrl: base);
  }

  final base = packageBaseUrl(uri.removeFragment());
  return PackageSource(indexUrl: base.resolve('index.json'), baseUrl: base);
}

class RemoteState {
  const RemoteState({
    this.status = RemoteStatus.idle,
    this.packages = const [],
    this.errorMessage,
    this.installedIds = const {},
    this.downloads = const {},
  });

  final RemoteStatus status;
  final List<PackageEntry> packages;
  final String? errorMessage;
  final Set<String> installedIds;
  final Map<String, DownloadState> downloads;

  RemoteState copyWith({
    RemoteStatus? status,
    List<PackageEntry>? packages,
    String? errorMessage,
    Set<String>? installedIds,
    Map<String, DownloadState>? downloads,
    bool clearError = false,
  }) {
    return RemoteState(
      status: status ?? this.status,
      packages: packages ?? this.packages,
      // Align with `ModelState.copyWith`'s `clearError` convention:
      // passing `errorMessage: "..."` sets it; passing
      // `clearError: true` clears it; passing neither preserves the
      // current value. The previous `errorMessage: errorMessage`
      // (no `??`) silently dropped the error on every other copyWith
      // call (e.g. the optimistic `deleteInstalledById` setStatus ready
      // call), making the banner flicker off.
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      installedIds: installedIds ?? this.installedIds,
      downloads: downloads ?? this.downloads,
    );
  }
}

class DownloadState {
  const DownloadState({
    required this.packageId,
    this.progress = 0.0,
    this.extracting = false,
    this.error,
  });

  final String packageId;
  final double progress;
  final bool extracting;
  final String? error;

  bool get failed => error != null;
}

final remotePackageRepoProvider = Provider<RemotePackageRepo>((ref) {
  return RemotePackageRepo();
});

final remoteProvider = StateNotifierProvider<RemoteNotifier, RemoteState>((
  ref,
) {
  return RemoteNotifier(ref);
});

class RemoteNotifier extends StateNotifier<RemoteState> {
  RemoteNotifier(this._ref) : super(const RemoteState());

  final Ref _ref;

  RemotePackageRepo get _repo => _ref.read(remotePackageRepoProvider);

  Future<void> fetchIndex() async {
    // Entire entry path is inside try/catch: settings load failure or a
    // malformed URL must land in `status: error`, not escape as an
    // unhandled exception from a fire-and-forget call site (which would
    // leave the page spinning forever).
    state = state.copyWith(status: RemoteStatus.loading, clearError: true);
    try {
      final settings = await _ref.read(settingsRepoProvider.future);
      final urlStr = settings.packageSourceUrl;
      if (urlStr.isEmpty) {
        state = state.copyWith(
          status: RemoteStatus.error,
          errorMessage: 'No package source URL configured',
        );
        return;
      }

      final source = parsePackageSource(urlStr);
      if (source == null) {
        state = state.copyWith(
          status: RemoteStatus.error,
          errorMessage: 'Package source URL must be an http(s) URL',
        );
        return;
      }
      _warnIfNotHttps(source.baseUrl);
      final index = await _repo.fetchIndex(source.indexUrl);

      final installed = <String>{};
      for (final pkg in index.packages) {
        if (await _repo.isInstalled(pkg.id)) {
          installed.add(pkg.id);
        }
      }

      state = state.copyWith(
        status: RemoteStatus.ready,
        packages: index.packages,
        installedIds: installed,
      );
    } catch (e) {
      // Keep diagnostics path-free: the UI banner and debug log must not
      // expose the user's filesystem layout, URLs, or hash digests.
      debugLog('[remote] fetchIndex failed: ${e.runtimeType}');
      state = state.copyWith(
        status: RemoteStatus.error,
        errorMessage: 'Failed to load package index',
      );
    }
  }

  Future<void> downloadAndInstall(PackageEntry entry) async {
    _setDownload(entry.id, DownloadState(packageId: entry.id));

    // Settings load, URL parse and version selection are all inside the
    // try: a failure there must surface as a per-tile download error,
    // not an unhandled exception from a fire-and-forget call site.
    try {
      final settings = await _ref.read(settingsRepoProvider.future);
      final source = parsePackageSource(settings.packageSourceUrl);
      if (source == null) {
        throw StateError('Package source URL must be an http(s) URL');
      }
      _warnIfNotHttps(source.baseUrl);

      if (entry.versions.isEmpty) {
        throw StateError('package ${entry.id} has no versions in the index');
      }
      final version = entry.versions.firstWhere(
        (v) => v.version == entry.latest,
        orElse: () => entry.versions.first,
      );

      // Throttle progress → state writes: every HTTP chunk fires
      // onProgress (potentially hundreds of times per second), and each
      // _setDownload rebuilds the whole Remote page. Only emit when the
      // fraction advanced ≥1%, ≥100ms passed, or the download completed
      // (a 100% event must always be delivered).
      var lastEmittedFraction = -1.0;
      final sinceEmit = Stopwatch()..start();
      final zipFile = await _repo.downloadPackage(
        version,
        source.baseUrl,
        onProgress: (p) {
          final done = p.fraction >= 1.0;
          if (!done &&
              p.fraction - lastEmittedFraction < 0.01 &&
              sinceEmit.elapsedMilliseconds < 100) {
            return;
          }
          lastEmittedFraction = p.fraction;
          sinceEmit.reset();
          _setDownload(
            entry.id,
            DownloadState(packageId: entry.id, progress: p.fraction),
          );
        },
      );

      _setDownload(
        entry.id,
        DownloadState(packageId: entry.id, progress: 1.0, extracting: true),
      );

      await _repo.verifyAndExtract(
        zipFile,
        version.sha256,
        entry.id,
        sourceUrl: source.baseUrl.resolve(version.url).toString(),
        versionLabel: version.version,
      );

      final installed = Set<String>.of(state.installedIds)..add(entry.id);
      final downloads = Map<String, DownloadState>.of(state.downloads)
        ..remove(entry.id);
      state = state.copyWith(installedIds: installed, downloads: downloads);

      _ref.read(modelProvider.notifier).refreshModels();
    } catch (e) {
      debugLog('[remote] download failed for ${entry.id}: ${e.runtimeType}');
      _setDownload(
        entry.id,
        DownloadState(packageId: entry.id, error: userFacingRemoteError(e)),
      );
    }
  }

  void _setDownload(String id, DownloadState ds) {
    final downloads = Map<String, DownloadState>.of(state.downloads)..[id] = ds;
    state = state.copyWith(downloads: downloads);
  }

  /// Plain-HTTP sources deliver unauthenticated bytes; SHA-256 in the
  /// index only helps if the index itself arrived untampered. Local
  /// LAN testing over http:// is a supported workflow, so this warns
  /// instead of rejecting.
  void _warnIfNotHttps(Uri url) {
    if (url.scheme != 'https') {
      debugLog(
        '[remote] WARNING: package source ${url.host} is not HTTPS — '
        'index and downloads are susceptible to tampering in transit',
      );
    }
  }

  /// Delete a previously-installed remote package.
  ///
  /// On success the id is removed from [RemoteState.installedIds],
  /// [modelProvider] is invalidated to refresh the local Library, and
  /// any leftover [DownloadState] for that id is cleared. On failure
  /// the previous `installedIds` set is preserved (no optimistic UI
  /// update), and the failure is surfaced by setting both
  /// [RemoteState.errorMessage] **and** [RemoteState.status] to
  /// [RemoteStatus.error] — the latter is required for the Remote
  /// page to actually render the error banner; setting only
  /// `errorMessage` leaves the user staring at a tile that silently
  /// flips back to "installed" with no explanation.
  Future<void> deletePackage(PackageEntry entry) async {
    await deleteInstalledById(entry.id, displayName: entry.name);
  }

  /// Delete an installed package by its managed-directory id.
  ///
  /// Used by both [deletePackage] and the Library page (which only
  /// knows the model's directory name). Returns `null` on success, or
  /// the error message on failure — callers outside the Remote page
  /// (e.g. the Library) surface it themselves via a SnackBar.
  Future<String?> deleteInstalledById(
    String packageId, {
    String? displayName,
  }) async {
    final previousIds = state.installedIds;
    final previousDownloads = state.downloads;

    // Optimistic update — the tile flips from "installed" to "not
    // installed" immediately so the user sees action feedback. If the
    // delete throws, we restore the previous sets below.
    final optimisticIds = Set<String>.of(state.installedIds)..remove(packageId);
    final optimisticDownloads = Map<String, DownloadState>.of(state.downloads)
      ..remove(packageId);
    state = state.copyWith(
      status: RemoteStatus.ready,
      installedIds: optimisticIds,
      downloads: optimisticDownloads,
      clearError: true,
    );

    try {
      final removed = await _repo.deletePackage(packageId);
      if (!removed) {
        // The directory wasn't there to begin with (e.g. a manual
        // delete from disk while the app was running). Treat as
        // success since the user's intent — "this should not be
        // installed" — is now satisfied, and the local Library will
        // not list it after refreshModels() below.
        debugLog('[remote] deletePackage: $packageId was not installed');
      }

      // `refreshModels` is a side-effect refresh of the local Library
      // list; it has its own error surfacing in [ModelNotifier], so
      // we just log here rather than conflating its failure with the
      // primary delete action.
      try {
        await _ref.read(modelProvider.notifier).refreshModels();
      } catch (e) {
        debugLog(
          '[remote] post-delete refreshModels failed for $packageId: '
          '${e.runtimeType}',
        );
      }
      return null;
    } catch (e) {
      debugLog(
        '[remote] deletePackage failed for $packageId: ${e.runtimeType}',
      );
      // Roll back the optimistic UI update AND set status: error so
      // the Remote page actually renders the error banner. Setting
      // only `errorMessage` was a silent-failure bug — see the doc
      // comment above.
      final message =
          'Failed to delete ${displayName ?? packageId}: '
          '${userFacingRemoteError(e)}';
      state = state.copyWith(
        status: RemoteStatus.error,
        installedIds: previousIds,
        downloads: previousDownloads,
        errorMessage: message,
      );
      return message;
    }
  }
}
