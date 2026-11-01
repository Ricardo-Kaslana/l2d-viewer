import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live2d_viewer/data/remote_package_repo.dart';
import 'package:live2d_viewer/data/settings_repo.dart';
import 'package:live2d_viewer/features/remote/remote_page.dart';
import 'package:live2d_viewer/models/package_index.dart';
import 'package:live2d_viewer/providers/model_provider.dart';
import 'package:live2d_viewer/providers/remote_provider.dart';

PackageEntry _entry() {
  return PackageEntry(
    id: 'model_a',
    name: 'Model A',
    latest: '1.0.0',
    versions: [
      PackageVersion(
        version: '1.0.0',
        url: 'packages/model_a.zip',
        sha256: 'abc',
        size: 1024,
      ),
    ],
  );
}

class _FakeRemotePackageRepo extends RemotePackageRepo {
  _FakeRemotePackageRepo({this.throwOnDelete});

  final List<String> deletedIds = [];
  final String? throwOnDelete;

  @override
  Future<PackageIndex> fetchIndex(Uri url) async {
    // Stub: return an empty index so RemotePage.initState's microtask
    // resolves cleanly. Without this, the microtask throws (or hangs
    // awaiting a real network) and `pumpAndSettle` times out before
    // the test can push its own state.
    return PackageIndex(packages: const []);
  }

  @override
  Future<bool> deletePackage(String packageId) async {
    deletedIds.add(packageId);
    if (throwOnDelete != null) {
      throw FileSystemException(throwOnDelete!, packageId);
    }
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

class _NoopModelNotifier extends ModelNotifier {
  _NoopModelNotifier() : super(_NoopModelRepository());

  @override
  Future<void> refreshModels() async {}
}

class _NoopModelRepository implements ModelRepository {
  @override
  Future<List<ManifestEntry>> listModels() async => <ManifestEntry>[];
}

/// Build an in-memory [SettingsRepo] with the package URL pre-set so
/// [RemoteNotifier.fetchIndex] can resolve without touching the real
/// `path_provider` channel (which is unmocked in widget tests and
/// would block until pumpAndSettle's 10-min timeout).
SettingsRepo _settings() {
  final s = SettingsRepo.empty()..packageSourceUrl = 'https://example.test';
  return s;
}

void main() {
  testWidgets(
    'installed tile shows delete button; confirm dialog drives delete',
    (tester) async {
      final repo = _FakeRemotePackageRepo();
      final entry = _entry();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            remotePackageRepoProvider.overrideWithValue(repo),
            modelProvider.overrideWith((ref) => _NoopModelNotifier()),
            settingsRepoProvider.overrideWith((ref) => _settings()),
          ],
          child: const MaterialApp(home: RemotePage()),
        ),
      );
      // Wait for fetchIndex microtask + first frame.
      await tester.pumpAndSettle();

      // Seed installedIds after fetchIndex returns an empty index.
      // Manually set state so the tile flips to "installed" rendering.
      final element = tester.element(find.byType(RemotePage));
      final container = ProviderScope.containerOf(element, listen: false);
      final notifier = container.read(remoteProvider.notifier);
      notifier.state = RemoteState(
        status: RemoteStatus.ready,
        packages: [entry],
        installedIds: {'model_a'},
      );
      await tester.pumpAndSettle();

      // Tile is rendered, with delete affordance.
      expect(find.text('Model A'), findsOneWidget);
      expect(
        find.byTooltip('Delete installed package'),
        findsOneWidget,
        reason: 'delete button must appear for installed tiles',
      );

      // Tap delete → confirm dialog appears.
      await tester.tap(find.byTooltip('Delete installed package'));
      await tester.pumpAndSettle();
      expect(find.text('Delete installed package?'), findsOneWidget);

      // Confirm.
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      // Repo was invoked with the right id.
      expect(repo.deletedIds, ['model_a']);

      // Optimistic UI update removed the id from installedIds.
      expect(notifier.state.installedIds, isNot(contains('model_a')));
    },
  );

  testWidgets('cancelling the confirm dialog does not invoke delete', (
    tester,
  ) async {
    final repo = _FakeRemotePackageRepo();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          remotePackageRepoProvider.overrideWithValue(repo),
          modelProvider.overrideWith((ref) => _NoopModelNotifier()),
          settingsRepoProvider.overrideWith((ref) => _settings()),
        ],
        child: const MaterialApp(home: RemotePage()),
      ),
    );
    await tester.pumpAndSettle();

    final element = tester.element(find.byType(RemotePage));
    final container = ProviderScope.containerOf(element, listen: false);
    final notifier = container.read(remoteProvider.notifier);
    notifier.state = RemoteState(
      status: RemoteStatus.ready,
      packages: [_entry()],
      installedIds: {'model_a'},
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete installed package'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(repo.deletedIds, isEmpty);
    expect(
      notifier.state.installedIds,
      contains('model_a'),
      reason: 'cancel must not change installedIds',
    );
  });

  testWidgets(
    'delete button is hidden while a download is in flight for that id',
    (tester) async {
      final repo = _FakeRemotePackageRepo();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            remotePackageRepoProvider.overrideWithValue(repo),
            modelProvider.overrideWith((ref) => _NoopModelNotifier()),
            settingsRepoProvider.overrideWith((ref) => _settings()),
          ],
          child: const MaterialApp(home: RemotePage()),
        ),
      );
      await tester.pumpAndSettle();

      final element = tester.element(find.byType(RemotePage));
      final container = ProviderScope.containerOf(element, listen: false);
      final notifier = container.read(remoteProvider.notifier);
      // Installed + in-flight download at 50%.
      notifier.state = RemoteState(
        status: RemoteStatus.ready,
        packages: [_entry()],
        installedIds: {'model_a'},
        downloads: const {
          'model_a': DownloadState(packageId: 'model_a', progress: 0.5),
        },
      );
      await tester.pumpAndSettle();

      expect(
        find.byTooltip('Delete installed package'),
        findsNothing,
        reason:
            'delete must be hidden while a download is in flight to '
            'avoid racing the in-flight extract',
      );
    },
  );

  testWidgets('failed delete shows the error banner (regression for "删除不成功")', (
    tester,
  ) async {
    // Repro for the user-reported "删除不成功" bug. The previous
    // implementation set `errorMessage` on a non-error state, so
    // RemotePage._content never rendered the error branch — the
    // tile silently flipped back to "installed" with no visible
    // feedback. The fix flips `status` to RemoteStatus.error as
    // well, which routes _content to the error branch.
    final repo = _FakeRemotePackageRepo(throwOnDelete: 'permission denied');
    final entry = _entry();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          remotePackageRepoProvider.overrideWithValue(repo),
          modelProvider.overrideWith((ref) => _NoopModelNotifier()),
          settingsRepoProvider.overrideWith((ref) => _settings()),
        ],
        child: const MaterialApp(home: RemotePage()),
      ),
    );
    await tester.pumpAndSettle();

    final element = tester.element(find.byType(RemotePage));
    final container = ProviderScope.containerOf(element, listen: false);
    final notifier = container.read(remoteProvider.notifier);
    notifier.state = RemoteState(
      status: RemoteStatus.ready,
      packages: [entry],
      installedIds: {'model_a'},
    );
    await tester.pumpAndSettle();

    // Tap delete → confirm dialog → confirm.
    await tester.tap(find.byTooltip('Delete installed package'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    // The error banner must render. Before the fix, this failed
    // because RemotePage._content only switched to the error
    // branch when status == RemoteStatus.error, but
    // RemoteNotifier.deletePackage only set errorMessage.
    expect(
      find.textContaining('permission denied'),
      findsOneWidget,
      reason:
          'user must see the failure reason, not a silent '
          'tile flip back to installed',
    );
    expect(
      find.textContaining('Failed to delete'),
      findsOneWidget,
      reason: 'banner must show the action-failed framing',
    );
    // Tile is rolled back to "installed" because the optimistic
    // update was reverted.
    expect(notifier.state.installedIds, contains('model_a'));
  });
}
