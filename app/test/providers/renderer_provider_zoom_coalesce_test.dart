import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live2d_viewer/providers/renderer_provider.dart';

import '../support/stub_renderer_api.dart';

/// Stub that records zoom calls and yields once per call so pending
/// factors can accumulate while a call is "in flight".
class _RecordingZoomApi extends StubRendererApi {
  final List<double> zoomCalls = [];

  @override
  Future<void> zoom(double factor) async {
    zoomCalls.add(factor);
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('10 rapid zoom calls coalesce into fewer FRB calls with the same '
      'cumulative factor', () async {
    final api = _RecordingZoomApi();
    final container = ProviderContainer(
      overrides: [rendererApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(rendererProvider.notifier);

    final futures = <Future<void>>[];
    for (var i = 0; i < 10; i++) {
      futures.add(notifier.zoom(1.1));
    }
    await Future.wait(futures);

    expect(
      api.zoomCalls.length,
      lessThan(10),
      reason: 'in-flight coalescing must batch rapid zoom factors',
    );
    final cumulative = api.zoomCalls.fold<double>(1.0, (p, f) => p * f);
    expect(cumulative, closeTo(math.pow(1.1, 10).toDouble(), 1e-9));
  });
}
