import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:live2d_viewer/providers/renderer_provider.dart';
import 'package:live2d_viewer/src/rust/render/frame_driver.dart';
import 'package:live2d_viewer/src/rust/render/texture_export.dart';

import '../support/stub_renderer_api.dart';

/// A [StubRendererApi] whose `startFrameLoop` emits exactly one
/// [FrameEvent.updated] and then closes the stream, so a unit test can
/// drive a deterministic register path without a long-lived stream.
///
/// `stopFrameLoop` appends `'stopFrameLoop'` to the shared [timeline]
/// list, so the test can assert its ordering against the texture
/// channel's `unregister` (which appends `'unregister'` to the same
/// list).
class _RecordingRendererApi extends StubRendererApi {
  _RecordingRendererApi(this.event, this.timeline);

  final FrameEvent event;
  final List<String> timeline;

  @override
  Stream<FrameEvent> startFrameLoop() async* {
    yield event;
  }

  @override
  Future<void> stopFrameLoop() async {
    timeline.add('stopFrameLoop');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const textureChannel = MethodChannel('live2d_viewer/texture');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(textureChannel, (call) async {
          if (call.method == 'register') return 11;
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(textureChannel, null);
  });

  test(
    'stopFrameLoop stops the Rust frame loop BEFORE unregistering the texture',
    () async {
      // Regression for the probabilistic teardown crash
      // (docs/postmortem/2026-07-30-windows-model-switch-process-crash.md,
      // second root cause: c0000409 subcode 7). The Rust frame-loop
      // worker can still present a frame after the Dart FrameEvent
      // subscription is cancelled. If `_stopFrameLoopInner`
      // unregisters the Flutter texture FIRST, the platform thread
      // tears down the TextureLayer (UnregisterTexture +
      // texture_variant_.reset()) while the raster thread is mid-paint
      // on that same layer — the engine then throws an uncaught
      // std::future_error across a noexcept boundary → terminate →
      // fastfail. The fix: call `_api.stopFrameLoop()` BEFORE
      // `TextureMethodChannel.unregister`.
      final timeline = <String>[];
      final handle = SharedTextureHandle(
        width: 64,
        height: 64,
        nativeHandle: BigInt.from(0x1234),
      );
      final api = _RecordingRendererApi(FrameEvent.updated(handle), timeline);

      // Capture the `unregister` arrival on the same timeline.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(textureChannel, (call) async {
            if (call.method == 'register') return 11;
            if (call.method == 'unregister') {
              timeline.add('unregister');
            }
            return null;
          });

      final container = ProviderContainer(
        overrides: [rendererApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);

      // Drive the full register-then-stop lifecycle.
      await container.read(rendererProvider.notifier).startFrameLoop();
      // Let the single Updated event flow through and register.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // Sanity: texture registered.
      expect(container.read(rendererProvider).textureId, 11);

      // Stop the frame loop. `_stopFrameLoopInner` records
      // 'stopFrameLoop' (via the recording api) and 'unregister' (via
      // the mock texture channel) on the shared timeline.
      await container.read(rendererProvider.notifier).stopFrameLoop();
      // Flush any pending microtasks for the unregister channel call.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // The core assertion: Rust frame loop stops before the Flutter
      // texture is unregistered.
      expect(timeline, contains('stopFrameLoop'));
      expect(timeline, contains('unregister'));
      expect(
        timeline.indexOf('stopFrameLoop') < timeline.indexOf('unregister'),
        isTrue,
        reason:
            'Rust frame loop must stop BEFORE the Flutter texture is '
            'unregistered, otherwise the raster thread races the '
            'TextureLayer teardown (c0000409 fastfail).',
      );
    },
  );
}
