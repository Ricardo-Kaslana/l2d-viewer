import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live2d_viewer/bridge/texture_method_channel.dart';
import 'package:live2d_viewer/src/rust/render/texture_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TextureMethodChannel channel;
  late List<MethodCall> calls;

  setUp(() {
    channel = TextureMethodChannel.instance;
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('live2d_viewer/texture'),
          (MethodCall call) async {
            calls.add(call);
            // Mimic the C++ runner: register mints a texture ID; update
            // swaps the handle in place and returns the existing ID.
            if (call.method == 'register' || call.method == 'update') {
              return 42;
            }
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

  test('register forwards width, height, and native_handle', () async {
    final handle = SharedTextureHandle(
      width: 1280,
      height: 720,
      nativeHandle: BigInt.from(0x1234),
    );

    final textureId = await channel.register(handle);

    expect(textureId, 42);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'register');
    final args = calls.single.arguments as Map<dynamic, dynamic>;
    expect(args['width'], 1280);
    expect(args['height'], 720);
    expect(args['native_handle'], 0x1234);
  });

  test('register accepts NT handles with the high bit set', () async {
    // Regression: `ID3D12Device::CreateSharedHandle` routinely returns
    // handles in the 0x80000000..=0xFFFFFFFF range. Earlier code
    // rejected anything >= 0x80000000 in `TextureMethodChannel.register`
    // and silently returned -1, leaving the Flutter `Texture` widget
    // without a texture ID and the renderer stuck on the placeholder UI.
    final handle = SharedTextureHandle(
      width: 512,
      height: 512,
      // A realistic high-bit NT handle value.
      nativeHandle: BigInt.from(0x80000040),
    );

    final textureId = await channel.register(handle);

    expect(textureId, 42, reason: 'high-bit NT handle should not be rejected');
    expect(calls, hasLength(1));
    final args = calls.single.arguments as Map<dynamic, dynamic>;
    // The exact wire encoding (Int32 vs Int64) is decided by the
    // Standard codec based on whether the value fits in signed int32,
    // but the runner must see the unsigned 32-bit value either way.
    final sent = args['native_handle'] as int;
    expect(sent & 0xFFFFFFFF, 0x80000040);
  });

  test('register accepts the maximum 32-bit unsigned handle', () async {
    final handle = SharedTextureHandle(
      width: 256,
      height: 256,
      nativeHandle: BigInt.from(0xFFFFFFFF),
    );

    final textureId = await channel.register(handle);
    expect(textureId, 42);
  });

  test('register rejects handles that exceed 32 bits', () async {
    final handle = SharedTextureHandle(
      width: 256,
      height: 256,
      // 2^32 — no longer a valid NT handle (handles are 32-bit even
      // on x64 Windows).
      nativeHandle: BigInt.from(0x100000000),
    );

    final textureId = await channel.register(handle);
    expect(textureId, -1);
    expect(
      calls,
      isEmpty,
      reason: 'runner must not be called for invalid handle',
    );
  });

  test(
    'update forwards width, height, and native_handle and keeps the id',
    () async {
      final handle = SharedTextureHandle(
        width: 1024,
        height: 768,
        nativeHandle: BigInt.from(0xBBB2),
      );

      final textureId = await channel.update(handle);

      expect(textureId, 42);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'update');
      final args = calls.single.arguments as Map<dynamic, dynamic>;
      expect(args['width'], 1024);
      expect(args['height'], 768);
      expect(args['native_handle'], 0xBBB2);
    },
  );

  test('update rejects handles that exceed 32 bits', () async {
    final handle = SharedTextureHandle(
      width: 256,
      height: 256,
      nativeHandle: BigInt.from(0x100000000),
    );

    final textureId = await channel.update(handle);
    expect(textureId, -1);
    expect(
      calls,
      isEmpty,
      reason: 'runner must not be called for invalid handle',
    );
  });

  test('register returns -1 when registrar rejects the handle', () async {
    // Override the mock to return -1 (the runner's failure sentinel).
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('live2d_viewer/texture'),
          (MethodCall call) async => -1,
        );

    final handle = SharedTextureHandle(
      width: 640,
      height: 480,
      nativeHandle: BigInt.from(99),
    );
    final textureId = await channel.register(handle);
    expect(textureId, -1);
  });

  test('markFrameAvailable forwards the texture_id', () async {
    await channel.markFrameAvailable(7);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'mark_frame_available');
    final args = calls.single.arguments as Map<dynamic, dynamic>;
    expect(args['texture_id'], 7);
  });

  test('unregister forwards the texture_id', () async {
    await channel.unregister(7);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'unregister');
    final args = calls.single.arguments as Map<dynamic, dynamic>;
    expect(args['texture_id'], 7);
  });

  test('unregister is safe to call before register', () async {
    // The Dart side never throws even if the native side no-ops.
    await channel.unregister(-1);
    expect(calls.single.method, 'unregister');
  });
}
