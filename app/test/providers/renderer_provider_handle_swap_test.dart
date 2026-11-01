import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live2d_viewer/providers/renderer_provider.dart';
import 'package:live2d_viewer/src/rust/render/frame_driver.dart';
import 'package:live2d_viewer/src/rust/render/texture_export.dart';

import '../support/stub_renderer_api.dart';

/// Emits a scripted sequence of [FrameEvent]s, pausing between them so the
/// test can flush microtasks and observe intermediate state.
class _SequencedRendererApi extends StubRendererApi {
  _SequencedRendererApi(this.events);

  final List<FrameEvent> events;

  @override
  Stream<FrameEvent> startFrameLoop() async* {
    for (final event in events) {
      yield event;
      // Yield to the event loop so _onFrameUpdated completes per event.
      await Future<void>.delayed(Duration.zero);
    }
  }

  @override
  Future<void> stopFrameLoop() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const textureChannel = MethodChannel('live2d_viewer/texture');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(textureChannel, null);
  });

  test('a changed native handle swaps in place via update — same texture id, '
      'no unregister', () async {
    // Regression for the resize re-registration protocol
    // (docs/postmortem/2026-07-21-viewer-setwindowsize-black-bars.md and
    // .../2026-07-30-windows-model-switch-process-crash.md): when
    // `setWindowSize` reallocates the D3D12 shared texture, the next
    // Updated event carries a NEW nativeHandle. The handle-change branch
    // must swap the NT handle IN PLACE via the `update` method (keeping
    // the same Flutter texture id). It must NEVER unregister+register
    // during an active frame loop — tearing down the TextureLayer on the
    // platform thread while the raster thread paints it aborts the
    // process (c0000409 fastfail).
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(textureChannel, (call) async {
          calls.add(call.method);
          if (call.method == 'register') return 11;
          if (call.method == 'update') return 11;
          return null;
        });

    final firstHandle = SharedTextureHandle(
      width: 64,
      height: 64,
      nativeHandle: BigInt.from(0x1234),
    );
    final reallocatedHandle = SharedTextureHandle(
      width: 128,
      height: 128,
      nativeHandle: BigInt.from(0x5678),
    );
    final api = _SequencedRendererApi([
      FrameEvent.updated(firstHandle),
      FrameEvent.updated(reallocatedHandle),
    ]);

    final container = ProviderContainer(
      overrides: [rendererApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    await container.read(rendererProvider.notifier).startFrameLoop();
    // Flush the two Updated events plus their channel round-trips.
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    // First event registered, second swapped in place.
    expect(calls, contains('register'));
    expect(calls, contains('update'));
    expect(
      calls.where((m) => m == 'register').length,
      1,
      reason: 'a handle change must not mint a second texture',
    );
    expect(
      calls,
      isNot(contains('unregister')),
      reason:
          'unregister during an active frame loop races the raster '
          'thread (c0000409 fastfail) — resize must use update',
    );
    expect(
      calls.indexOf('register') < calls.indexOf('update'),
      isTrue,
      reason: 'update must target the texture minted by register',
    );

    // The Flutter texture id survives the handle swap.
    expect(container.read(rendererProvider).textureId, 11);
  });

  test('an unchanged native handle does not re-register or update', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(textureChannel, (call) async {
          calls.add(call.method);
          if (call.method == 'register') return 11;
          if (call.method == 'update') return 11;
          return null;
        });

    final handle = SharedTextureHandle(
      width: 64,
      height: 64,
      nativeHandle: BigInt.from(0x1234),
    );
    final api = _SequencedRendererApi([
      FrameEvent.updated(handle),
      FrameEvent.updated(handle),
      FrameEvent.updated(handle),
    ]);

    final container = ProviderContainer(
      overrides: [rendererApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    await container.read(rendererProvider.notifier).startFrameLoop();
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(calls.where((m) => m == 'register').length, 1);
    expect(calls, isNot(contains('update')));
    expect(container.read(rendererProvider).textureId, 11);
  });
}
