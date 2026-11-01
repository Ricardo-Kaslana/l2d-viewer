import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live2d_viewer/providers/renderer_provider.dart';
import 'package:live2d_viewer/src/rust/render/frame_driver.dart';

import '../support/stub_renderer_api.dart';

/// Stub whose frame loop stream is controlled by the test.
class _StreamedRendererApi extends StubRendererApi {
  _StreamedRendererApi(this.controller);

  final StreamController<FrameEvent> controller;

  @override
  Stream<FrameEvent> startFrameLoop() => controller.stream;
}

void main() {
  test('120 identical failed events cause at most 2 state changes', () async {
    final controller = StreamController<FrameEvent>();
    final container = ProviderContainer(
      overrides: [
        rendererApiProvider.overrideWithValue(_StreamedRendererApi(controller)),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(controller.close);

    var changes = 0;
    container.listen(rendererProvider, (prev, next) => changes++);

    await container.read(rendererProvider.notifier).startFrameLoop();
    final baseline = changes;

    for (var i = 0; i < 120; i++) {
      controller.add(const FrameEvent.failed('boom'));
    }
    await Future<void>.delayed(Duration.zero);

    final failedChanges = changes - baseline;
    expect(failedChanges, lessThanOrEqualTo(2));
    final state = container.read(rendererProvider);
    expect(state.status, RendererStatus.error);
    expect(state.errorMessage, 'boom');
  });

  test('a different failed message still updates state', () async {
    final controller = StreamController<FrameEvent>();
    final container = ProviderContainer(
      overrides: [
        rendererApiProvider.overrideWithValue(_StreamedRendererApi(controller)),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(controller.close);

    await container.read(rendererProvider.notifier).startFrameLoop();

    controller.add(const FrameEvent.failed('boom'));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(rendererProvider).errorMessage, 'boom');

    controller.add(const FrameEvent.failed('bang'));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(rendererProvider).errorMessage, 'bang');
  });
}
