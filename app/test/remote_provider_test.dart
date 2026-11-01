import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live2d_viewer/data/remote_package_repo.dart';
import 'package:live2d_viewer/models/package_index.dart';
import 'package:live2d_viewer/providers/model_provider.dart';
import 'package:live2d_viewer/providers/remote_provider.dart';

void main() {
  group('RemoteState', () {
    test('default state is idle with empty packages', () {
      const state = RemoteState();
      expect(state.status, RemoteStatus.idle);
      expect(state.packages, isEmpty);
      expect(state.installedIds, isEmpty);
      expect(state.downloads, isEmpty);
      expect(state.errorMessage, isNull);
    });

    test('copyWith preserves unchanged fields', () {
      const state = RemoteState(
        status: RemoteStatus.ready,
        packages: [],
        installedIds: {'model_a'},
      );
      final updated = state.copyWith(status: RemoteStatus.error);
      expect(updated.status, RemoteStatus.error);
      expect(updated.installedIds, contains('model_a'));
    });

    test('copyWith preserves errorMessage when not provided', () {
      // Aligns with `ModelState.copyWith`'s `clearError` convention:
      // `errorMessage` is only changed when explicitly passed or when
      // `clearError: true` is passed. An implicit copyWith call
      // (e.g. updating `installedIds` after a delete) must NOT clear
      // a banner the UI is still rendering.
      const state = RemoteState(errorMessage: 'old error');
      final updated = state.copyWith(status: RemoteStatus.loading);
      expect(updated.errorMessage, 'old error');
    });

    test('copyWith with clearError: true wipes errorMessage', () {
      const state = RemoteState(errorMessage: 'old error');
      final updated = state.copyWith(clearError: true);
      expect(updated.errorMessage, isNull);
    });

    test('copyWith with explicit errorMessage overrides current', () {
      const state = RemoteState(errorMessage: 'old error');
      final updated = state.copyWith(errorMessage: 'new error');
      expect(updated.errorMessage, 'new error');
    });
  });

  group('DownloadState', () {
    test('failed is true when error is set', () {
      const ds = DownloadState(packageId: 'x', error: 'timeout');
      expect(ds.failed, isTrue);
    });

    test('failed is false when no error', () {
      const ds = DownloadState(packageId: 'x', progress: 0.5);
      expect(ds.failed, isFalse);
    });
  });

  group('PackageIndex parsing', () {
    test('parses multi-package index', () {
      const raw = '''
      {
        "schema": "live2d-viewer.pkg-index/v1",
        "packages": [
          {
            "id": "model_a",
            "name": "Model A",
            "latest": "1.0.0",
            "versions": [
              {"version": "1.0.0", "url": "packages/model_a.zip", "sha256": "abc123", "size": 1024}
            ]
          },
          {
            "id": "model_b",
            "name": "Model B",
            "latest": "2.0.0",
            "versions": [
              {"version": "1.0.0", "url": "packages/model_b_1.zip", "sha256": "def", "size": 512},
              {"version": "2.0.0", "url": "packages/model_b_2.zip", "sha256": "ghi", "size": 2048}
            ]
          }
        ]
      }
      ''';
      final index = PackageIndex.fromJsonString(raw);
      expect(index.packages.length, 2);
      expect(index.packages[0].id, 'model_a');
      expect(index.packages[1].versions.length, 2);
      expect(index.packages[1].latest, '2.0.0');
    });

    test('rejects wrong schema', () async {
      const raw = '{"schema": "wrong/v2", "packages": []}';
      expect(
        () => PackageIndex.fromJsonString(raw),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('RemoteNotifier.deletePackage', () {
    PackageEntry entry({String id = 'model_a', String name = 'Model A'}) {
      return PackageEntry(
        id: id,
        name: name,
        latest: '1.0.0',
        versions: [
          PackageVersion(
            version: '1.0.0',
            url: 'packages/$id.zip',
            sha256: 'abc',
            size: 1024,
          ),
        ],
      );
    }

    test('successful delete removes id from installedIds', () async {
      final repo = _FakeRemotePackageRepo();
      final notifier = _buildNotifier(repo, installedIds: {'model_a'});

      await notifier.deletePackage(entry());

      expect(notifier.state.installedIds, isNot(contains('model_a')));
      expect(notifier.state.errorMessage, isNull);
      expect(repo.deletedIds, ['model_a']);
    });

    test('failed delete rolls back installedIds and surfaces error', () async {
      final repo = _FakeRemotePackageRepo(throwOnDelete: 'disk full');
      final notifier = _buildNotifier(repo, installedIds: {'model_a'});

      await notifier.deletePackage(entry());

      expect(
        notifier.state.installedIds,
        contains('model_a'),
        reason: 'optimistic install must be rolled back on failure',
      );
      expect(notifier.state.errorMessage, contains('disk full'));
      // Regression for the "删除不成功" silent-failure bug: setting
      // only `errorMessage` is not enough — RemotePage only renders
      // the error banner in the `RemoteStatus.error` branch, so the
      // status must flip to error too, otherwise the user sees the
      // tile silently flip back to "installed" with no explanation.
      expect(
        notifier.state.status,
        RemoteStatus.error,
        reason: 'status must flip to error so RemotePage renders the banner',
      );
    });

    test(
      'failed delete does not propagate refreshModels errors as delete failures',
      () async {
        // Even if the post-delete `refreshModels()` throws, the
        // primary delete action is recorded as successful (the id is
        // removed from installedIds) and the refresh error is only
        // logged. Otherwise a transient Library-list failure would
        // report "delete failed" to the user when their disk delete
        // actually succeeded.
        final repo = _FakeRemotePackageRepo();
        final notifier = _buildNotifier(
          repo,
          installedIds: {'model_a'},
          throwOnRefresh: true,
        );

        await notifier.deletePackage(entry());

        expect(
          notifier.state.installedIds,
          isNot(contains('model_a')),
          reason: 'primary delete should still be reported as success',
        );
        expect(notifier.state.status, RemoteStatus.ready);
        expect(notifier.state.errorMessage, isNull);
      },
    );

    test('missing-on-disk delete is treated as success', () async {
      final repo = _FakeRemotePackageRepo(returnFalse: true);
      final notifier = _buildNotifier(repo, installedIds: {'model_a'});

      await notifier.deletePackage(entry());

      expect(notifier.state.installedIds, isNot(contains('model_a')));
      expect(repo.deletedIds, ['model_a']);
    });
  });
}

/// Build a [RemoteNotifier] wired to a [_FakeRemotePackageRepo].
///
/// Uses a [ProviderContainer] with the real `remotePackageRepoProvider`
/// overridden and the real `modelProvider` overridden with a no-op
/// notifier, so the production wiring is exercised but no real I/O runs.
RemoteNotifier _buildNotifier(
  _FakeRemotePackageRepo repo, {
  Set<String>? installedIds,
  bool throwOnRefresh = false,
}) {
  final container = ProviderContainer(
    overrides: [
      remotePackageRepoProvider.overrideWithValue(repo),
      modelProvider.overrideWith(
        (ref) => _NoopModelNotifier(throwOnRefresh: throwOnRefresh),
      ),
    ],
  );
  addTearDown(container.dispose);
  final notifier = container.read(remoteProvider.notifier);
  // Seed the initial state synchronously so the delete can find
  // installedIds without going through fetchIndex().
  if (installedIds != null) {
    notifier.state = RemoteState(
      status: RemoteStatus.ready,
      installedIds: installedIds,
    );
  }
  return notifier;
}

class _FakeRemotePackageRepo extends RemotePackageRepo {
  _FakeRemotePackageRepo({this.throwOnDelete, this.returnFalse = false});

  final String? throwOnDelete;
  final bool returnFalse;
  final List<String> deletedIds = [];

  @override
  Future<bool> deletePackage(String packageId) async {
    deletedIds.add(packageId);
    if (throwOnDelete != null) {
      throw FileSystemException(throwOnDelete!, packageId);
    }
    return !returnFalse;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

class _NoopModelNotifier extends ModelNotifier {
  _NoopModelNotifier({this.throwOnRefresh = false})
    : super(_NoopModelRepository());

  /// When `true`, [refreshModels] throws — used to verify that
  /// [RemoteNotifier.deletePackage] isolates Library-refresh errors
  /// from the primary delete action.
  final bool throwOnRefresh;

  @override
  Future<void> refreshModels() async {
    if (throwOnRefresh) {
      throw StateError('refreshModels stub failure');
    }
  }
}

class _NoopModelRepository implements ModelRepository {
  @override
  Future<List<ManifestEntry>> listModels() async => <ManifestEntry>[];
}
