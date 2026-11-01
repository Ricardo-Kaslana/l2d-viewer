import 'package:flutter_test/flutter_test.dart';
import 'package:live2d_viewer/providers/renderer_provider.dart';

void main() {
  group('capRenderSize', () {
    test('returns input unchanged when within the cap', () {
      expect(capRenderSize(1080, 1600), (1080, 1600));
      expect(capRenderSize(1600, 900), (1600, 900));
    });

    test('caps the longer edge and preserves aspect (portrait)', () {
      final (w, h) = capRenderSize(1080, 2400);
      expect(h, 1600);
      expect(w, 720);
    });

    test('caps the longer edge and preserves aspect (landscape)', () {
      final (w, h) = capRenderSize(2400, 1080);
      expect(w, 1600);
      expect(h, 720);
    });

    test('respects a custom maxEdge', () {
      expect(capRenderSize(2000, 1000, maxEdge: 1000), (1000, 500));
    });

    test('square input caps both edges equally', () {
      expect(capRenderSize(3200, 3200), (1600, 1600));
    });

    test('zero and tiny sizes pass through untouched', () {
      expect(capRenderSize(0, 0), (0, 0));
      expect(capRenderSize(1, 1), (1, 1));
    });
  });
}
