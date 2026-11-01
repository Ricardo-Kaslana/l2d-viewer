import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Supported frame-rate cap options for the Viewer, in the order shown in
/// the Settings UI. The trailing `0` is the "Unlimited" cap (the frame loop
/// runs as fast as it can). Persisted as [SettingsRepo.targetFps].
const List<int> kFpsCapOptions = [30, 60, 120, 0];

/// Clamp a persisted / user-supplied FPS cap to a known-good option.
/// Unknown or missing values fall back to 60 (same tolerance approach as
/// [SettingsRepo.librarySortField]).
int _sanitizeFps(int? value) => kFpsCapOptions.contains(value) ? value! : 60;

/// Settings repository backed by a JSON file in the app support directory.
///
/// Persisted fields: [packageSourceUrl], [customModelPaths], [lastSelectedModelPath].
/// Values survive app restarts. The file is written on every change via [save].
class SettingsRepo {
  SettingsRepo._();
  SettingsRepo.empty() : this._();

  /// Remote package index URL (e.g. for downloading models).
  String packageSourceUrl = '';

  /// User-specified model directories or `.model3.json` file paths.
  ///
  /// These are scanned by [LocalModelRepo] alongside the default
  /// app-support directory, allowing the user to load models from
  /// arbitrary locations on disk without copying them into the app's
  /// managed directory.
  List<String> customModelPaths = [];

  /// The last model the user selected in the Library. Persisted so the
  /// Viewer page can auto-load it on next app launch.
  String? lastSelectedModelPath;

  /// Per-model gesture state: model path -> [scaleX, scaleY, translateX, translateY].
  Map<String, List<double>> modelGestures = {};

  /// Library list sort field. Persisted as a string so adding new fields
  /// doesn't require a migration — unknown values fall back to `name`.
  /// Allowed values: `name`, `addedAt`, `source`.
  String librarySortField = 'name';

  /// Whether the Library list sort is descending. Persisted alongside
  /// [librarySortField] so the user's preferred ordering survives restarts.
  bool librarySortDescending = false;

  /// Whether to show a real-time FPS overlay in the Viewer.
  bool showFps = false;

  /// Frame-rate cap for the Viewer render loop, in frames per second.
  /// Allowed values: 30, 60, 120, or 0 (unlimited — the loop runs as fast
  /// as it can). Unknown persisted values fall back to 60. See
  /// [kFpsCapOptions].
  int targetFps = 60;

  Timer? _saveTimer;
  Future<void>? _pendingWrite;
  final List<Completer<void>> _pendingSaves = [];

  // ── Persistence ───────────────────────────────────────────────

  static Future<SettingsRepo> load() async {
    final repo = SettingsRepo._();
    final file = await _file();
    if (!await file.exists()) return repo;
    try {
      final raw = await file.readAsString();
      final j = jsonDecode(raw) as Map<String, dynamic>;
      repo.packageSourceUrl = (j['packageSourceUrl'] as String?) ?? '';
      repo.customModelPaths =
          (j['customModelPaths'] as List<dynamic>?)?.cast<String>() ?? [];
      repo.lastSelectedModelPath = j['lastSelectedModelPath'] as String?;
      final gestures = j['modelGestures'] as Map<String, dynamic>?;
      if (gestures != null) {
        repo.modelGestures = gestures.map(
          (k, v) => MapEntry(k, (v as List<dynamic>).cast<double>()),
        );
      }
      // Library sort. Unknown / missing field falls back to the default
      // ('name'); a missing descending flag falls back to false.
      switch (j['librarySortField'] as String?) {
        case 'name':
        case 'addedAt':
        case 'source':
          repo.librarySortField = j['librarySortField'] as String;
      }
      repo.librarySortDescending = j['librarySortDescending'] as bool? ?? false;
      repo.showFps = j['showFps'] as bool? ?? false;
      repo.targetFps = _sanitizeFps(j['targetFps'] as int?);
    } catch (_) {
      // Corrupt file — start fresh.
    }
    return repo;
  }

  /// Persist the current settings to disk (debounced).
  ///
  /// Rapid successive calls are coalesced: only one write happens per
  /// 300ms window, but **every** caller's future completes (or errors)
  /// when that write finishes — a coalesced call is never left pending.
  /// Use [flush] when an immediate write is required (e.g., before app
  /// exit).
  ///
  /// Errors from [_writeToDisk] are propagated through the returned
  /// future (rather than being silently swallowed by `whenComplete`).
  /// Callers that only want best-effort persistence should `try/catch`
  /// the result; callers that need to surface persistence failures
  /// (e.g. [RendererNotifier.saveCurrentGesture]) can `await` and react.
  Future<void> save() {
    _saveTimer?.cancel();
    final completer = Completer<void>();
    _pendingSaves.add(completer);
    _saveTimer = Timer(const Duration(milliseconds: 300), _commitPendingSaves);
    return completer.future;
  }

  /// Write immediately, bypassing the debounce timer. Also completes any
  /// coalesced [save] callers still waiting on the debounce window.
  ///
  /// Errors from [_writeToDisk] propagate through the returned future.
  Future<void> flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    return _commitPendingSaves();
  }

  /// Perform the actual write and settle every waiter that was coalesced
  /// into this window. Writes are serialized behind any in-flight write
  /// so two windows can never interleave partial file contents.
  Future<void> _commitPendingSaves() {
    final waiters = List<Completer<void>>.of(_pendingSaves);
    _pendingSaves.clear();
    final previous = _pendingWrite ?? Future<void>.value();
    final write = previous
        // A failure of the previous write was already reported to its own
        // waiters; it must not poison this window's write.
        .catchError((Object _) {})
        .then((_) => _writeToDisk());
    _pendingWrite = write;
    write.then(
      (_) {
        for (final c in waiters) {
          if (!c.isCompleted) c.complete();
        }
      },
      onError: (Object e, StackTrace st) {
        for (final c in waiters) {
          if (!c.isCompleted) c.completeError(e, st);
        }
      },
    );
    return write;
  }

  Future<void> _writeToDisk() async {
    final file = await _file();
    // Ensure the parent directory exists. On a fresh install the
    // `live2d-viewer/` subdirectory under the app support directory
    // has not been created yet, and `File.writeAsString` does not
    // create intermediate directories — it throws
    // `PathNotFoundException` instead. `create(recursive: true)` is
    // idempotent, so calling it on every write is safe and cheap.
    await file.parent.create(recursive: true);
    final j = <String, dynamic>{
      'packageSourceUrl': packageSourceUrl,
      'customModelPaths': customModelPaths,
    };
    if (lastSelectedModelPath != null) {
      j['lastSelectedModelPath'] = lastSelectedModelPath;
    }
    if (modelGestures.isNotEmpty) {
      j['modelGestures'] = modelGestures;
    }
    // Library sort is always written (defaults are valid values too).
    j['librarySortField'] = librarySortField;
    j['librarySortDescending'] = librarySortDescending;
    j['showFps'] = showFps;
    j['targetFps'] = targetFps;
    // Atomic write: a crash / power loss mid-write must never leave a
    // truncated settings.json (load() would then throw and drop ALL
    // settings). Write to a sibling temp file, flush, then rename into
    // place — rename within one directory is atomic on both NTFS and
    // ext4/f2fs, and Dart's rename replaces an existing file.
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(j), flush: true);
    await tmp.rename(file.path);
  }

  static Future<File> _file() async {
    final base = await getApplicationSupportDirectory();
    return File('${base.path}/live2d-viewer/settings.json');
  }
}

/// Provider for the settings repository.
///
/// Loads persisted settings asynchronously on first access. The provider
/// stores the [SettingsRepo] instance once loaded; subsequent reads via
/// [ref.watch] use the cached instance.
final settingsRepoProvider = FutureProvider<SettingsRepo>((ref) async {
  return SettingsRepo.load();
});
