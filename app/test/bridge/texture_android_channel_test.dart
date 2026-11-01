import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live2d_viewer/bridge/texture_android_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('live2d_viewer/texture_android');
  final log = <MethodCall>[];

  setUp(() {
    log.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          log.add(call);
          switch (call.method) {
            case 'create':
              return {'texture_id': 42, 'native_window': 12345};
            case 'resize':
            case 'destroy':
              return null;
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('create returns textureId and nativeWindow', () async {
    final result = await TextureAndroidChannel.instance.create(1080, 1920);
    expect(result.textureId, 42);
    expect(result.nativeWindow, 12345);
    expect(log.single.method, 'create');
    expect(log.single.arguments, {'width': 1080, 'height': 1920});
  });

  test('resize sends width and height', () async {
    await TextureAndroidChannel.instance.resize(720, 1280);
    expect(log.single.method, 'resize');
    expect(log.single.arguments, {'width': 720, 'height': 1280});
  });

  test('destroy sends no args', () async {
    await TextureAndroidChannel.instance.destroy();
    expect(log.single.method, 'destroy');
  });
}
