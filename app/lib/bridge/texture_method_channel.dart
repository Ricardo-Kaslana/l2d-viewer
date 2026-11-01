import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../src/rust/render/texture_export.dart';

/// Dart side of the `live2d_viewer/texture` MethodChannel.
///
/// Each Rust frame produces a fresh [SharedTextureHandle] pointing at a
/// D3D12 shared resource. The Windows runner owns a [TextureHandler]
/// that imports the NT handle into a D3D11 texture and registers it
/// with Flutter's [TextureRegistrar]. This class is the Dart↔native
/// glue: it sends the handle to the runner and receives the texture ID
/// that the Flutter `Texture` widget consumes.
///
/// Method protocol (kept identical on the C++ side):
///   * `register`  — args `{width:int, height:int, native_handle:int}`
///                   → result `int texture_id` (-1 on failure)
///   * `mark_frame_available` — args `{texture_id:int}` → result null
///   * `unregister` — args `{texture_id:int}` → result null
///
/// The channel name MUST stay in sync with the Windows runner
/// (`flutter_window.cpp`) and any Android equivalent.
class TextureMethodChannel {
  TextureMethodChannel._();
  static const String _channelName = 'live2d_viewer/texture';
  // Singleton: tests replace the underlying MethodChannel via
  // `setMockMethodCallHandler` rather than swapping this field.
  static final TextureMethodChannel instance = TextureMethodChannel._();

  final MethodChannel _channel = const MethodChannel(_channelName);

  /// Register a shared D3D11 texture with Flutter's texture registrar.
  ///
  /// Returns the texture ID on success, or -1 if the runner rejected
  /// the handle (e.g. `OpenSharedResource` failed on the C++ side).
  Future<int> register(SharedTextureHandle handle) async {
    // FRB generates `nativeHandle` as `BigInt` because Rust's `u64`
    // doesn't fit Dart's 53-bit `int`. The C++ runner reads the
    // value as either `int32_t` or `int64_t` from the Standard codec
    // (whichever Dart's `int` was encoded as).
    //
    // NT handles on Windows are 32-bit unsigned, but the kernel
    // routinely returns values in the `0x80000000..=0xFFFFFFFF`
    // range for shared resources minted by `ID3D12Device::CreateSharedHandle`.
    // Earlier code rejected anything >= 0x80000000 here, which silently
    // dropped every shared-resource handle the Rust side produced and
    // surfaced as -1 to the renderer — the Flutter `Texture` widget
    // never received an ID and the placeholder UI was shown.
    //
    // Accept the full 32-bit unsigned range. The C++ side handles
    // both Int32 and Int64 encodings; see `flutter_window.cpp`.
    final rawHandle = handle.nativeHandle;
    if (rawHandle < BigInt.from(0) || rawHandle > BigInt.from(0xFFFFFFFF)) {
      debugPrint(
        '[live2d/texture] register: handle 0x'
        '${rawHandle.toRadixString(16)} rejected: out of 32-bit range',
      );
      return -1;
    }
    final nativeHandle = rawHandle.toInt();
    debugPrint(
      '[live2d/texture] register: sending native_handle=0x'
      '${nativeHandle.toRadixString(16)} '
      '(${handle.width}x${handle.height})',
    );
    final result = await _channel.invokeMethod<int>(
      'register',
      <String, dynamic>{
        'width': handle.width,
        'height': handle.height,
        'native_handle': nativeHandle,
      },
    );
    final textureId = result ?? -1;
    debugPrint('[live2d/texture] register: returned texture_id=$textureId');
    return textureId;
  }

  /// Swap the shared NT handle in place, keeping the SAME Flutter texture id.
  ///
  /// The offscreen D3D12 texture is reallocated on every `setWindowSize`
  /// change, minting a brand-new NT handle. The naive fix — unregister the
  /// old texture id then register the new handle — tears down the Flutter
  /// `TextureLayer` (`UnregisterTexture` + `texture_variant_.reset()`) on the
  /// platform thread while the raster thread is mid-paint on that same layer,
  /// which makes the engine throw an uncaught `std::future_error` across a
  /// `noexcept` boundary → `terminate` → process abort (the probabilistic
  /// resize crash). Instead we hand the native side the new handle and it
  /// atomically swaps `{handle,width,height}` under its mutex, returning the
  /// existing texture id untouched. ANGLE re-opens the new handle on the next
  /// `ObtainDescriptor`; the `TextureLayer` is never unregistered.
  ///
  /// Returns the existing texture id, or -1 on failure.
  Future<int> update(SharedTextureHandle handle) async {
    final rawHandle = handle.nativeHandle;
    if (rawHandle < BigInt.from(0) || rawHandle > BigInt.from(0xFFFFFFFF)) {
      debugPrint(
        '[live2d/texture] update: handle 0x'
        '${rawHandle.toRadixString(16)} rejected: out of 32-bit range',
      );
      return -1;
    }
    final nativeHandle = rawHandle.toInt();
    debugPrint(
      '[live2d/texture] update: swapping native_handle=0x'
      '${nativeHandle.toRadixString(16)} '
      '(${handle.width}x${handle.height})',
    );
    final result = await _channel.invokeMethod<int>('update', <String, dynamic>{
      'width': handle.width,
      'height': handle.height,
      'native_handle': nativeHandle,
    });
    final textureId = result ?? -1;
    debugPrint('[live2d/texture] update: returned texture_id=$textureId');
    return textureId;
  }

  /// Notify Flutter that a new frame has been written to the texture.
  ///
  /// Call this on every `FrameEvent::Updated` after the initial
  /// `register`. The C++ side calls
  /// `TextureRegistrar::MarkTextureFrameAvailable`.
  Future<void> markFrameAvailable(int textureId) async {
    await _channel.invokeMethod<void>('mark_frame_available', <String, dynamic>{
      'texture_id': textureId,
    });
  }

  /// Unregister the texture from Flutter.
  ///
  /// Safe to call multiple times — the C++ side no-ops when the texture
  /// ID is -1 or already unregistered.
  Future<void> unregister(int textureId) async {
    await _channel.invokeMethod<void>('unregister', <String, dynamic>{
      'texture_id': textureId,
    });
  }
}
