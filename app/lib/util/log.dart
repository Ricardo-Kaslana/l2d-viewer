import 'package:flutter/foundation.dart';

/// Debug-only logging. Release builds stay silent.
void debugLog(String message) {
  if (kDebugMode) debugPrint(message);
}

/// Log only the final path component; full local paths can contain usernames
/// or directory names that should not appear in diagnostics.
String pathBasename(String path) {
  if (path.isEmpty) return '<empty>';
  final parts = path.split(RegExp(r'[/\\]'));
  return parts.last.isEmpty ? '<root>' : parts.last;
}
