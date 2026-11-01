import 'package:flutter/material.dart';

/// The Live2D Viewer mark.
///
/// Three stacked rounded squares with a mask hole punched through them —
/// the same geometry as the app icon in `design/icon/`, drawn as a
/// single-colour glyph so it can sit on any surface and follow the
/// Material 3 theme.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 24, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: AppLogoPainter(color ?? Theme.of(context).colorScheme.primary),
      ),
    );
  }
}

class AppLogoPainter extends CustomPainter {
  const AppLogoPainter(this.color);

  final Color color;

  /// The mark's own extent in the 512-unit master, cropped to its bounds.
  static const double _extent = 328;
  static const double _corner = 64;
  static const Rect _back = Rect.fromLTRB(0, 0, 232, 232);
  static const Rect _middle = Rect.fromLTRB(48, 48, 280, 280);
  static const Rect _front = Rect.fromLTRB(96, 96, 328, 328);
  static const Offset _hole = Offset(212, 212);
  static const double _holeRadius = 46;

  /// The mark outline in local units: the three layers merged, with the
  /// mask hole punched through all of them.
  @visibleForTesting
  static Path buildMark() {
    final stack = Path.combine(
      PathOperation.union,
      Path.combine(PathOperation.union, _rounded(_back), _rounded(_middle)),
      _rounded(_front),
    );
    final hole = Path()
      ..addOval(Rect.fromCircle(center: _hole, radius: _holeRadius));
    return Path.combine(PathOperation.difference, stack, hole);
  }

  static Path _rounded(Rect rect) => Path()
    ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(_corner)));

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.shortestSide / _extent);
    canvas.drawPath(buildMark(), Paint()..color = color);
  }

  @override
  bool shouldRepaint(AppLogoPainter oldDelegate) => oldDelegate.color != color;
}
