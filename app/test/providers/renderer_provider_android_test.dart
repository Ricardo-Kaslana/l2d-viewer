import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live2d_viewer/providers/renderer_provider.dart';
import 'package:live2d_viewer/src/rust/render/frame_driver.dart';

import '../support/stub_renderer_api.dart';

/// Records the order of frame-loop lifecycle calls and lets the test
/// hold `stopFrameLoop` open to prove start/stop are serialized.
class _OrderTrackingApi extends StubRendererApi {
  _OrderTrackingApi();

  final List<String> log = [];
  Completer<void>? stopGate;

  @override
  Stream<FrameEvent> startFrameLoop() {
    log.add('start');
    return const Stream<FrameEvent>.empty();
  }

  @override
  Future<void> stopFrameLoop() async {
    log.add('stop:begin');
    final gate = stopGate;
    if (gate != null) await gate.future;
    log.add('stop:end');
  }
}

void main() {
  test('StubRendererApi attachSurface/detachSurface are no-ops', () async {
    const api = StubRendererApi();
    await api.attachSurface(123, 1080, 1920);
    await api.detachSurface();
  });

  test('RendererNotifier starts in idle state', () {
    final container = ProviderContainer(
      overrides: [
        rendererApiProvider.overrideWithValue(const StubRendererApi()),
      ],
    );
    addTearDown(container.dispose);
    final state = container.read(rendererProvider);
    expect(state.status, RendererStatus.idle);
    expect(state.textureId, isNull);
    expect(state.isFrameLoopRunning, false);
  });

  test(
    'startFrameLoop waits for an in-flight stopFrameLoop (lifecycle chain)',
    () async {
      final api = _OrderTrackingApi()..stopGate = Completer<void>();
      final container = ProviderContainer(
        overrides: [rendererApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(rendererProvider.notifier);

      final stopFuture = notifier.stopFrameLoop();
      final startFuture = notifier.startFrameLoop();
      await Future<void>.delayed(Duration.zero);

      // stop is blocked on the gate; start must not have begun yet.
      expect(api.log, ['stop:begin']);

      api.stopGate!.complete();
      await stopFuture;
      await startFuture;

      expect(api.log, ['stop:begin', 'stop:end', 'start']);
    },
  );
}
