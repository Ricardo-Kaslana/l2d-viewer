import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Requests Android storage access only when the user opts into browsing an
/// external model folder.
///
/// The app-managed model directory and remote installs do not require broad
/// storage access. On Android 11+ this opens the "All files access" settings
/// screen; the caller should retry after the user returns to the app.
class StorageAccess {
  StorageAccess._();

  static const _channel = MethodChannel('live2d_viewer/storage_permission');

  static Future<bool> ensure(BuildContext context) async {
    if (!Platform.isAndroid) return true;
    if (await _hasAccess()) return true;
    if (!context.mounted) return false;

    final action = await showDialog<_StorageAction>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Storage permission required'),
        content: const Text(
          'To browse model folders outside the app sandbox, Live2D Viewer '
          'needs storage access.\n\n'
          'App-managed and remote models do not require this permission.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _StorageAction.grant),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (action != _StorageAction.grant) return false;

    final sdkInt = await _sdkInt();
    if (sdkInt >= 30) {
      final opened = await _invoke<bool>('openAllFilesAccessSettings') ?? false;
      if (!context.mounted) return false;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text(
            'Enable "All files access" for Live2D Viewer, then return and '
            'try again.',
          ),
        ),
      );
      return opened && await _hasAccess();
    }

    final status = await Permission.storage.request();
    if (!status.isGranted && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Storage access was not granted.')),
      );
    }
    return status.isGranted;
  }

  static Future<bool> _hasAccess() async {
    try {
      if (await _sdkInt() >= 30) {
        return await _invoke<bool>('hasAllFilesAccess') ?? false;
      }
      return await Permission.storage.isGranted;
    } on PlatformException catch (e) {
      debugPrint('[storage] permission check failed: ${e.code}');
      return true;
    } on MissingPluginException {
      // Widget tests and non-Android hosts do not register this channel.
      return true;
    }
  }

  static Future<int> _sdkInt() async {
    try {
      return await _invoke<int>('getSdkInt') ?? 30;
    } on PlatformException catch (e) {
      debugPrint('[storage] SDK lookup failed: ${e.code}');
      return 30;
    } on MissingPluginException {
      return 30;
    }
  }

  static Future<T?> _invoke<T>(String method) async {
    try {
      return await _channel.invokeMethod<T>(method);
    } on PlatformException catch (e) {
      debugPrint('[storage] $method failed: ${e.code}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

enum _StorageAction { grant }
