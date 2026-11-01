import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live2d_viewer/data/remote_package_repo.dart';
import 'package:live2d_viewer/data/settings_repo.dart';
import 'package:live2d_viewer/models/package_index.dart';
import 'package:live2d_viewer/providers/model_provider.dart';
import 'package:live2d_viewer/providers/remote_provider.dart';

void main() {
  test('500 rapid onProgress calls produce far fewer state writes '
      'and the final progress reaches 1.0', () async {
    final repo = _ProgressFakeRepo();
    final settings = SettingsRepo.empty()
      ..packageSourceUrl = 'http://localhost/pkgs/';
    final container = ProviderContainer(
      overrides: [
        remotePackageRepoProvider.overrideWithValue(repo),
        settingsRepoProvider.overrideWith((ref) async => settings),
        modelProvider.overrideWith((ref) => _NoopModelNotifier()),
      ],
    );
    addTearDown(container.dispose);

    var progressWrites = 0;
    double? lastProgress;
    container.listen(remoteProvider, (prev, next) {
      final ds = next.downloads['model_a'];
      if (ds != null && !ds.extracting && ds.error == null) {
        if (ds.progress != lastProgress) {
          progressWrites++;
          lastProgress = ds.progress;
        }
      }
    });

    await container.read(remoteProvider.notifier).downloadAndInstall(_entry());

    expect(repo.progressCalls, 500);
    expect(
      progressWrites,
      lessThan(150),
      reason:
          'progress state writes must be throttled well below the '
          '500 raw onProgress callbacks',
    );
    expect(lastProgress, 1.0, reason: 'the 100% event must always land');
    final state = container.read(remoteProvider);
    expect(state.installedIds, contains('model_a'));
    expect(state.downloads.containsKey('model_a'), isFalse);
  });
}

PackageEntry _entry() => PackageEntry(
  id: 'model_a',
  name: 'Model A',
  latest: '1.0.0',
  versions: [
    PackageVersion(
      version: '1.0.0',
      url: 'model_a.zip',
      sha256: 'abc',
      size: 500,
    ),
  ],
);

class _ProgressFakeRepo extends RemotePackageRepo {
  int progressCalls = 0;

  @override
  Future<File> downloadPackage(
    PackageVersion version,
    Uri baseUrl, {
    void Function(DownloadProgress)? onProgress,
    int maxDownloadBytes = 1 << 31,
  }) async {
    for (var i = 1; i <= 500; i++) {
      progressCalls++;
      onProgress?.call(DownloadProgress(received: i, total: 500));
    }
    return File('fake.zip');
  }

  @override
  Future<Directory> verifyAndExtract(
    File zipFile,
    String expectedSha256,
    String modelId, {
    int maxUncompressedBytes = 1 << 30,
    String? sourceUrl,
    String? versionLabel,
    DateTime? installedAt,
  }) async {
    return Directory('fake');
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
