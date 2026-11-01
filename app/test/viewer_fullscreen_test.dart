import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:live2d_viewer/pages/viewer_page.dart';
import 'package:live2d_viewer/providers/model_provider.dart';
import 'package:live2d_viewer/providers/renderer_provider.dart';
import 'package:live2d_viewer/src/rust/render/frame_driver.dart';

class _FakeRendererApi implements RendererApi {
  @override
  Future<void> initialize() async {}
  @override
  Future<ModelLoadResult> loadModel(String path) async =>
      ModelLoadResult(motionGroups: ['Idle']);
  @override
  Future<void> triggerMotion(String group) async {}
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
  Future<void> panDelta(double dx, double dy, int w, int h) async {}
  @override
  Future<void> panEnd() async {}
  @override
  Future<void> resize(int width, int height) async {}
  @override
  Future<List<String>> getMotionGroups() async => ['Idle'];
  @override
  Future<void> setWindowSize(int width, int height) async {}
  @override
  Stream<FrameEvent> startFrameLoop() => StreamController<FrameEvent>().stream;
  @override
  Future<void> stopFrameLoop() async {}
  @override
  Future<(double, double, double, double)> getGestureState() async =>
      (1.0, 1.0, 0.0, 0.0);
  @override
  Future<void> setGestureState(
    double sx,
    double sy,
    double tx,
    double ty,
  ) async {}
  @override
  Future<void> attachSurface(int nativeWindow, int width, int height) async {}
  @override
  Future<void> detachSurface() async {}
}

class _EmptyModelRepository implements ModelRepository {
  @override
  Future<List<ManifestEntry>> listModels() async => const [];
}

class _PreSelectedModelNotifier extends ModelNotifier {
  _PreSelectedModelNotifier(super.repo, String path) {
    selectModel(path);
  }
}

void main() {
  late List<MethodCall> immersiveCalls;

  setUp(() {
    debugForceFullscreenAvailable = true;
    immersiveCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('live2d_viewer/immersive'),
          (call) async {
            immersiveCalls.add(call);
            return null;
          },
        );
  });

  tearDown(() {
    debugForceFullscreenAvailable = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('live2d_viewer/immersive'),
          null,
        );
  });

  Widget harness() {
    return ProviderScope(
      overrides: [
        rendererApiProvider.overrideWith((_) => _FakeRendererApi()),
        modelRepositoryProvider.overrideWith((_) => _EmptyModelRepository()),
        modelProvider.overrideWith(
          (_) => _PreSelectedModelNotifier(
            _EmptyModelRepository(),
            '/fake/model.model3.json',
          ),
        ),
      ],
      child: MaterialApp(home: const ViewerPage()),
    );
  }

  group('Windows fullscreen toggle button', () {
    testWidgets('fullscreen button exists in wide layout', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.fullscreen), findsOneWidget);
    });

    testWidgets('tapping fullscreen button sends enable then disable', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.fullscreen));
      await tester.pumpAndSettle();
      expect(immersiveCalls.map((c) => c.method), contains('enable'));

      // Hover left edge to reveal overlay panel with exit button.
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(5, 360));
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(const Offset(5, 360));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.fullscreen_exit));
      await tester.pumpAndSettle();
      expect(immersiveCalls.map((c) => c.method), contains('disable'));
    });
  });

  group('keyboard shortcuts', () {
    testWidgets('F11 toggles fullscreen', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pumpAndSettle();
      expect(immersiveCalls.map((c) => c.method), contains('enable'));

      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pumpAndSettle();
      expect(immersiveCalls.map((c) => c.method), contains('disable'));
    });

    testWidgets('Esc exits fullscreen only when fullscreen', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      // Esc when not fullscreen: no disable call.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(immersiveCalls, isEmpty);

      // Enter fullscreen, then Esc exits.
      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pumpAndSettle();
      immersiveCalls.clear();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(immersiveCalls.map((c) => c.method), contains('disable'));
    });
  });

  group('fullscreen layout', () {
    testWidgets('control column removed from main layout when fullscreen', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      // Before fullscreen: Gestures label visible in the control column.
      expect(find.text('Gestures'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pumpAndSettle();

      // After fullscreen: the static control column is gone.
      expect(find.text('Gestures'), findsNothing);
    });

    testWidgets('hover left edge shows overlay panel, leaving hides it', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      // Enter fullscreen.
      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pumpAndSettle();
      expect(find.text('Gestures'), findsNothing);

      // Hover the left-edge hot zone (x=5, y=center).
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(5, 360));
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(const Offset(5, 360));
      await tester.pumpAndSettle();

      // Overlay panel should now be visible.
      expect(find.text('Gestures'), findsOneWidget);

      // Move mouse far away from panel and hot zone.
      await gesture.moveTo(const Offset(700, 360));
      // Wait for the 600ms hide delay.
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();

      expect(find.text('Gestures'), findsNothing);
    });

    testWidgets('overlay panel has fullscreen exit button', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pumpAndSettle();

      // Hover to reveal panel.
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(5, 360));
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(const Offset(5, 360));
      await tester.pumpAndSettle();

      // Exit button in overlay panel.
      expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);

      // Tapping it exits fullscreen.
      await tester.tap(find.byIcon(Icons.fullscreen_exit));
      await tester.pumpAndSettle();
      expect(immersiveCalls.map((c) => c.method), contains('disable'));
      // Back to normal layout with static Gestures column.
      expect(find.text('Gestures'), findsOneWidget);
    });
  });
}
