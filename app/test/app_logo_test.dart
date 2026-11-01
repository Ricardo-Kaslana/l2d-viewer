import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live2d_viewer/widgets/app_logo.dart';

void main() {
  testWidgets('renders at the requested size', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: AppLogo(size: 64))),
      ),
    );
    expect(tester.getSize(find.byType(AppLogo)), const Size(64, 64));
  });

  testWidgets('falls back to the theme primary colour', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorSchemeSeed: Colors.indigo),
        home: const Scaffold(body: Center(child: AppLogo())),
      ),
    );
    final paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(AppLogo),
        matching: find.byType(CustomPaint),
      ),
    );
    final painter = paint.painter;
    expect(painter, isA<AppLogoPainter>());
    expect(
      (painter! as AppLogoPainter).color,
      ThemeData(colorSchemeSeed: Colors.indigo).colorScheme.primary,
    );
  });

  group('mark geometry', () {
    final mark = AppLogoPainter.buildMark();

    test('spans the full 328-unit mark extent', () {
      expect(mark.getBounds(), const Rect.fromLTRB(0, 0, 328, 328));
    });

    test('keeps the three stacked layers', () {
      // Back layer's top-left corner is exposed, the front layer's
      // bottom-right corner is exposed, and the middle layer shows along
      // both steps between them.
      expect(mark.contains(const Offset(20, 20)), isTrue);
      expect(mark.contains(const Offset(300, 300)), isTrue);
      expect(mark.contains(const Offset(52, 52)), isTrue);
    });

    test('punches the mask hole through every layer', () {
      expect(mark.contains(const Offset(212, 212)), isFalse);
      expect(mark.contains(const Offset(212, 180)), isFalse);
      expect(mark.contains(const Offset(212, 250)), isFalse);
      // The rim around the hole is solid.
      expect(mark.contains(const Offset(212, 160)), isTrue);
    });
  });
}
