import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:live2d_viewer/data/settings_repo.dart';
import 'package:live2d_viewer/pages/library_page.dart';
import 'package:live2d_viewer/providers/model_provider.dart';

/// Empty model repository that returns no models, used to avoid touching
/// path_provider in widget tests.
class _EmptyModelRepository implements ModelRepository {
  @override
  Future<List<ManifestEntry>> listModels() async => const [];
}

Widget _harness(Widget child) {
  return ProviderScope(
    overrides: [
      modelRepositoryProvider.overrideWith((_) => _EmptyModelRepository()),
      settingsRepoProvider.overrideWith((_) async => SettingsRepo.empty()),
    ],
    child: MaterialApp(home: child),
  );
}

void main() {
  testWidgets('library page renders empty state', (tester) async {
    await tester.pumpWidget(_harness(const LibraryPage()));
    await tester.pumpAndSettle();

    expect(find.text('No models installed'), findsOneWidget);
  });

  testWidgets('embedded library page renders header without Scaffold', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(const LibraryPage(embedded: true)));
    await tester.pumpAndSettle();

    expect(find.text('Library'), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
  });
}
