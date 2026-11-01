import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:live2d_viewer/data/settings_repo.dart';
import 'package:live2d_viewer/pages/home_page.dart';
import 'package:live2d_viewer/providers/model_provider.dart';

/// Regression guard for the Android-only "Library stuck on
/// `ModelSelectionStatus.idle`" symptom.
///
/// Forces a narrow viewport (matching an Android phone cold start) and
/// asserts that mounting `HomePage` itself triggers a library scan, so
/// the narrow-shell status text under the "选择模型" button ("Loading
/// library…" / "Library ready (N models)") reflects reality without
/// the user having to tap into Library first.
///
/// Before this guard existed, the narrow shell rendered the central
/// status text as "Library idle" until the user tapped "选择模型" and
/// came back — `_initialLoad()` was owned only by `LibraryPage`, but
/// `HomePage` is the only thing the user sees on cold start.
class _TraceRepo implements ModelRepository {
  _TraceRepo({required this.onList});

  Future<List<ManifestEntry>> Function() onList;

  int calls = 0;
  bool sawScanned = false;

  @override
  Future<List<ManifestEntry>> listModels() async {
    calls++;
    sawScanned = true;
    return onList();
  }
}

Widget _harness({
  required _TraceRepo repo,
  required SettingsRepo settings,
  Completer<SettingsRepo>? settingsCompleter,
}) {
  return UncontrolledProviderScope(
    container: ProviderContainer(
      overrides: [
        modelRepositoryProvider.overrideWith((_) => repo),
        settingsRepoProvider.overrideWith(
          (_) => settingsCompleter?.future ?? Future.value(settings),
        ),
      ],
    ),
    child: MaterialApp(
      home: const HomePage(),
      routes: {'/library': (_) => const _LibraryProbe()},
    ),
  );
}

void main() {
  testWidgets(
    'narrow shell: HomePage cold start kicks off library scan immediately',
    (tester) async {
      final loadedSettings = SettingsRepo.empty()
        ..customModelPaths = <String>['/storage/emulated/0/Models/haru'];

      // The fake listModels returns after a single microtask. The real
      // Android path is gated by `getApplicationSupportDirectory()` /
      // filesystem I/O / FUSE list(), but the *contract we care about*
      // is the same: did HomePage ask the repo to scan?
      final repo = _TraceRepo(
        onList: () async => const [
          ManifestEntry(
            id: 'haru',
            name: 'Haru',
            directoryPath: '/storage/emulated/0/Models/haru',
          ),
        ],
      );

      await tester.binding.setSurfaceSize(const Size(411, 891));
      await tester.pumpWidget(_harness(repo: repo, settings: loadedSettings));

      // After the first paint + a couple of microtask drains, the
      // home-page-initState scan must have hit the repository and
      // driven the model provider to `loading` (not stuck on `idle`).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      expect(
        repo.calls,
        greaterThanOrEqualTo(1),
        reason:
            'HomePage on Android cold start must schedule a library scan '
            'so the narrow-shell status text does not stay "Library idle".',
      );

      // Reach into the provider container once HomePage mounted to
      // assert status is no longer the initial `idle` — proves the
      // scan was actually scheduled (not just the future created).
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HomePage)),
      );
      final afterInit = container.read(modelProvider);
      expect(
        afterInit.status,
        isNot(ModelSelectionStatus.idle),
        reason:
            'modelProvider must transition past `idle` once HomePage '
            'mounts on the narrow shell — otherwise the home status text '
            'sits at "Library idle" forever on Android cold start.',
      );

      // Drive everything to a steady state and confirm the scan also
      // populates `availableModels`. This is the user-visible contract.
      await tester.pumpAndSettle();
      final settled = container.read(modelProvider);
      expect(settled.status, ModelSelectionStatus.ready);
      expect(settled.availableModels, hasLength(1));
      expect(repo.sawScanned, isTrue);
    },
  );

  testWidgets(
    'narrow shell: HomePage waits for delayed settings before scanning',
    (tester) async {
      final settingsCompleter = Completer<SettingsRepo>();
      var settingsLoaded = false;
      final repo = _TraceRepo(
        // An early scan would get an empty library and stay stuck on
        // "No models yet"; the rescan after settings resolve must see
        // the custom-path model.
        onList: () async => settingsLoaded
            ? const [
                ManifestEntry(
                  id: 'haru',
                  name: 'Haru',
                  directoryPath: '/storage/emulated/0/Models/haru',
                ),
              ]
            : const [],
      );

      await tester.binding.setSurfaceSize(const Size(411, 891));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _harness(
          repo: repo,
          settings: SettingsRepo.empty(),
          settingsCompleter: settingsCompleter,
        ),
      );
      await tester.pump();

      expect(
        repo.calls,
        0,
        reason:
            'HomePage must not scan with the temporary empty SettingsRepo '
            'while persisted settings are still loading.',
      );

      settingsLoaded = true;
      settingsCompleter.complete(
        SettingsRepo.empty()
          ..customModelPaths = <String>['/storage/emulated/0/Models'],
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(repo.calls, greaterThanOrEqualTo(1));
      expect(
        find.textContaining('Library ready (1 model)'),
        findsOneWidget,
        reason:
            'After delayed settings arrive, HomePage must rescan and show '
            'the models from the configured custom paths.',
      );
    },
  );

  testWidgets('wide shell: HomePage cold start scans at most twice '
      '(warm-up + settings-arrival rescan)', (tester) async {
    // On the wide shell HomePage's warm-up and the embedded Library
    // pane's initial load fire close together. ModelNotifier's
    // coalescing + latest-wins must collapse them into at most two
    // scans: the warm-up scan (possibly with empty settings) and one
    // follow-up rescan once persisted settings arrive. Anything more
    // means the dedup regressed to racing parallel scans.
    final loadedSettings = SettingsRepo.empty();
    final repo = _TraceRepo(onList: () async => const []);

    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_harness(repo: repo, settings: loadedSettings));
    await tester.pumpAndSettle();

    expect(
      repo.calls,
      lessThanOrEqualTo(2),
      reason:
          'HomePage warm-up + embedded Library load must coalesce into '
          'at most one scan plus one settings-arrival rescan.',
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomePage)),
    );
    expect(container.read(modelProvider).status, ModelSelectionStatus.ready);
  });
}

class _LibraryProbe extends StatelessWidget {
  const _LibraryProbe();
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('LIBRARY_PROBE')));
}
