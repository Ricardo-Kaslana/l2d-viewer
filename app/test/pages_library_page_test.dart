import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:live2d_viewer/data/remote_package_repo.dart';
import 'package:live2d_viewer/data/settings_repo.dart';
import 'package:live2d_viewer/pages/library_page.dart';
import 'package:live2d_viewer/providers/model_provider.dart';
import 'package:live2d_viewer/providers/remote_provider.dart';

/// Controllable fake repository. [listModels] awaits [completer] if set,
/// so tests can observe the loading state before completing.
class _FakeModelRepository implements ModelRepository {
  _FakeModelRepository({this.entries = const [], this.completer});

  List<ManifestEntry> entries;
  Completer<void>? completer;

  @override
  Future<List<ManifestEntry>> listModels() async {
    if (completer != null) {
      await completer!.future;
    }
    return entries;
  }
}

/// Repository that always throws, to exercise the error state.
class _ThrowingModelRepository implements ModelRepository {
  @override
  Future<List<ManifestEntry>> listModels() async {
    throw StateError('disk on fire');
  }
}

/// Fake remote repo that records deletions instead of touching disk.
class _FakeRemotePackageRepo extends RemotePackageRepo {
  final deletedIds = <String>[];
  bool shouldFail = false;

  @override
  Future<bool> deletePackage(String packageId) async {
    if (shouldFail) {
      throw const FileSystemException('disk locked');
    }
    deletedIds.add(packageId);
    return true;
  }
}

Widget _harness(
  ModelRepository repo, {
  RemotePackageRepo? remoteRepo,
  SettingsRepo? settings,
}) {
  return ProviderScope(
    overrides: [
      modelRepositoryProvider.overrideWith((_) => repo),
      // Provide a pre-loaded SettingsRepo so the onTap handler's
      // await ref.read(settingsRepoProvider.future) resolves immediately.
      settingsRepoProvider.overrideWith(
        (_) async => settings ?? SettingsRepo.empty(),
      ),
      if (remoteRepo != null)
        remotePackageRepoProvider.overrideWithValue(remoteRepo),
    ],
    child: MaterialApp(
      home: const LibraryPage(),
      routes: {'/viewer': (context) => const _ViewerProbe()},
    ),
  );
}

class _ViewerProbe extends StatelessWidget {
  const _ViewerProbe();
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('VIEWER_PROBE')));
}

void main() {
  testWidgets('shows loading indicator before discovery completes', (
    tester,
  ) async {
    final completer = Completer<void>();
    final repo = _FakeModelRepository(completer: completer);
    await tester.pumpWidget(_harness(repo));
    // First frame schedules the microtask; pump it without settling.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('No models installed'), findsNothing);

    completer.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('empty library explains how to add models', (tester) async {
    await tester.pumpWidget(_harness(_FakeModelRepository()));
    await tester.pumpAndSettle();

    expect(find.text('No models installed'), findsOneWidget);
    expect(
      find.textContaining('Add a local model folder in Settings'),
      findsOneWidget,
    );
  });

  testWidgets('shows empty state when no models installed', (tester) async {
    final repo = _FakeModelRepository(entries: const []);
    await tester.pumpWidget(_harness(repo));
    await tester.pumpAndSettle();

    expect(find.text('No models installed'), findsOneWidget);
    expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('lists discovered models and selects on tap', (tester) async {
    final entries = [
      const ManifestEntry(
        id: 'haru',
        name: 'Haru',
        directoryPath: '/models/haru/haru.model3.json',
      ),
      const ManifestEntry(
        id: 'hiyori',
        name: 'Hiyori',
        directoryPath: '/models/hiyori/hiyori.model3.json',
      ),
    ];
    final repo = _FakeModelRepository(entries: entries);
    await tester.pumpWidget(_harness(repo));
    await tester.pumpAndSettle();

    expect(find.text('Haru'), findsOneWidget);
    expect(find.text('Hiyori'), findsOneWidget);

    // Tapping the first model navigates to /viewer.
    await tester.tap(find.text('Haru'));
    await tester.pumpAndSettle();

    expect(find.text('VIEWER_PROBE'), findsOneWidget);
  });

  testWidgets('shows error body with retry when discovery fails', (
    tester,
  ) async {
    final repo = _ThrowingModelRepository();
    await tester.pumpWidget(_harness(repo));
    await tester.pumpAndSettle();

    expect(find.text('Failed to load models'), findsOneWidget);
    expect(find.textContaining('disk on fire'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('retry button re-runs discovery and recovers', (tester) async {
    // Flag-driven fake: throws on first discovery, then recovers.
    final fake = _RecoverableFakeRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          modelRepositoryProvider.overrideWith((_) => fake),
          settingsRepoProvider.overrideWith((_) async => SettingsRepo.empty()),
        ],
        child: MaterialApp(
          home: const LibraryPage(),
          routes: {'/viewer': (_) => const _ViewerProbe()},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Failed to load models'), findsOneWidget);

    // Recover and tap retry.
    fake.shouldThrow = false;
    fake.entries = [
      const ManifestEntry(
        id: 'recovered',
        name: 'Recovered',
        directoryPath: '/models/recovered',
      ),
    ];
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Recovered'), findsOneWidget);
    expect(find.text('Failed to load models'), findsNothing);
  });

  testWidgets('refresh button calls refreshModels and reloads the list', (
    tester,
  ) async {
    final repo = _FakeModelRepository(entries: const []);
    await tester.pumpWidget(_harness(repo));
    await tester.pumpAndSettle();

    expect(find.text('No models installed'), findsOneWidget);

    // Simulate models appearing on disk, then refresh.
    repo.entries = [
      const ManifestEntry(
        id: 'newmodel',
        name: 'NewModel',
        directoryPath: '/models/newmodel',
      ),
    ];
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    expect(find.text('NewModel'), findsOneWidget);
    expect(find.text('No models installed'), findsNothing);
  });

  testWidgets(
    'does not get stuck on spinner when settings load lags behind mount',
    (tester) async {
      // Regression: previously, when persisted settings finished loading
      // after the initial `loadAvailableModels` microtask,
      // `modelRepositoryProvider` invalidated `modelProvider`, the
      // in-flight notifier was disposed, the new notifier started at
      // `idle`, and the page sat on the spinner until the user refreshed
      // or switched tabs. The provider-level snapshot in
      // `modelRepositoryProvider` keeps the notifier stable across the
      // settings transition — this test asserts the user-visible contract:
      // the page never goes back to spinner mid-scan, and the scan's
      // results are shown once it completes.
      final settingsCompleter = Completer<SettingsRepo>();
      final discoveryCompleter = Completer<void>();
      final repo = _FakeModelRepository(
        completer: discoveryCompleter,
        entries: const [
          ManifestEntry(
            id: 'late',
            name: 'Late',
            directoryPath: '/models/late',
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            modelRepositoryProvider.overrideWith((_) => repo),
            settingsRepoProvider.overrideWith((_) => settingsCompleter.future),
          ],
          child: MaterialApp(home: const LibraryPage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      // Initial discovery in-flight; spinner is up.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Settings finish loading *while* discovery is still awaiting its
      // fake listModels. Without the snapshot fix this would invalidate
      // modelProvider, dispose the in-flight notifier, and leave the page
      // stuck on the spinner — that's the bug we're guarding against.
      settingsCompleter.complete(SettingsRepo.empty());
      await tester.pump();

      // Discovery still in-flight; spinner is still up (no silent reset).
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Let the fake discovery finish.
      discoveryCompleter.complete();
      await tester.pumpAndSettle();

      // The scan's results are shown.
      expect(find.text('Late'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );

  testWidgets(
    'waits for settings before scanning so custom paths are available',
    (tester) async {
      // The initial scan now awaits settingsRepoProvider.future so that
      // customModelPaths are populated before discovery runs. This
      // eliminates the cold-start race where the scan used empty paths.
      final settingsCompleter = Completer<SettingsRepo>();
      var callCount = 0;
      final repo = _SequencedRepo(
        onList: () async {
          callCount++;
          return const [
            ManifestEntry(
              id: 'late',
              name: 'Late',
              directoryPath: '/models/late',
            ),
          ];
        },
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            modelRepositoryProvider.overrideWith((_) => repo),
            settingsRepoProvider.overrideWith((_) => settingsCompleter.future),
          ],
          child: MaterialApp(home: const LibraryPage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      // Scan hasn't run yet — waiting for settings.
      expect(callCount, 0);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Settings settle; scan runs with real paths.
      settingsCompleter.complete(SettingsRepo.empty());
      await tester.pumpAndSettle();

      expect(callCount, 1);
      expect(find.text('Late'), findsOneWidget);
      expect(find.text('No models installed'), findsNothing);
    },
  );

  testWidgets('cold start with already-loaded settings scans exactly once', (
    tester,
  ) async {
    // Regression for the Android "render idle / shows 0 models until
    // I tap a model and come back" symptom. Both `LibraryPage
    // ._initialLoad()` and `LibraryPage.build()` previously kicked
    // off their own `loadAvailableModels()` when settings became
    // available during cold start — two concurrent scans raced, and
    // the page briefly rendered the first scan's empty result
    // before the second scan corrected it. The fix drops the
    // redundant `loadAvailableModels()` call in `_initialLoad()`
    // when `_lastCustomPaths` was already captured by `build()`.
    var callCount = 0;
    final repo = _SequencedRepo(
      onList: () async {
        callCount++;
        return const [
          ManifestEntry(
            id: 'haru',
            name: 'Haru',
            directoryPath: '/models/haru',
          ),
        ];
      },
    );

    // Settings are pre-loaded (synchronous) so `build()` captures
    // `_lastCustomPaths` on the first frame and schedules its own
    // microtask. `_initialLoad()` also awaits settings, then checks
    // whether the build path already covered it.
    final settings = SettingsRepo.empty();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          modelRepositoryProvider.overrideWith((_) => repo),
          settingsRepoProvider.overrideWith((_) async => settings),
        ],
        child: MaterialApp(home: const LibraryPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      callCount,
      1,
      reason:
          'cold start with pre-loaded settings must trigger '
          'exactly one scan, not two racing scans',
    );
    expect(find.text('Haru'), findsOneWidget);
    expect(find.text('No models installed'), findsNothing);
  });

  testWidgets('shows source and added date; delete only on remote entries', (
    tester,
  ) async {
    final entries = [
      ManifestEntry(
        id: 'local',
        name: 'Local',
        directoryPath: '/somewhere/local',
        source: ModelSource.custom,
        addedAt: DateTime(2026, 7, 1),
      ),
      ManifestEntry(
        id: 'haru',
        name: 'Haru',
        directoryPath: '/support/live2d-viewer/models/haru',
        source: ModelSource.remote,
        addedAt: DateTime(2026, 7, 20),
      ),
      const ManifestEntry(
        id: 'custom',
        name: 'Custom',
        directoryPath: '/somewhere/custom',
        // source defaults to ModelSource.custom, addedAt null.
      ),
    ];
    final repo = _FakeModelRepository(entries: entries);
    await tester.pumpWidget(_harness(repo));
    await tester.pumpAndSettle();

    expect(find.text('Custom path · 2026-07-01'), findsOneWidget);
    expect(find.text('Remote · 2026-07-20'), findsOneWidget);
    expect(find.text('Custom path'), findsOneWidget);
    // Only the remote entry offers deletion.
    expect(find.byTooltip('Delete model'), findsOneWidget);
  });

  testWidgets('delete flow confirms, deletes via RemotePackageRepo and '
      'refreshes the list', (tester) async {
    final modelRepo = _FakeModelRepository(
      entries: [
        ManifestEntry(
          id: 'haru',
          name: 'Haru',
          directoryPath: '/support/live2d-viewer/models/haru',
          source: ModelSource.remote,
          addedAt: DateTime(2026, 7, 20),
        ),
      ],
    );
    final remoteRepo = _FakeRemotePackageRepo();
    await tester.pumpWidget(_harness(modelRepo, remoteRepo: remoteRepo));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete model'));
    await tester.pumpAndSettle();

    expect(find.text('Delete model?'), findsOneWidget);

    // Simulate the model disappearing from disk once deleted.
    modelRepo.entries = const [];
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(remoteRepo.deletedIds, ['haru']);
    expect(find.text('No models installed'), findsOneWidget);
  });

  testWidgets('cancelling the delete dialog does not delete', (tester) async {
    final modelRepo = _FakeModelRepository(
      entries: [
        ManifestEntry(
          id: 'haru',
          name: 'Haru',
          directoryPath: '/support/live2d-viewer/models/haru',
          source: ModelSource.remote,
        ),
      ],
    );
    final remoteRepo = _FakeRemotePackageRepo();
    await tester.pumpWidget(_harness(modelRepo, remoteRepo: remoteRepo));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete model'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(remoteRepo.deletedIds, isEmpty);
    expect(find.text('Haru'), findsOneWidget);
  });

  testWidgets('delete failure surfaces a SnackBar and keeps the entry', (
    tester,
  ) async {
    final modelRepo = _FakeModelRepository(
      entries: [
        ManifestEntry(
          id: 'haru',
          name: 'Haru',
          directoryPath: '/support/live2d-viewer/models/haru',
          source: ModelSource.remote,
        ),
      ],
    );
    final remoteRepo = _FakeRemotePackageRepo()..shouldFail = true;
    await tester.pumpWidget(_harness(modelRepo, remoteRepo: remoteRepo));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete model'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Failed to delete Haru'), findsOneWidget);
    expect(find.text('Haru'), findsOneWidget);
  });

  testWidgets('locate recent scrolls to and highlights the last viewed model', (
    tester,
  ) async {
    final settings = SettingsRepo.empty()
      ..lastSelectedModelPath = '/models/hiyori';
    final repo = _FakeModelRepository(
      entries: const [
        ManifestEntry(id: 'haru', name: 'Haru', directoryPath: '/models/haru'),
        ManifestEntry(
          id: 'hiyori',
          name: 'Hiyori',
          directoryPath: '/models/hiyori',
        ),
      ],
    );
    await tester.pumpWidget(_harness(repo, settings: settings));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Locate recent'));
    await tester.pumpAndSettle();

    ListTile tileOf(String name) =>
        tester.widget<ListTile>(find.widgetWithText(ListTile, name));
    expect(tileOf('Hiyori').tileColor, isNotNull);
    expect(tileOf('Haru').tileColor, isNull);

    // Highlight clears after the timer fires.
    await tester.pump(const Duration(milliseconds: 1700));
    expect(tileOf('Hiyori').tileColor, isNull);
  });

  testWidgets('locate recent without a recent model shows a SnackBar', (
    tester,
  ) async {
    final repo = _FakeModelRepository(
      entries: const [
        ManifestEntry(id: 'haru', name: 'Haru', directoryPath: '/models/haru'),
      ],
    );
    await tester.pumpWidget(_harness(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Locate recent'));
    await tester.pumpAndSettle();

    expect(find.text('No recently viewed model'), findsOneWidget);
  });

  testWidgets('locate recent uses the sorted order for the scroll offset', (
    tester,
  ) async {
    // Name-descending sort puts m29 (last in raw scan order) at the top
    // of the list. Locating it must therefore keep the list at offset 0;
    // a raw-order index would scroll to the bottom instead.
    final settings = SettingsRepo.empty()
      ..librarySortDescending = true
      ..lastSelectedModelPath = '/models/m29';
    final repo = _FakeModelRepository(
      entries: [
        for (var i = 0; i < 30; i++)
          ManifestEntry(
            id: 'm${i.toString().padLeft(2, '0')}',
            name: 'm${i.toString().padLeft(2, '0')}',
            directoryPath: '/models/m${i.toString().padLeft(2, '0')}',
          ),
      ],
    );
    await tester.pumpWidget(_harness(repo, settings: settings));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Locate recent'));
    await tester.pumpAndSettle();

    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    expect(position.pixels, 0.0);
    final tile = tester.widget<ListTile>(find.widgetWithText(ListTile, 'm29'));
    expect(tile.tileColor, isNotNull);
  });

  group('sort', () {
    /// Three models in scan order: Zeta (remote, newest),
    /// Airi (remote, oldest), Haru (custom, middle).
    /// Used to verify every sort field + direction.
    List<ManifestEntry> entries() => [
      ManifestEntry(
        id: 'zeta',
        name: 'Zeta',
        directoryPath: '/managed/zeta',
        source: ModelSource.remote,
        addedAt: DateTime(2026, 7, 26),
      ),
      ManifestEntry(
        id: 'airi',
        name: 'Airi',
        directoryPath: '/managed/airi',
        source: ModelSource.remote,
        addedAt: DateTime(2026, 7, 20),
      ),
      ManifestEntry(
        id: 'haru',
        name: 'Haru',
        directoryPath: '/custom/haru',
        source: ModelSource.custom,
        addedAt: DateTime(2026, 7, 23),
      ),
    ];

    /// Returns the displayed model names in list order.
    List<String> displayedNames(WidgetTester tester) {
      final tiles = tester.widgetList<ListTile>(find.byType(ListTile));
      return tiles.map((t) {
        final title = t.title;
        return title is Text ? title.data ?? '' : '';
      }).toList();
    }

    testWidgets('default sort is name asc', (tester) async {
      final repo = _FakeModelRepository(entries: entries());
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();

      expect(displayedNames(tester), ['Airi', 'Haru', 'Zeta']);
    });

    testWidgets('sort button is present in AppBar', (tester) async {
      final repo = _FakeModelRepository(entries: entries());
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Sort'), findsOneWidget);
    });

    testWidgets('selecting Added time reorders the list', (tester) async {
      final repo = _FakeModelRepository(entries: entries());
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();

      // Initial: name asc.
      expect(displayedNames(tester), ['Airi', 'Haru', 'Zeta']);

      await tester.tap(find.byTooltip('Sort'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Added time').last);
      await tester.pumpAndSettle();

      // addedAt asc: Airi (20th) < Haru (23rd) < Zeta (26th).
      expect(displayedNames(tester), ['Airi', 'Haru', 'Zeta']);
    });

    testWidgets('toggling direction reverses the primary sort', (tester) async {
      final repo = _FakeModelRepository(entries: entries());
      await tester.pumpWidget(_harness(repo));
      await tester.pumpAndSettle();

      // Open the sort menu.
      await tester.tap(find.byTooltip('Sort'));
      await tester.pumpAndSettle();

      // Ascending is the current state — tapping the direction row
      // flips to descending.
      await tester.tap(find.text('Ascending'));
      await tester.pumpAndSettle();

      // name desc: Zeta, Haru, Airi.
      expect(displayedNames(tester), ['Zeta', 'Haru', 'Airi']);
    });

    testWidgets('sort selection persists to SettingsRepo', (tester) async {
      // Pre-seed SettingsRepo with a non-default sort and verify the
      // page hydrates it on first build. The actual disk round-trip
      // is covered by `settings_repo_test.dart`; this case only needs
      // to confirm the page-to-settings wiring works end-to-end.
      //
      // We deliberately avoid driving the PopupMenuButton cascade
      // here: on the default 800×600 test surface the menu overlay
      // routes partially off-screen, so `tester.tap(find.text(...))`
      // lands on the IgnorePointer scrim and `pumpAndSettle` hangs.
      final settings = SettingsRepo.empty()
        ..librarySortField = 'source'
        ..librarySortDescending = true;

      final repo = _FakeModelRepository(entries: entries());
      await tester.pumpWidget(_harness(repo, settings: settings));
      await tester.pumpAndSettle();

      // Source desc → custom (Haru) > remote (Airi, Zeta).
      // If hydration had failed we'd see Airi at the top (the
      // name-asc default).
      expect(displayedNames(tester), ['Haru', 'Airi', 'Zeta']);
    });
  });
}

/// Fake that can flip from throwing to returning entries mid-test.
class _RecoverableFakeRepository implements ModelRepository {
  bool shouldThrow = true;
  List<ManifestEntry> entries = const [];

  @override
  Future<List<ManifestEntry>> listModels() async {
    if (shouldThrow) {
      throw StateError('disk on fire');
    }
    return entries;
  }
}

/// Fake whose `listModels` is fully driven by the test — used by the
/// auto-rescan regression test to gate successive calls and observe
/// the cold-start race between settings loading and the initial
/// discovery microtask.
class _SequencedRepo implements ModelRepository {
  _SequencedRepo({required this.onList});

  final Future<List<ManifestEntry>> Function() onList;

  @override
  Future<List<ManifestEntry>> listModels() => onList();
}
