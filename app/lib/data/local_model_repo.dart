import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/manifest.dart';
import '../util/log.dart';
import 'remote_package_repo.dart' show installMetaSchema;

/// Check if a directory contains a model (manifest.json or *.model3.json).
///
/// Uses async listing because `listSync()` is unreliable on Android's
/// FUSE-based scoped storage — it silently throws even when the directory
/// is readable via the async API.
Future<bool> _isModelDir(Directory dir) async {
  try {
    if (await File('${dir.path}/manifest.json').exists()) return true;
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.model3.json')) return true;
    }
    return false;
  } catch (e) {
    debugLog(
      '[model-repo] _isModelDir failed for ${pathBasename(dir.path)}: '
      '${e.runtimeType}',
    );
    return false;
  }
}

/// Find the first `.model3.json` file in a directory (async).
Future<String?> _findModel3Json(Directory dir) async {
  try {
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.model3.json')) return e.path;
    }
  } catch (e) {
    debugLog(
      '[model-repo] _findModel3Json failed for ${pathBasename(dir.path)}: '
      '${e.runtimeType}',
    );
  }
  return null;
}

/// Attempt to convert a content:// URI from file_picker into a real
/// filesystem path. On Android 11+ file_picker may return URIs like
/// content://com.android.externalstorage.documents/tree/primary%3AModels
/// which dart:io cannot open. We extract the path segment after the
/// colon (e.g. "Models") and prepend /storage/emulated/0/.
String _normalizePath(String path) {
  if (!path.startsWith('content://')) return path;
  // content://com.android.externalstorage.documents/tree/primary%3AModels
  final decoded = Uri.decodeComponent(path);
  final colonIdx = decoded.lastIndexOf(':');
  if (colonIdx != -1 && colonIdx < decoded.length - 1) {
    final relative = decoded.substring(colonIdx + 1);
    final real = '/storage/emulated/0/$relative';
    debugLog('[model-repo] content URI -> ${pathBasename(real)}');
    return real;
  }
  return path;
}

/// Normalized dedup key for a directory path: unified separators, no
/// trailing separator, case-folded on case-insensitive filesystems
/// (Windows/macOS).
String _dedupKey(String path) {
  var p = path.replaceAll('\\', '/');
  while (p.length > 1 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  if (Platform.isWindows || Platform.isMacOS) p = p.toLowerCase();
  return p;
}

class LocalModelRepo {
  /// Path of the managed models directory
  /// (`.../live2d-viewer/models`). Models installed by the remote
  /// download flow live in direct subdirectories of this path.
  Future<String> managedRootPath() async => (await _rootDir()).path;

  /// Read the `.l2dv-install.json` sidecar written at install time.
  ///
  /// Returns `null` when the file is missing (pre-sidecar installs,
  /// built-in or custom models) or unparseable. The sidecar must
  /// declare `schema == live2d-viewer.install-meta/v1`; a missing or
  /// mismatched `schema` field is treated as a foreign/corrupt file
  /// rather than silently consumed (defends against a user placing
  /// arbitrary JSON in a managed-models directory to spoof install
  /// metadata).
  Future<InstallMeta?> readInstallMeta(Directory dir) async {
    final file = File('${dir.path}/.l2dv-install.json');
    try {
      if (!await file.exists()) return null;
      final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      // Schema guard: a sidecar without our content-version marker is
      // not ours. Pre-sidecar installs (which wrote no file at all)
      // hit the `exists()` branch above and return null; a sidecar
      // here means somebody put one in place, and we want it to be
      // one *we* wrote.
      if (j['schema'] != installMetaSchema) {
        debugLog(
          '[model-repo] readInstallMeta: sidecar in ${pathBasename(dir.path)} '
          'has schema=${j['schema']}; expected $installMetaSchema; ignoring',
        );
        return null;
      }
      final rawInstalledAt = j['installedAt'] as String?;
      return InstallMeta(
        installedAt: rawInstalledAt != null
            ? DateTime.tryParse(rawInstalledAt)
            : null,
        sourceUrl: j['sourceUrl'] as String?,
        version: j['version'] as String?,
      );
    } catch (e) {
      debugLog(
        '[model-repo] readInstallMeta failed for ${pathBasename(dir.path)}: '
        '${e.runtimeType}',
      );
      return null;
    }
  }

  /// List all installed model directories.
  ///
  /// Scans the default app-support directory (`.../live2d-viewer/models/`)
  /// and any [customPaths] the user has configured. Each custom path may
  /// be:
  ///   * A `.model3.json` file path — its parent directory is added, or
  ///   * A directory that itself contains a model (manifest.json or
  ///     *.model3.json) — it is added as a single model entry, or
  ///   * A directory whose subdirectories contain models (each subdirectory
  ///     is added as a model entry).
  Future<List<Directory>> listInstalledModels({
    List<String> customPaths = const [],
  }) async {
    // Keyed by normalized path: `Directory` does not override `==`, so a
    // `Set<Directory>` would dedup by object identity and the same model
    // dir reached twice (duplicate custom path, parent scan + direct
    // path) would appear twice in the library.
    final dirs = <String, Directory>{};
    void addDir(Directory d) => dirs.putIfAbsent(_dedupKey(d.path), () => d);

    // Default managed directory.
    try {
      final root = await _rootDir();
      if (await root.exists()) {
        await for (final e in root.list()) {
          if (e is Directory) addDir(e);
        }
      }
    } catch (e) {
      debugLog('[model-repo] error scanning default dir: ${e.runtimeType}');
    }

    // Custom paths.
    for (final rawPath in customPaths) {
      final path = _normalizePath(rawPath);
      try {
        // Case 1: path points directly to a .model3.json file.
        if (path.endsWith('.model3.json')) {
          final f = File(path);
          if (await f.exists()) {
            final parent = f.parent;
            debugLog(
              '[model-repo] direct file path, adding parent: '
              '${pathBasename(parent.path)}',
            );
            addDir(parent);
          } else {
            debugLog(
              '[model-repo] .model3.json does not exist: ${pathBasename(path)}',
            );
          }
          continue;
        }

        final d = Directory(path);
        if (!await d.exists()) {
          debugLog(
            '[model-repo] custom path does not exist: ${pathBasename(path)}',
          );
          continue;
        }

        // Case 2: the directory itself is a model directory.
        if (await _isModelDir(d)) {
          debugLog('[model-repo] path is a model dir: ${pathBasename(path)}');
          addDir(d);
        } else {
          // Case 3: scan subdirectories for model entries.
          debugLog('[model-repo] scanning subdirs of: ${pathBasename(path)}');
          await for (final e in d.list()) {
            if (e is Directory && await _isModelDir(e)) {
              debugLog(
                '[model-repo]   found model subdir: '
                '${pathBasename(e.path)}',
              );
              addDir(e);
            }
          }
        }
      } catch (e) {
        debugLog(
          '[model-repo] error scanning custom path '
          '${pathBasename(path)}: ${e.runtimeType}',
        );
      }
    }

    debugLog('[model-repo] total model dirs found: ${dirs.length}');
    return dirs.values.toList();
  }

  /// Read the model metadata from a directory.
  ///
  /// Prefers `manifest.json` (custom format) but falls back to parsing
  /// the standard Cubism `.model3.json` file — no custom manifest required.
  Future<Manifest> readManifest(Directory dir) async {
    // Fast path: manifest.json exists.
    final manifestFile = File('${dir.path}/manifest.json');
    if (await manifestFile.exists()) {
      return Manifest.fromJsonString(await manifestFile.readAsString());
    }
    // Fallback: parse the standard Cubism model3.json.
    final model3 = await _findModel3Json(dir);
    if (model3 == null) {
      throw FileSystemException(
        'No manifest.json or .model3.json found',
        dir.path,
      );
    }
    return _parseModel3Json(model3, dir);
  }

  /// Parse a standard Cubism `.model3.json` file and synthesise a
  /// [Manifest] from it, so users don't need a custom `manifest.json`.
  Future<Manifest> _parseModel3Json(String path, Directory dir) async {
    final raw = await File(path).readAsString();
    final j = jsonDecode(raw) as Map<String, dynamic>;

    // Derive a human-readable id/name from the filename.
    final filename = path.split(RegExp(r'[/\\]')).last;
    final id = filename.replaceAll('.model3.json', '');
    final name = id.replaceAll(RegExp(r'[_\-]'), ' ');
    final nameCaps = name.isNotEmpty
        ? name[0].toUpperCase() + name.substring(1)
        : id;

    // Extract texture paths from the standard model3.json.
    final textures = <String>[];
    if (j['FileReferences'] is Map) {
      final fr = j['FileReferences'] as Map;
      final texList = fr['Textures'];
      if (texList is List) {
        for (final t in texList) {
          textures.add(t.toString());
        }
      }
    }

    // Extract motion groups.
    final motionGroups = <MotionGroup>[];
    if (j['FileReferences'] is Map) {
      final fr = j['FileReferences'] as Map;
      final motionMap = fr['Motions'];
      if (motionMap is Map) {
        for (final groupId in motionMap.keys) {
          final groupList = motionMap[groupId];
          if (groupList is List) {
            final files = groupList
                .map((m) => (m as Map)['File']?.toString() ?? '')
                .where((f) => f.isNotEmpty)
                .toList();
            if (files.isNotEmpty) {
              motionGroups.add(MotionGroup(id: groupId, files: files));
            }
          }
        }
      }
    }

    // Extract expressions.
    final expressions = <ExpressionEntry>[];
    if (j['FileReferences'] is Map) {
      final fr = j['FileReferences'] as Map;
      final exprList = fr['Expressions'];
      if (exprList is List) {
        for (final e in exprList) {
          final entry = e as Map;
          expressions.add(
            ExpressionEntry(
              id: (entry['Name'] ?? entry['Id'] ?? '').toString(),
              file: (entry['File'] ?? '').toString(),
            ),
          );
        }
      }
    }

    final fileRefs = (j['FileReferences'] as Map?) ?? {};
    // Cubism model3.json has no explicit default idle; pick the first
    // file of the "Idle" group (case-insensitive), else any first file.
    var defaultIdle = '';
    for (final g in motionGroups) {
      if (g.id.toLowerCase() == 'idle' && g.files.isNotEmpty) {
        defaultIdle = g.files.first;
        break;
      }
    }
    if (defaultIdle.isEmpty && motionGroups.isNotEmpty) {
      defaultIdle = motionGroups.first.files.first;
    }
    return Manifest(
      id: id,
      name: nameCaps,
      moc3: fileRefs['Moc']?.toString() ?? '',
      textures: textures,
      defaultIdle: defaultIdle,
      motionGroups: motionGroups,
      expressions: expressions,
      physics: fileRefs['Physics']?.toString(),
      hitAreas: null,
      scale: 1.0,
      offset: const [0, 0],
    );
  }

  Future<Directory> _rootDir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/live2d-viewer/models');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }
}

/// Parsed contents of a model's `.l2dv-install.json` sidecar
/// (schema `live2d-viewer.install-meta/v1`).
class InstallMeta {
  const InstallMeta({this.installedAt, this.sourceUrl, this.version});

  final DateTime? installedAt;
  final String? sourceUrl;
  final String? version;
}
