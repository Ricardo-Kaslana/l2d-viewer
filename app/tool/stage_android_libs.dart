import 'dart:io';

import 'package:crypto/crypto.dart';

/// Copies the cross-compiled Rust cdylib into the Android jniLibs directory
/// and verifies both files are byte-identical.
Future<void> main() async {
  final script = File.fromUri(Platform.script).absolute;
  final appDir = script.parent.parent;
  final repoRoot = appDir.parent;

  final source = File(
    '${repoRoot.path}/target/aarch64-linux-android/release/'
    'libmocari_host.so',
  );
  final destination = File(
    '${appDir.path}/android/app/src/main/jniLibs/arm64-v8a/'
    'libmocari_host.so',
  );

  if (!source.existsSync()) {
    stderr.writeln(
      'Missing cross-compiled library: ${source.path}\n'
      'Run: cargo build -p mocari_host --target aarch64-linux-android '
      '--release',
    );
    exitCode = 1;
    return;
  }

  await destination.parent.create(recursive: true);
  await source.copy(destination.path);

  final sourceHash = sha256.convert(await source.readAsBytes());
  final destinationHash = sha256.convert(await destination.readAsBytes());
  if (sourceHash != destinationHash) {
    stderr.writeln(
      'SHA-256 mismatch after staging:\n'
      '  source:      $sourceHash\n'
      '  destination: $destinationHash',
    );
    exitCode = 1;
    return;
  }

  stdout.writeln('Staged ${destination.path}');
  stdout.writeln('SHA-256: $destinationHash');
}
