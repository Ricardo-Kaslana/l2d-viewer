import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live2d_viewer/data/remote_package_repo.dart';
import 'package:live2d_viewer/data/settings_repo.dart';
import 'package:live2d_viewer/features/remote/remote_page.dart';
import 'package:live2d_viewer/models/package_index.dart';
import 'package:live2d_viewer/providers/model_provider.dart';
import 'package:live2d_viewer/providers/remote_provider.dart';

/// A malformed (but schema-valid) index can carry a package with an
/// empty `versions` list. The Remote page must render such a tile
/// degraded instead of crashing the whole list build with a
/// `StateError` from `versions.first`.
class _EmptyVersionsRepo extends RemotePackageRepo {
  @override
  Future<bool> isInstalled(String packageId) async => false;

  @override
  Future<PackageIndex> fetchIndex(Uri url) async {
    return PackageIndex(
      packages: [
        PackageEntry(
          id: 'broken',
          name: 'Broken Package',
          latest: '1.0.0',
          versions: const [],
        ),
        PackageEntry(
          id: 'ok',
          name: 'Good Package',
          latest: '1.0.0',
          versions: [
            PackageVersion(
              version: '1.0.0',
              url: 'packages/ok.zip',
              sha256: 'abc',
              size: 2 * 1024 * 1024,
            ),
          ],
        ),
      ],
    );
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

SettingsRepo _settings() {
  final s = SettingsRepo.empty()..packageSourceUrl = 'https://example.test';
  return s;
}

void main() {
  testWidgets('package with empty versions renders degraded, not a crash', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          remotePackageRepoProvider.overrideWithValue(_EmptyVersionsRepo()),
          modelProvider.overrideWith((ref) => _NoopModelNotifier()),
          settingsRepoProvider.overrideWith((ref) => _settings()),
        ],
        child: const MaterialApp(home: RemotePage()),
      ),
    );
    await tester.pumpAndSettle();

    // The healthy package still renders normally.
    expect(find.text('Good Package'), findsOneWidget);
    expect(find.text('2.0 MB'), findsOneWidget);

    // The broken one renders without size and without a download button.
    expect(find.text('Broken Package'), findsOneWidget);
    expect(find.text('No downloadable version'), findsOneWidget);
    // Exactly one download button: the healthy package's.
    expect(find.byIcon(Icons.download), findsOneWidget);
  });
}
