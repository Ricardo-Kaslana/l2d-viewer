import 'package:flutter/services.dart';

class TextureAndroidChannel {
  TextureAndroidChannel._();
  static final TextureAndroidChannel instance = TextureAndroidChannel._();

  final MethodChannel _channel = const MethodChannel(
    'live2d_viewer/texture_android',
  );

  Future<({int textureId, int nativeWindow})> create(
    int width,
    int height,
  ) async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'create',
      {'width': width, 'height': height},
    );
    final map = result!;
    return (
      textureId: (map['texture_id'] as num).toInt(),
      nativeWindow: (map['native_window'] as num).toInt(),
    );
  }

  Future<void> resize(int width, int height) async {
    await _channel.invokeMethod<void>('resize', {
      'width': width,
      'height': height,
    });
  }

  Future<void> destroy() async {
    await _channel.invokeMethod<void>('destroy');
  }
}
