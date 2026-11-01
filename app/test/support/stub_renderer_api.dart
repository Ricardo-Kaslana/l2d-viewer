import 'package:live2d_viewer/providers/renderer_provider.dart';
import 'package:live2d_viewer/src/rust/render/frame_driver.dart';

/// Test-only no-op renderer API.
class StubRendererApi implements RendererApi {
  const StubRendererApi();

  @override
  Future<void> initialize() async {}

  @override
  Future<ModelLoadResult> loadModel(String path) async {
    return const ModelLoadResult(motionGroups: []);
  }

  @override
  Future<void> triggerMotion(String group) async {}

  @override
  Future<void> resetGesture() async {}

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
  Future<List<String>> getMotionGroups() async => const [];

  @override
  Future<void> setWindowSize(int width, int height) async {}

  @override
  Future<void> setTargetFps(int fps) async {}

  @override
  Stream<FrameEvent> startFrameLoop() => const Stream<FrameEvent>.empty();

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
