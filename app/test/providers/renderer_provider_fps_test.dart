import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live2d_viewer/providers/renderer_provider.dart';

import '../support/stub_renderer_api.dart';

/// Records every FPS cap pushed through [setTargetFps].
class _RecordingRendererApi extends StubRendererApi {
  final List<int> fpsCalls = [];

  @override
  Future<void> setTargetFps(int fps) async {
    fpsCalls.add(fps);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('RendererNotifier.setTargetFps forwards the cap to the API', () async {
    final api = _RecordingRendererApi();
    final container = ProviderContainer(
      overrides: [rendererApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    final notifier = container.read(rendererProvider.notifier);
    await notifier.setTargetFps(30);
    await notifier.setTargetFps(0);

    expect(api.fpsCalls, [30, 0]);
  });

  test('setTargetFps swallows API errors (best-effort)', () async {
    final container = ProviderContainer(
      overrides: [rendererApiProvider.overrideWithValue(_ThrowingApi())],
    );
    addTearDown(container.dispose);

    // Must not throw — a cap tweak should never disrupt the viewer.
    await container.read(rendererProvider.notifier).setTargetFps(120);
  });
}

class _ThrowingApi extends StubRendererApi {
  @override
  Future<void> setTargetFps(int fps) async {
    throw StateError('renderer not ready');
  }
}
