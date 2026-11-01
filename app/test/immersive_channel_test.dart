import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live2d_viewer/bridge/immersive_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('enable sends method enable on immersive channel', () async {
    final calls = <MethodCall>[];
    const ch = MethodChannel('live2d_viewer/immersive');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (c) async {
          calls.add(c);
          return null;
        });
    await ImmersiveChannel(ch).enable();
    expect(calls.single.method, 'enable');
  });
}
