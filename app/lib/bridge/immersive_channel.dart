import 'package:flutter/services.dart';

class ImmersiveChannel {
  ImmersiveChannel(this._channel);
  final MethodChannel _channel;

  Future<void> enable() => _channel.invokeMethod<void>('enable');
  Future<void> disable() => _channel.invokeMethod<void>('disable');
}
