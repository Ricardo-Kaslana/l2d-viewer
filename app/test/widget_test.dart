import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:live2d_viewer/app.dart';
import 'package:live2d_viewer/data/settings_repo.dart';
import 'package:live2d_viewer/pages/viewer_page.dart';
import 'package:live2d_viewer/providers/model_provider.dart';

/// Empty model repository that returns no models, used to avoid touching
/// path_provider in widget tests.
class _EmptyModelRepository implements ModelRepository {
  @override
  Future<List<ManifestEntry>> listModels() async => const [];
}

/// Pre-loaded settings repo that doesn't touch the filesystem.
SettingsRepo _testSettings() => SettingsRepo.empty();

void main() {
  // Common overrides for all tests: avoid filesystem dependencies.
  ProviderScope harness(Widget child) {
    return ProviderScope(
      overrides: [
        modelRepositoryProvider.overrideWith((_) => _EmptyModelRepository()),
        settingsRepoProvider.overrideWith((_) async => _testSettings()),
      ],
      child: child,
    );
  }

  testWidgets('app renders home shell with navigation rail', (
    WidgetTester tester,
  ) async {
    // Default test surface is 800×600 which is >= the compact breakpoint
    // (720), so the wide two-pane shell renders.
    await tester.pumpWidget(harness(const Live2DViewerApp()));
    await tester.pumpAndSettle();

    expect(find.text('Live2D Viewer'), findsOneWidget);
    expect(find.text('Viewer'), findsOneWidget);
    // Library and Settings each appear once in the rail; the embedded
    // page is also Library by default so 'Library' may appear twice.
    expect(find.text('Library'), findsWidgets);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('tapping Library rail item shows the library pane', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(harness(const Live2DViewerApp()));
    await tester.pumpAndSettle();

    // Tap the rail item by its unique key (the page header has no key).
    await tester.tap(find.byKey(const Key('rail-item-Library')));
    await tester.pumpAndSettle();

    // The embedded LibraryPage renders a refresh icon in its header.
    expect(find.byIcon(Icons.refresh), findsWidgets);
  });

  testWidgets('tapping Settings rail item shows the settings pane', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(harness(const Live2DViewerApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('rail-item-Settings')));
    await tester.pumpAndSettle();

    expect(find.text('Package source URL'), findsOneWidget);
  });

  testWidgets('viewer page shows gesture controls', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(harness(const MaterialApp(home: ViewerPage())));
    await tester.pumpAndSettle();

    expect(find.text('Reset'), findsOneWidget);
    expect(find.text('Zoom In'), findsOneWidget);
    expect(find.text('Zoom Out'), findsOneWidget);
    expect(find.text('Tap'), findsOneWidget);
  });
}
