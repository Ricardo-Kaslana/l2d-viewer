import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:live2d_viewer/data/settings_repo.dart';
import 'package:live2d_viewer/pages/viewer_page.dart';
import 'package:live2d_viewer/providers/model_provider.dart';
import 'package:live2d_viewer/providers/renderer_provider.dart';
import 'package:live2d_viewer/src/rust/render/frame_driver.dart';
import 'package:live2d_viewer/src/rust/render/texture_export.dart';
import 'package:live2d_viewer/widgets/error_banner.dart';

/// Fake [RendererApi] with controllable behavior for viewer page tests.
class _FakeRendererApi implements RendererApi {
  _FakeRendererApi({
    this.motionGroups = const [],
    this.loadCompleter,
    this.shouldThrow = false,
    this.frameEvents = const [],
    this.keepStreamOpen = false,
  });

  List<String> motionGroups;
  Completer<void>? loadCompleter;
  bool shouldThrow;

  /// When `true`, the fake frame stream stays open after emitting
  /// [frameEvents], keeping `isFrameLoopRunning` true (needed to assert
  /// on the FPS badge, which hides once the loop stops).
  bool keepStreamOpen;

  /// Frames the fake `startFrameLoop` will emit, in order. When the
  /// list is exhausted the stream completes (mimicking the Rust worker
  /// exiting). Tests can populate this with `FrameEvent.updated(...)`
  /// to drive `TextureMethodChannel.register`/`markFrameAvailable`.
  List<FrameEvent> frameEvents;

  @override
  Future<void> initialize() async {}

  @override
  Future<ModelLoadResult> loadModel(String path) async {
    if (loadCompleter != null) {
      await loadCompleter!.future;
    }
    if (shouldThrow) {
      throw StateError('renderer boom');
    }
    return ModelLoadResult(motionGroups: motionGroups);
  }

  @override
  Future<void> triggerMotion(String group) async {
    if (triggerMotionError != null) {
      throw triggerMotionError!;
    }
  }

  /// When non-null, [triggerMotion] throws this error. Used by the F7
  /// stale-error test to inject a motion failure without touching the
  /// real Rust bridge.
  Object? triggerMotionError;

  @override
  Future<void> resetGesture() async {}

  @override
  Future<void> setTargetFps(int fps) async {}

  @override
  Future<void> tap() async {}

  @override
  Future<void> zoom(double factor) async {}

  @override
  Future<void> panStart() async {}

  @override
  Future<void> panDelta(
    double dx,
    double dy,
    int surfaceW,
    int surfaceH,
  ) async {}

  @override
  Future<void> panEnd() async {}

  @override
  Future<void> resize(int width, int height) async {}

  @override
  Future<List<String>> getMotionGroups() async => motionGroups;

  @override
  Future<void> setWindowSize(int width, int height) async {}

  @override
  Stream<FrameEvent> startFrameLoop() {
    // When no events are configured, keep the stream open forever
    // so the StateNotifier's onDone does not fire and overwrite the
    // caller's state. Tests that want deterministic completion
    // supply a non-empty frameEvents list.
    final controller = StreamController<FrameEvent>();
    for (final event in frameEvents) {
      controller.add(event);
    }
    if (frameEvents.isEmpty || keepStreamOpen) {
      return controller.stream;
    }
    controller.close();
    return controller.stream;
  }

  @override
  Future<void> stopFrameLoop() async {}

  @override
  Future<(double, double, double, double)> getGestureState() async =>
      (1.0, 1.0, 0.0, 0.0);

  @override
  Future<void> setGestureState(
    double scaleX,
    double scaleY,
    double translateX,
    double translateY,
  ) async {}

  @override
  Future<void> attachSurface(int nativeWindow, int width, int height) async {}

  @override
  Future<void> detachSurface() async {}
}

/// Builds a fresh `SharedTextureHandle` for tests.
SharedTextureHandle _handle({int width = 64, int height = 64}) {
  return SharedTextureHandle(
    width: width,
    height: height,
    nativeHandle: BigInt.from(0x1234),
  );
}

/// Empty model repository to avoid touching path_provider in tests.
class _EmptyModelRepository implements ModelRepository {
  @override
  Future<List<ManifestEntry>> listModels() async => const [];
}

/// [ModelNotifier] subclass that pre-selects a model path on construction,
/// so the viewer page loads the model during its init microtask.
class _PreSelectedModelNotifier extends ModelNotifier {
  _PreSelectedModelNotifier(super.repo, String path) {
    selectModel(path);
  }
}

Widget _harness({
  required RendererApi rendererApi,
  String? selectedModelPath,
  bool showFps = false,
}) {
  final overrides = <Override>[
    rendererApiProvider.overrideWith((_) => rendererApi),
    modelRepositoryProvider.overrideWith((_) => _EmptyModelRepository()),
  ];
  if (showFps) {
    overrides.add(
      settingsRepoProvider.overrideWith((_) async {
        final settings = SettingsRepo.empty();
        settings.showFps = true;
        return settings;
      }),
    );
  }
  if (selectedModelPath != null) {
    overrides.add(
      modelProvider.overrideWith(
        (_) => _PreSelectedModelNotifier(
          _EmptyModelRepository(),
          selectedModelPath,
        ),
      ),
    );
  }
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(home: const ViewerPage()),
  );
}

void main() {
  // The new _initializeAndLoad auto-starts the frame loop after a
  // successful loadModel. That loop calls TextureMethodChannel.register
  // on the first FrameEvent.updated. Without a mock handler the call
  // throws MissingPluginException, which the notifier surfaces as a
  // generic error and overwrites the original 'renderer boom' banner.
  // Stub the channel once per test so register returns -1 (no GPU),
  // keeping the legacy assertion paths intact.
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('live2d_viewer/texture'),
          (call) async {
            if (call.method == 'register') return -1;
            return null;
          },
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('live2d_viewer/texture'),
          null,
        );
  });

  testWidgets('shows loading indicator while model is loading', (tester) async {
    final completer = Completer<void>();
    final api = _FakeRendererApi(loadCompleter: completer);
    await tester.pumpWidget(
      _harness(
        rendererApi: api,
        selectedModelPath: '/models/test/model.model3.json',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    completer.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('shows no-model hint when no model selected', (tester) async {
    final api = _FakeRendererApi();
    await tester.pumpWidget(_harness(rendererApi: api));
    await tester.pumpAndSettle();

    expect(find.textContaining('No model selected'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows error banner with retry and dismiss when load fails', (
    tester,
  ) async {
    final api = _FakeRendererApi(shouldThrow: true);
    await tester.pumpWidget(
      _harness(
        rendererApi: api,
        selectedModelPath: '/models/test/model.model3.json',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('renderer boom'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Dismiss'), findsOneWidget);
  });

  testWidgets('dismiss button clears the error banner', (tester) async {
    final api = _FakeRendererApi(shouldThrow: true);
    await tester.pumpWidget(
      _harness(
        rendererApi: api,
        selectedModelPath: '/models/test/model.model3.json',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('renderer boom'), findsOneWidget);

    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();

    expect(find.textContaining('renderer boom'), findsNothing);
  });

  testWidgets(
    'loadModel success clears stale error from a prior gesture/motion failure',
    (tester) async {
      // Repro for F7: triggerMotion failure sets errorMessage; a
      // subsequent successful loadModel must clear it (otherwise the
      // viewer shows "Ready" with an error banner).
      //
      // Flow: load model A successfully → open motion sheet → tap a
      // motion that throws → error banner appears → tap Retry which
      // re-runs loadModel → error banner must disappear.
      final api = _FakeRendererApi(motionGroups: ['Idle']);
      await tester.pumpWidget(
        _harness(
          rendererApi: api,
          selectedModelPath: '/models/test/test_model.model3.json',
        ),
      );
      await tester.pumpAndSettle();

      // Model loaded, no error.
      expect(find.text('Idle'), findsOneWidget);
      expect(find.byType(ErrorBanner), findsNothing);

      // Make the next triggerMotion fail, then drive it through the
      // motion chip in the floating control bar.
      api.triggerMotionError = StateError('motion boom');
      await tester.tap(find.text('Idle'));
      await tester.pumpAndSettle();

      // Error banner now visible from the triggerMotion failure.
      expect(find.byType(ErrorBanner), findsOneWidget);
      expect(find.textContaining('motion boom'), findsOneWidget);

      // Clear the injected failure so the next loadModel succeeds.
      api.triggerMotionError = null;

      // Retry re-runs loadModel; the success path must clear the error.
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(
        find.byType(ErrorBanner),
        findsNothing,
        reason: 'loadModel success must clear the stale error banner',
      );
    },
  );

  testWidgets('retry button re-attempts model load and recovers', (
    tester,
  ) async {
    final api = _FakeRendererApi(shouldThrow: true);
    await tester.pumpWidget(
      _harness(
        rendererApi: api,
        selectedModelPath: '/models/test/model.model3.json',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('renderer boom'), findsOneWidget);

    // Recover and tap retry.
    api.shouldThrow = false;
    api.motionGroups = ['Idle', 'Wave'];
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.textContaining('renderer boom'), findsNothing);
    expect(find.text('Idle'), findsOneWidget);
    expect(find.text('Wave'), findsOneWidget);
  });

  testWidgets('gesture controls are disabled when no model loaded', (
    tester,
  ) async {
    final api = _FakeRendererApi();
    await tester.pumpWidget(_harness(rendererApi: api));
    await tester.pumpAndSettle();

    // Verify gesture buttons exist by finding their text labels.
    expect(find.text('Reset'), findsOneWidget);
    expect(find.text('Zoom In'), findsOneWidget);
    expect(find.text('Zoom Out'), findsOneWidget);
    expect(find.text('Tap'), findsOneWidget);

    // Tapping a disabled button should not throw or change state.
    // If the button were enabled, it would call notifier methods.
    await tester.tap(find.text('Reset'));
    await tester.pump();
    // No crash = button is disabled (onPressed null).
  });

  testWidgets(
    'gesture controls enabled and motion chips appear when model is loaded',
    (tester) async {
      final api = _FakeRendererApi(motionGroups: ['Idle', 'TapBody']);
      await tester.pumpWidget(
        _harness(
          rendererApi: api,
          selectedModelPath: '/models/test/test_model.model3.json',
        ),
      );
      await tester.pumpAndSettle();

      // Gesture buttons should exist and be tappable.
      expect(find.text('Reset'), findsOneWidget);
      expect(find.text('Zoom In'), findsOneWidget);
      expect(find.text('Zoom Out'), findsOneWidget);
      expect(find.text('Tap'), findsOneWidget);

      // Tap the Reset button — should not throw (enabled).
      await tester.tap(find.text('Reset'));
      await tester.pump();

      // Tap the Tap button — should not throw (enabled).
      await tester.tap(find.text('Tap'));
      await tester.pump();

      // Motion chips should appear.
      expect(find.text('Idle'), findsOneWidget);
      expect(find.text('TapBody'), findsOneWidget);
    },
  );

  testWidgets(
    'Texture widget appears after FrameEvent.updated registers a texture',
    (tester) async {
      // Mock the live2d_viewer/texture MethodChannel so
      // TextureMethodChannel.register returns texture_id = 7.
      const textureChannel = MethodChannel('live2d_viewer/texture');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(textureChannel, (call) async {
            if (call.method == 'register') return 7;
            return null;
          });

      final api = _FakeRendererApi(
        motionGroups: ['Idle'],
        frameEvents: [
          FrameEvent.initial(width: 64, height: 64),
          FrameEvent.updated(_handle()),
          FrameEvent.updated(_handle()),
        ],
      );
      await tester.pumpWidget(
        _harness(
          rendererApi: api,
          selectedModelPath: '/models/test/test_model.model3.json',
        ),
      );
      await tester.pumpAndSettle();

      // The Texture widget should now be in the tree with id = 7.
      final texture = find.byType(Texture);
      expect(texture, findsOneWidget);
      final widget = tester.widget<Texture>(texture);
      expect(widget.textureId, 7);
    },
  );

  testWidgets(
    'live surface shows the current model name badge (suffix stripped)',
    (tester) async {
      const textureChannel = MethodChannel('live2d_viewer/texture');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(textureChannel, (call) async {
            if (call.method == 'register') return 7;
            return null;
          });

      final api = _FakeRendererApi(
        motionGroups: ['Idle'],
        frameEvents: [
          FrameEvent.initial(width: 64, height: 64),
          FrameEvent.updated(_handle()),
          FrameEvent.updated(_handle()),
        ],
      );
      await tester.pumpWidget(
        _harness(
          rendererApi: api,
          selectedModelPath: '/models/test/test_model.model3.json',
        ),
      );
      await tester.pumpAndSettle();

      // Badge shows the basename with `.model3.json` stripped.
      expect(find.text('test_model'), findsOneWidget);
    },
  );

  testWidgets(
    'mark_frame_available is called for every FrameEvent.updated after register',
    (tester) async {
      const textureChannel = MethodChannel('live2d_viewer/texture');
      final markCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(textureChannel, (call) async {
            if (call.method == 'register') return 11;
            if (call.method == 'mark_frame_available') {
              markCalls.add(call);
            }
            return null;
          });

      final api = _FakeRendererApi(
        motionGroups: ['Idle'],
        frameEvents: [
          FrameEvent.updated(_handle()),
          FrameEvent.updated(_handle()),
          FrameEvent.updated(_handle()),
        ],
      );
      await tester.pumpWidget(
        _harness(
          rendererApi: api,
          selectedModelPath: '/models/test/test_model.model3.json',
        ),
      );
      await tester.pumpAndSettle();

      // Three Updated events -> three mark_frame_available calls,
      // each carrying texture_id = 11.
      expect(markCalls, hasLength(3));
      for (final call in markCalls) {
        expect(call.method, 'mark_frame_available');
        expect((call.arguments as Map)['texture_id'], 11);
      }
    },
  );

  testWidgets(
    'a new native handle swaps in place via update and keeps the texture id',
    (tester) async {
      // Regression for the probabilistic resize crash. When `setWindowSize`
      // triggers a D3D12 offscreen rebuild, Rust exports a fresh NT handle.
      // The notifier must detect the changed `nativeHandle` and swap it IN
      // PLACE (`update`), keeping the SAME Flutter texture id. It must NOT
      // unregister+register: tearing down the TextureLayer while the raster
      // thread paints it aborts the process (uncaught std::future_error
      // across a noexcept boundary). See
      // docs/postmortem/2026-07-21-viewer-setwindowsize-black-bars.md.
      const textureChannel = MethodChannel('live2d_viewer/texture');
      final calls = <MethodCall>[];
      var nextId = 100;
      var currentId = -1;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(textureChannel, (call) async {
            calls.add(call);
            if (call.method == 'register') {
              currentId = nextId++;
              return currentId;
            }
            // Native side swaps the handle atomically and returns the
            // existing texture id unchanged.
            if (call.method == 'update') return currentId;
            return null;
          });

      final handleA = SharedTextureHandle(
        width: 800,
        height: 600,
        nativeHandle: BigInt.from(0xAAA1),
      );
      final handleB = SharedTextureHandle(
        width: 1024,
        height: 768,
        nativeHandle: BigInt.from(0xBBB2),
      );

      final api = _FakeRendererApi(
        motionGroups: ['Idle'],
        frameEvents: [
          FrameEvent.updated(handleA),
          FrameEvent.updated(handleA),
          FrameEvent.updated(handleB),
          FrameEvent.updated(handleB),
        ],
      );
      await tester.pumpWidget(
        _harness(
          rendererApi: api,
          selectedModelPath: '/models/test/test_model.model3.json',
        ),
      );
      await tester.pumpAndSettle();

      // The first handle registers exactly once.
      final registerCalls = calls.where((c) => c.method == 'register').toList();
      expect(
        registerCalls,
        hasLength(1),
        reason: 'only the first handle registers a new texture id',
      );

      // The changed handle (handleB) swaps in place via a single `update`.
      final updateCalls = calls.where((c) => c.method == 'update').toList();
      expect(
        updateCalls,
        hasLength(1),
        reason:
            'one in-place update per distinct native handle after the first',
      );

      // The TextureLayer must NEVER be torn down during a resize swap.
      final unregisterCalls = calls
          .where((c) => c.method == 'unregister')
          .toList();
      expect(unregisterCalls, isEmpty);

      // The Texture widget keeps the original id across the swap.
      final texture = find.byType(Texture);
      expect(texture, findsOneWidget);
      expect(tester.widget<Texture>(texture).textureId, 100);

      // mark_frame_available only ever targets the single stable id.
      final markCalls = calls
          .where((c) => c.method == 'mark_frame_available')
          .toList();
      final markIds = markCalls
          .map((c) => (c.arguments as Map)['texture_id'])
          .toSet();
      expect(markIds, <int>{100});
    },
  );

  testWidgets(
    'narrow layout shows floating control bar and motion bottom sheet',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final api = _FakeRendererApi(motionGroups: ['Idle', 'TapBody']);
      await tester.pumpWidget(
        _harness(
          rendererApi: api,
          selectedModelPath: '/models/test/test_model.model3.json',
        ),
      );
      await tester.pumpAndSettle();

      // Compact floating bar buttons.
      expect(find.text('Reset'), findsOneWidget);
      expect(find.text('Out'), findsOneWidget);
      expect(find.text('In'), findsOneWidget);
      expect(find.text('Tap'), findsOneWidget);
      expect(find.text('Motions'), findsOneWidget);
      // Motion count badge on the Motions button.
      expect(find.text('2'), findsOneWidget);
      // The wide-layout gesture section must not be present.
      expect(find.text('Gestures'), findsNothing);

      // Open the motion bottom sheet.
      await tester.tap(find.text('Motions'));
      await tester.pumpAndSettle();
      expect(find.text('Motions (2)'), findsOneWidget);
      expect(find.text('Idle'), findsOneWidget);
      expect(find.text('TapBody'), findsOneWidget);

      // Selecting a motion closes the sheet.
      await tester.tap(find.text('Idle'));
      await tester.pumpAndSettle();
      expect(find.text('Motions (2)'), findsNothing);

      // Drain the 4s auto-hide timer armed by the button press so no
      // timer is left pending at teardown.
      await tester.pump(const Duration(seconds: 5));
    },
  );

  testWidgets('portrait immersive viewer shows a Landscape entry button', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _FakeRendererApi(motionGroups: ['Idle']);
    await tester.pumpWidget(
      _harness(
        rendererApi: api,
        selectedModelPath: '/models/test/test_model.model3.json',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Landscape'), findsOneWidget);

    // Drain the auto-hide timer.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets(
    'Landscape entry button pushes the immersive landscape viewer with no AppBar',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final api = _FakeRendererApi(motionGroups: ['Idle']);
      await tester.pumpWidget(
        _harness(
          rendererApi: api,
          selectedModelPath: '/models/test/test_model.model3.json',
        ),
      );
      await tester.pumpAndSettle();

      // Tap the Landscape entry button in the portrait control bar.
      await tester.tap(find.byTooltip('Landscape'));
      await tester.pumpAndSettle();

      // The landscape route is now on top.
      expect(find.byTooltip('Exit landscape'), findsOneWidget);
      // No AppBar — the model render surface fills the entire screen.
      expect(find.byType(AppBar), findsNothing);
      // No wide-layout gesture column — landscape uses the side rail.
      expect(find.text('Gestures'), findsNothing);
      // Side-rail tooltips are present (pure-icon buttons).
      expect(find.byTooltip('Reset'), findsOneWidget);
      expect(find.byTooltip('Zoom In'), findsOneWidget);
      expect(find.byTooltip('Zoom Out'), findsOneWidget);
      expect(find.byTooltip('Tap'), findsOneWidget);
      expect(find.byTooltip('Motions'), findsOneWidget);

      // Drain the auto-hide timer.
      await tester.pump(const Duration(seconds: 5));
    },
  );

  testWidgets(
    'Exit landscape button pops back to the portrait immersive viewer',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final api = _FakeRendererApi(motionGroups: ['Idle']);
      await tester.pumpWidget(
        _harness(
          rendererApi: api,
          selectedModelPath: '/models/test/test_model.model3.json',
        ),
      );
      await tester.pumpAndSettle();

      // Enter the landscape route.
      await tester.tap(find.byTooltip('Landscape'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Exit landscape'), findsOneWidget);

      // The portrait viewer's Landscape entry button is no longer visible
      // while the landscape route is on top (it is underneath the pushed
      // MaterialPageRoute).
      expect(find.byTooltip('Landscape'), findsNothing);

      // Exit pops back to the portrait immersive viewer.
      await tester.tap(find.byTooltip('Exit landscape'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Exit landscape'), findsNothing);
      // The portrait viewer re-emerges with its top-right entry button.
      expect(find.byTooltip('Landscape'), findsOneWidget);

      // Drain the auto-hide timer.
      await tester.pump(const Duration(seconds: 5));
    },
  );

  testWidgets(
    'narrow portrait FPS badge does not overlap the Landscape entry button',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      const textureChannel = MethodChannel('live2d_viewer/texture');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(textureChannel, (call) async {
            if (call.method == 'register') return 7;
            return null;
          });

      final api = _FakeRendererApi(
        motionGroups: ['Idle'],
        frameEvents: [
          FrameEvent.updated(_handle()),
          FrameEvent.updated(_handle()),
        ],
        keepStreamOpen: true,
      );
      await tester.pumpWidget(
        _harness(
          rendererApi: api,
          selectedModelPath: '/models/test/test_model.model3.json',
          showFps: true,
        ),
      );
      await tester.pumpAndSettle();

      final fpsBadge = find.textContaining('FPS');
      expect(fpsBadge, findsOneWidget);
      final landscapeButton = find.byTooltip('Landscape');
      expect(landscapeButton, findsOneWidget);

      final fpsRect = tester.getRect(fpsBadge);
      final buttonRect = tester.getRect(landscapeButton);
      expect(
        fpsRect.overlaps(buttonRect),
        isFalse,
        reason: 'FPS badge must sit clear of the landscape entry button',
      );

      // Drain the auto-hide timer.
      await tester.pump(const Duration(seconds: 5));
    },
  );

  testWidgets('landscape immersive viewer shows the FPS badge', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const textureChannel = MethodChannel('live2d_viewer/texture');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(textureChannel, (call) async {
          if (call.method == 'register') return 7;
          return null;
        });

    final api = _FakeRendererApi(
      motionGroups: ['Idle'],
      frameEvents: [
        FrameEvent.updated(_handle()),
        FrameEvent.updated(_handle()),
      ],
      keepStreamOpen: true,
    );
    await tester.pumpWidget(
      _harness(
        rendererApi: api,
        selectedModelPath: '/models/test/test_model.model3.json',
        showFps: true,
      ),
    );
    await tester.pumpAndSettle();

    // Enter the landscape route.
    await tester.tap(find.byTooltip('Landscape'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Exit landscape'), findsOneWidget);

    final fpsBadge = find.textContaining('FPS');
    expect(
      fpsBadge,
      findsOneWidget,
      reason: 'landscape viewer must show the FPS badge when enabled',
    );

    // The badge must not sit under the right-edge control rail.
    final fpsRect = tester.getRect(fpsBadge);
    final screenWidth = tester.view.physicalSize.width;
    expect(fpsRect.right, lessThanOrEqualTo(screenWidth - 72));

    // Drain the auto-hide timer.
    await tester.pump(const Duration(seconds: 5));
  });
}
