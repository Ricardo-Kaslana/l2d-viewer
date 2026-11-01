import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:live2d_viewer/providers/model_provider.dart';

class _FakeRepo implements ModelRepository {
  @override
  Future<List<ManifestEntry>> listModels() async => const [];
}

/// Repo whose [listModels] blocks until the test releases it, counting
/// how many scans were actually started.
class _GatedRepo implements ModelRepository {
  int calls = 0;
  Completer<void> gate = Completer<void>();

  @override
  Future<List<ManifestEntry>> listModels() async {
    calls++;
    await gate.future;
    return const [];
  }
}

void main() {
  group('ModelNotifier scan dedup', () {
    test('concurrent loadAvailableModels calls coalesce to one scan', () async {
      final repo = _GatedRepo();
      final notifier = ModelNotifier(repo);

      final f1 = notifier.loadAvailableModels();
      final f2 = notifier.loadAvailableModels();
      final f3 = notifier.loadAvailableModels();
      expect(notifier.state.status, ModelSelectionStatus.loading);
      expect(identical(f1, f2), isTrue);
      expect(identical(f1, f3), isTrue);

      repo.gate.complete();
      await f1;

      expect(repo.calls, 1);
      expect(notifier.state.status, ModelSelectionStatus.ready);
    });

    test('refresh twice during a scan runs exactly one follow-up scan '
        '(latest-wins)', () async {
      final repo = _GatedRepo();
      final notifier = ModelNotifier(repo);

      final first = notifier.loadAvailableModels();
      unawaited(notifier.refreshModels());
      unawaited(notifier.refreshModels());
      expect(repo.calls, 1);

      // Release the first scan; the pending refresh starts a second one.
      final firstGate = repo.gate;
      repo.gate = Completer<void>();
      firstGate.complete();
      await first;
      await Future<void>.delayed(Duration.zero);

      expect(repo.calls, 2, reason: 'two refreshes collapse into one rescan');

      repo.gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(notifier.state.status, ModelSelectionStatus.ready);
    });

    test('refresh with no scan in flight starts a scan', () async {
      final repo = _GatedRepo();
      final notifier = ModelNotifier(repo);
      repo.gate.complete();

      await notifier.refreshModels();
      expect(repo.calls, 1);
      expect(notifier.state.status, ModelSelectionStatus.ready);
    });
  });

  group('ModelNotifier.clearSelection', () {
    test('actually clears the selected model path', () async {
      final notifier = ModelNotifier(_FakeRepo());
      await notifier.selectModel('C:/models/foo/foo.model3.json');
      expect(notifier.state.selectedModelPath, isNotNull);

      notifier.clearSelection();

      // Regression: copyWith(selectedModelPath: null) was a no-op
      // (`null ?? old` kept the old value), leaving a dangling selection
      // after deleting the currently-selected model.
      expect(notifier.state.selectedModelPath, isNull);
    });
  });

  group('ModelState.copyWith', () {
    test('clearSelection flag clears; plain copyWith preserves', () {
      const state = ModelState(selectedModelPath: '/a/b.model3.json');
      expect(
        state.copyWith(status: ModelSelectionStatus.ready).selectedModelPath,
        '/a/b.model3.json',
      );
      expect(state.copyWith(clearSelection: true).selectedModelPath, isNull);
    });
  });
}
