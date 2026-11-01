import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../data/library_sort.dart';
import '../data/settings_repo.dart';
import '../providers/model_provider.dart';
import '../providers/remote_provider.dart';

/// Model selection page.
///
/// Discovers installed models from [modelProvider] on first build and lists
/// them. Tapping a model selects it in the shared state and navigates to the
/// Viewer. The AppBar refresh button re-runs discovery via
/// [ModelNotifier.refreshModels].
///
/// When [embedded] is `true` (Windows wide shell) the page renders without
/// its own Scaffold/AppBar so it fills the shell's content pane; on phones
/// it is pushed as a standalone route with the full Scaffold.
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> with RouteAware {
  /// Fixed row height for the model list. Required so the "locate
  /// recent" action can compute an exact scroll offset even for rows
  /// the lazy ListView has not built yet.
  static const double _itemExtent = 72;

  List<String>? _lastCustomPaths;

  /// True once either `_initialLoad` or `build()` has scheduled the
  /// initial library scan. `_lastCustomPaths != null` cannot serve as
  /// this guard: `_initialLoad` sets it right before checking, so on a
  /// warm remount (settings future already resolved) both paths fired
  /// and two scans raced.
  bool _initialScanScheduled = false;
  final ScrollController _scrollController = ScrollController();
  String? _highlightedPath;
  Timer? _highlightTimer;

  /// Current Library sort specification. Initialized lazily from the
  /// persisted [SettingsRepo] on the first build where settings have
  /// resolved, and mutated in place whenever the user picks a new
  /// field or direction.
  LibrarySort _sort = LibrarySort.defaultSort;

  /// Whether [_sort] has been hydrated from [SettingsRepo] yet.
  /// Prevents re-applying the persisted sort on every rebuild and
  /// clobbering an in-flight user selection.
  bool _sortHydrated = false;

  @override
  void initState() {
    super.initState();
    _initialLoad();
  }

  Future<void> _initialLoad() async {
    // Wait for settings to be ready so customModelPaths are available.
    SettingsRepo? settings;
    try {
      settings = await ref.read(settingsRepoProvider.future);
    } catch (_) {
      // Settings failed to load — scan with defaults.
    }
    if (!mounted) return;
    if (settings != null && _lastCustomPaths == null) {
      _lastCustomPaths = List.of(settings.customModelPaths);
    }
    // Only kick off the initial scan if the build path hasn't already
    // scheduled one (see `_initialScanScheduled`). Without this guard
    // a warm remount saw two concurrent scans racing — and on Android
    // this manifested as the Library page showing the wrong model
    // count until the user tapped a model and came back (which
    // triggered `didPopNext` → `refreshModels`).
    //
    // `refreshModels` (not `loadAvailableModels`): a HomePage warm-up
    // scan may still be in flight *with empty settings*. Coalescing
    // into it would drop the customModelPaths we just awaited;
    // latest-wins schedules a follow-up scan with the real settings.
    if (settings != null && !_initialScanScheduled) {
      _initialScanScheduled = true;
      ref.read(modelProvider.notifier).refreshModels();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _highlightTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didPopNext() {
    // User returned from a pushed route (e.g. Settings on Android).
    // Refresh models in case custom paths changed.
    ref.read(modelProvider.notifier).refreshModels();
  }

  @override
  Widget build(BuildContext context) {
    // Detect customModelPaths changes (user added/removed a path in
    // Settings and navigated back). SettingsRepo is mutable and held by
    // a FutureProvider that never re-emits, so ref.listen won't fire;
    // we compare directly on each build. Use ref.watch so we rebuild
    // when settings transition from loading to data (cold-start race).
    final settingsAsync = ref.watch(settingsRepoProvider);
    final settings = settingsAsync.valueOrNull;
    if (settings != null) {
      // Hydrate the Library sort from persisted settings exactly once.
      // Doing this every build would clobber the user's in-flight sort
      // selection whenever a unrelated provider rebuild triggered a
      // repaint.
      if (!_sortHydrated) {
        _sort = LibrarySort(
          field:
              LibrarySortField.fromPersistedKey(settings.librarySortField) ??
              LibrarySortField.name,
          direction: settings.librarySortDescending
              ? LibrarySortDirection.desc
              : LibrarySortDirection.asc,
        );
        _sortHydrated = true;
      }
      final currentPaths = settings.customModelPaths;
      if (_lastCustomPaths == null) {
        // Settings just became available. The initial scan in initState
        // likely ran with SettingsRepo.empty() (no custom paths), so
        // always rescan to pick up the user's configured paths.
        // `refreshModels` (latest-wins) so this cannot coalesce into a
        // still-running empty-settings scan and lose the custom paths.
        _lastCustomPaths = List.of(currentPaths);
        _initialScanScheduled = true;
        Future.microtask(
          () => ref.read(modelProvider.notifier).refreshModels(),
        );
      } else if (!_listEquals(_lastCustomPaths!, currentPaths)) {
        _lastCustomPaths = List.of(currentPaths);
        Future.microtask(
          () => ref.read(modelProvider.notifier).refreshModels(),
        );
      }
    }

    final model = ref.watch(modelProvider);
    final theme = Theme.of(context);

    if (widget.embedded) {
      return _embeddedBody(context, model, theme);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          _sortButton(),
          IconButton(
            icon: const Icon(Icons.my_location),
            tooltip: 'Locate recent',
            onPressed: _locateRecent,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () => ref.read(modelProvider.notifier).refreshModels(),
          ),
        ],
      ),
      body: _body(context, model, theme),
    );
  }

  Widget _embeddedBody(
    BuildContext context,
    ModelState model,
    ThemeData theme,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _embeddedHeader(context, theme),
        Expanded(child: _body(context, model, theme)),
      ],
    );
  }

  Widget _embeddedHeader(BuildContext context, ThemeData theme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Text('Library', style: theme.textTheme.titleMedium),
          const Spacer(),
          _sortButton(),
          IconButton(
            icon: const Icon(Icons.my_location),
            tooltip: 'Locate recent',
            onPressed: _locateRecent,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () => ref.read(modelProvider.notifier).refreshModels(),
          ),
        ],
      ),
    );
  }

  /// Sort button + dropdown menu. Rendered in both the standalone
  /// AppBar and the embedded header so the affordance stays in the
  /// same place across layouts.
  Widget _sortButton() {
    return PopupMenuButton<_SortMenuAction>(
      tooltip: 'Sort',
      icon: const Icon(Icons.sort),
      onSelected: (action) {
        if (action == _SortMenuAction.toggleDirection) {
          _onSortChanged(
            _sort.copyWith(
              direction: _sort.direction == LibrarySortDirection.asc
                  ? LibrarySortDirection.desc
                  : LibrarySortDirection.asc,
            ),
          );
        } else {
          _onSortChanged(_sort.copyWith(field: action.field));
        }
      },
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          value: _SortMenuAction(LibrarySortField.name),
          checked: _sort.field == LibrarySortField.name,
          child: const Text('Name'),
        ),
        CheckedPopupMenuItem(
          value: _SortMenuAction(LibrarySortField.addedAt),
          checked: _sort.field == LibrarySortField.addedAt,
          child: const Text('Added time'),
        ),
        CheckedPopupMenuItem(
          value: _SortMenuAction(LibrarySortField.source),
          checked: _sort.field == LibrarySortField.source,
          child: const Text('Source'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _SortMenuAction.toggleDirection,
          child: Row(
            children: [
              Icon(
                _sort.isDescending ? Icons.arrow_downward : Icons.arrow_upward,
                size: 20,
              ),
              const SizedBox(width: 12),
              Text(_sort.isDescending ? 'Descending' : 'Ascending'),
            ],
          ),
        ),
      ],
    );
  }

  /// Apply a new sort selection: update in-memory state, persist to
  /// [SettingsRepo], and rebuild so the list reorders.
  void _onSortChanged(LibrarySort next) {
    if (next == _sort) return;
    setState(() => _sort = next);
    final settings = ref.read(settingsRepoProvider).valueOrNull;
    if (settings == null) return;
    settings.librarySortField = next.field.persistedKey;
    settings.librarySortDescending = next.isDescending;
    settings.save().catchError((Object e, StackTrace st) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to save sort: $e')));
    });
  }

  /// Return [entries] ordered by the current [_sort].
  ///
  /// This is a pure pass-through to [sortLibraryEntries]; keeping it as
  /// a method lets the page (and future tests) swap in a different
  /// ordering without touching the call sites.
  List<ManifestEntry> _sortedModels(List<ManifestEntry> entries) =>
      sortLibraryEntries(entries, _sort);

  Widget _body(BuildContext context, ModelState model, ThemeData theme) {
    switch (model.status) {
      case ModelSelectionStatus.loading:
      case ModelSelectionStatus.idle:
        return const Center(child: CircularProgressIndicator());
      case ModelSelectionStatus.error:
        return _ErrorBody(
          message: model.errorMessage ?? 'unknown error',
          onRetry: () => ref.read(modelProvider.notifier).refreshModels(),
        );
      case ModelSelectionStatus.ready:
        if (model.availableModels.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.inbox_outlined,
                  size: 64,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(height: 16),
                Text('No models installed', style: theme.textTheme.bodyLarge),
                const SizedBox(height: 8),
                Text(
                  'Add a local model folder in Settings or install one from '
                  'a remote catalog.',
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          );
        }
        final sorted = _sortedModels(model.availableModels);
        return ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: sorted.length,
          itemExtent: _itemExtent,
          itemBuilder: (context, index) {
            final entry = sorted[index];
            // `selectedModelPath` may be either the model directory
            // (from `entry.directoryPath`) or the resolved
            // `.model3.json` file inside it (after `selectModel` walks
            // the directory). Compare on `directoryPath` prefix so both
            // representations highlight the row.
            final selected =
                model.selectedModelPath != null &&
                (model.selectedModelPath == entry.directoryPath ||
                    model.selectedModelPath!.startsWith(
                      '${entry.directoryPath}/',
                    ) ||
                    model.selectedModelPath!.startsWith(
                      '${entry.directoryPath}\\',
                    ));
            final highlighted = _highlightedPath == entry.directoryPath;
            return ListTile(
              tileColor: highlighted
                  ? theme.colorScheme.primaryContainer
                  : null,
              leading: Icon(
                selected ? Icons.check_circle : Icons.person_outline,
                color: selected ? theme.colorScheme.primary : null,
              ),
              title: Text(entry.name, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                _entrySubtitle(entry),
                overflow: TextOverflow.ellipsis,
              ),
              trailing: entry.source == ModelSource.remote
                  ? IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Delete model',
                      onPressed: () => _confirmAndDelete(entry),
                    )
                  : const Icon(Icons.chevron_right),
              onTap: () async {
                await ref
                    .read(modelProvider.notifier)
                    .selectModel(entry.directoryPath);
                // Persist the selection so it survives app restart. Fire
                // and forget: a slow or hung disk write (e.g. antivirus
                // scanning the support directory, or a missing path
                // provider channel in widget tests) must not block the
                // navigation to the Viewer.
                try {
                  final settingsAsync = ref.read(settingsRepoProvider);
                  final settings = settingsAsync.valueOrNull;
                  if (settings != null) {
                    settings.lastSelectedModelPath = entry.directoryPath;
                    unawaited(settings.save().catchError((Object _) {}));
                  }
                } catch (_) {
                  // Best-effort — persistence failure is non-fatal.
                }
                if (!context.mounted) return;
                Navigator.of(context).pushNamed('/viewer');
              },
            );
          },
        );
    }
  }

  String _entrySubtitle(ManifestEntry entry) {
    final source = switch (entry.source) {
      ModelSource.remote => 'Remote',
      ModelSource.custom => 'Custom path',
    };
    final added = entry.addedAt;
    if (added == null) return source;
    final local = added.toLocal();
    final date =
        '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
    return '$source · $date';
  }

  /// Scroll to the last-viewed model (from settings) and briefly
  /// highlight it.
  void _locateRecent() {
    final lastPath = ref
        .read(settingsRepoProvider)
        .valueOrNull
        ?.lastSelectedModelPath;
    // Index against the sorted list — the ListView renders _sortedModels,
    // so a raw-order index would scroll to the wrong row under any
    // non-default sort.
    final models = _sortedModels(ref.read(modelProvider).availableModels);
    final index = lastPath == null
        ? -1
        : models.indexWhere((e) => e.directoryPath == lastPath);
    if (index < 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No recently viewed model')));
      return;
    }
    if (_scrollController.hasClients) {
      final target = (index * _itemExtent).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
    _highlightTimer?.cancel();
    setState(() => _highlightedPath = models[index].directoryPath);
    _highlightTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _highlightedPath = null);
    });
  }

  /// Ask for confirmation, then delete a remote-installed model.
  ///
  /// Deletion goes through [RemoteNotifier.deleteInstalledById] →
  /// [RemotePackageRepo.deletePackage] (the five-check discipline), so
  /// only direct children of the managed models directory can ever be
  /// removed. The package id is the managed directory's name.
  Future<void> _confirmAndDelete(ManifestEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete model?'),
        content: Text(
          '"${entry.name}" will be removed from this device. '
          'You can reinstall it from the Remote page later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final dirName = entry.directoryPath.split(RegExp(r'[/\\]')).last;
    // selectModel resolves a directory to the .model3.json inside it,
    // so the selected path may be either the directory itself or a
    // file within it.
    final selectedPath = ref.read(modelProvider).selectedModelPath;
    final wasSelected =
        selectedPath != null &&
        (selectedPath == entry.directoryPath ||
            selectedPath.startsWith('${entry.directoryPath}/') ||
            selectedPath.startsWith('${entry.directoryPath}\\'));
    final error = await ref
        .read(remoteProvider.notifier)
        .deleteInstalledById(dirName, displayName: entry.name);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    if (wasSelected) {
      ref.read(modelProvider.notifier).clearSelection();
      // Also drop the persisted auto-load path so the Viewer doesn't try
      // to load the deleted model on next launch. Best effort.
      final settings = ref.read(settingsRepoProvider).valueOrNull;
      if (settings != null && settings.lastSelectedModelPath != null) {
        settings.lastSelectedModelPath = null;
        try {
          await settings.save();
        } catch (_) {
          // Persistence failure is non-fatal here; the stale path is
          // handled by the Viewer's load-error path.
        }
      }
    }
  }
}

/// Centered error body with a retry action. Rendered as the Scaffold body
/// (not a MaterialBanner) so it occupies the full content area and stays
/// testable without relying on [ScaffoldMessenger].
class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 64, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text('Failed to load models', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Menu actions for the Library sort popup.
///
/// Each `LibrarySortField` value selects a new sort field; the sentinel
/// [toggleDirection] flips asc ↔ desc without changing the field.
class _SortMenuAction {
  const _SortMenuAction(this.field);
  const _SortMenuAction._toggle() : field = null;

  static const _SortMenuAction toggleDirection = _SortMenuAction._toggle();

  final LibrarySortField? field;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is _SortMenuAction && other.field == field;
  }

  @override
  int get hashCode => field?.hashCode ?? 0;
}
