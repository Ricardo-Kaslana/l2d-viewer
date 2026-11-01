import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live2d_viewer/data/remote_package_repo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RemotePackageRepo.verifyAndExtract', () {
    late Directory tmpBase;

    setUp(() {
      tmpBase = Directory.systemTemp.createTempSync('remote_repo_test_');
      // Stub path_provider so _modelsDir()/_tmpDir() resolve under
      // tmpBase instead of hitting the real platform channel.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (MethodCall call) async {
              if (call.method == 'getApplicationSupportDirectory') {
                return tmpBase.path;
              }
              return null;
            },
          );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      if (tmpBase.existsSync()) tmpBase.deleteSync(recursive: true);
    });

    List<int> makeZip(Map<String, String> files) {
      final archive = Archive();
      for (final entry in files.entries) {
        final data = entry.value.codeUnits;
        archive.addFile(ArchiveFile(entry.key, data.length, data));
      }
      return ZipEncoder().encode(archive);
    }

    String shaOf(List<int> bytes) => sha256.convert(bytes).toString();

    test('rejects zip entries with path traversal (..)', () async {
      final zipBytes = makeZip({'../evil.txt': 'pwned'});
      final zipFile = File('${tmpBase.path}/test.zip')
        ..writeAsBytesSync(zipBytes);

      final repo = RemotePackageRepo();

      expect(
        () => repo.verifyAndExtract(zipFile, shaOf(zipBytes), 'test_model'),
        throwsA(isA<UnsafeArchiveException>()),
      );
    });

    test('rejects zip entries with absolute paths', () async {
      final zipBytes = makeZip({'/etc/passwd': 'root:x:0:0'});
      final zipFile = File('${tmpBase.path}/test.zip')
        ..writeAsBytesSync(zipBytes);

      final repo = RemotePackageRepo();

      expect(
        () => repo.verifyAndExtract(zipFile, shaOf(zipBytes), 'test_model'),
        throwsA(isA<UnsafeArchiveException>()),
      );
    });

    test('rejects zip with backslash absolute path', () async {
      final zipBytes = makeZip({'\\Windows\\System32\\evil.dll': 'data'});
      final zipFile = File('${tmpBase.path}/test.zip')
        ..writeAsBytesSync(zipBytes);

      final repo = RemotePackageRepo();

      expect(
        () => repo.verifyAndExtract(zipFile, shaOf(zipBytes), 'test_model'),
        throwsA(isA<UnsafeArchiveException>()),
      );
    });

    test('rejects Windows drive-letter path (C:\\)', () async {
      final zipBytes = makeZip({'C:\\Windows\\evil.dll': 'data'});
      final zipFile = File('${tmpBase.path}/test.zip')
        ..writeAsBytesSync(zipBytes);

      final repo = RemotePackageRepo();

      expect(
        () => repo.verifyAndExtract(zipFile, shaOf(zipBytes), 'test_model'),
        throwsA(isA<UnsafeArchiveException>()),
      );
    });

    test('rejects Windows drive-letter path (C:/)', () async {
      final zipBytes = makeZip({'C:/evil.txt': 'data'});
      final zipFile = File('${tmpBase.path}/test.zip')
        ..writeAsBytesSync(zipBytes);

      final repo = RemotePackageRepo();

      expect(
        () => repo.verifyAndExtract(zipFile, shaOf(zipBytes), 'test_model'),
        throwsA(isA<UnsafeArchiveException>()),
      );
    });

    test(
      'accepts legitimate filename containing .. substring (foo..bar.png)',
      () async {
        // The old substring match would false-positive here. The new
        // segment-based check must accept `foo..bar.png` (no `..` path
        // segment) and reject only actual parent-dir references.
        final zipBytes = makeZip({'foo..bar.png': 'data'});
        final zipFile = File('${tmpBase.path}/test.zip')
          ..writeAsBytesSync(zipBytes);

        final repo = RemotePackageRepo();

        // Should NOT throw — it's a legitimate filename.
        await repo.verifyAndExtract(zipFile, shaOf(zipBytes), 'test_model');
      },
    );

    test('rejects parent-dir reference in nested path (a/../../etc)', () async {
      final zipBytes = makeZip({'a/../../etc/passwd': 'root:x:0:0'});
      final zipFile = File('${tmpBase.path}/test.zip')
        ..writeAsBytesSync(zipBytes);

      final repo = RemotePackageRepo();

      expect(
        () => repo.verifyAndExtract(zipFile, shaOf(zipBytes), 'test_model'),
        throwsA(isA<UnsafeArchiveException>()),
      );
    });

    test('rejects zip bomb (uncompressed total exceeds cap)', () async {
      // 5 entries × 256 MiB = 1.25 GiB uncompressed, just over the 1 GiB
      // default cap. Compressed size is tiny (all zeros). We use 256 MiB
      // entries instead of 1 GiB to keep the test allocation under 1.5 GiB
      // of resident memory.
      final big = List<int>.filled(1 << 28, 0); // 256 MiB
      final archive = Archive();
      for (var i = 0; i < 5; i++) {
        archive.addFile(ArchiveFile('part_$i.bin', big.length, big));
      }
      final zipBytes = ZipEncoder().encode(archive);
      final zipFile = File('${tmpBase.path}/bomb.zip')
        ..writeAsBytesSync(zipBytes);

      final repo = RemotePackageRepo();

      expect(
        () => repo.verifyAndExtract(zipFile, shaOf(zipBytes), 'bomb_model'),
        throwsA(isA<UnsafeArchiveException>()),
      );
    });

    test('rejects zip with oversized single entry', () async {
      // Single entry of 64 MiB, with a 32 MiB cap.
      final big = List<int>.filled(1 << 26, 0); // 64 MiB
      final archive = Archive()
        ..addFile(ArchiveFile('huge.bin', big.length, big));
      final zipBytes = ZipEncoder().encode(archive);
      final zipFile = File('${tmpBase.path}/single_big.zip')
        ..writeAsBytesSync(zipBytes);

      final repo = RemotePackageRepo();

      expect(
        () => repo.verifyAndExtract(
          zipFile,
          shaOf(zipBytes),
          'big_model',
          maxUncompressedBytes: 1 << 25, // 32 MiB cap
        ),
        throwsA(isA<UnsafeArchiveException>()),
      );
    });
    test('writes .l2dv-install.json sidecar with source metadata', () async {
      final zipBytes = makeZip({'model.model3.json': '{}'});
      final zipFile = File('${tmpBase.path}/test.zip')
        ..writeAsBytesSync(zipBytes);

      final repo = RemotePackageRepo();
      final installedAt = DateTime.utc(2026, 7, 25, 12, 30);

      final dest = await repo.verifyAndExtract(
        zipFile,
        shaOf(zipBytes),
        'meta_model',
        sourceUrl: 'https://example.com/pkgs/meta_model-1.0.0.zip',
        versionLabel: '1.0.0',
        installedAt: installedAt,
      );

      final sidecar = File('${dest.path}/$installMetaFileName');
      expect(sidecar.existsSync(), isTrue);
      final j = jsonDecode(sidecar.readAsStringSync()) as Map<String, dynamic>;
      expect(j['schema'], installMetaSchema);
      expect(j['packageId'], 'meta_model');
      expect(j['installedAt'], installedAt.toIso8601String());
      expect(j['sourceUrl'], 'https://example.com/pkgs/meta_model-1.0.0.zip');
      expect(j['version'], '1.0.0');
    });

    test('sidecar omits sourceUrl/version when not provided but always '
        'records installedAt', () async {
      final zipBytes = makeZip({'model.model3.json': '{}'});
      final zipFile = File('${tmpBase.path}/test.zip')
        ..writeAsBytesSync(zipBytes);

      final repo = RemotePackageRepo();
      final dest = await repo.verifyAndExtract(
        zipFile,
        shaOf(zipBytes),
        'meta_model2',
      );

      final sidecar = File('${dest.path}/$installMetaFileName');
      expect(sidecar.existsSync(), isTrue);
      final j = jsonDecode(sidecar.readAsStringSync()) as Map<String, dynamic>;
      expect(j['schema'], installMetaSchema);
      expect(j.containsKey('installedAt'), isTrue);
      expect(DateTime.tryParse(j['installedAt'] as String), isNotNull);
      expect(j.containsKey('sourceUrl'), isFalse);
      expect(j.containsKey('version'), isFalse);
    });

    test(
      'reinstall replaces existing install and leaves no .old dir',
      () async {
        final repo = RemotePackageRepo();

        final zip1 = makeZip({'model.model3.json': '{"v":1}', 'old.txt': 'x'});
        final f1 = File('${tmpBase.path}/v1.zip')..writeAsBytesSync(zip1);
        final dest = await repo.verifyAndExtract(f1, shaOf(zip1), 'reinst');
        expect(File('${dest.path}/old.txt').existsSync(), isTrue);

        final zip2 = makeZip({'model.model3.json': '{"v":2}'});
        final f2 = File('${tmpBase.path}/v2.zip')..writeAsBytesSync(zip2);
        final dest2 = await repo.verifyAndExtract(f2, shaOf(zip2), 'reinst');

        expect(dest2.path, dest.path);
        expect(
          File('${dest2.path}/model.model3.json').readAsStringSync(),
          '{"v":2}',
        );
        // Old content fully replaced, and the transient `.old` parking
        // directory must not survive a successful reinstall.
        expect(File('${dest2.path}/old.txt').existsSync(), isFalse);
        expect(Directory('${dest2.path}.old').existsSync(), isFalse);
      },
    );

    test('rejects malicious modelId from remote index', () async {
      final zipBytes = makeZip({'model.model3.json': '{}'});
      final zipFile = File('${tmpBase.path}/test.zip')
        ..writeAsBytesSync(zipBytes);

      final repo = RemotePackageRepo();

      for (final badId in ['../x', '..', 'a/b', r'a\b', 'C:evil', 'a\x00b']) {
        expect(
          () => repo.verifyAndExtract(zipFile, shaOf(zipBytes), badId),
          throwsA(isA<FileSystemException>()),
          reason: 'modelId "$badId" must be rejected',
        );
      }
      // The zip must not have been consumed/deleted by any rejected call.
      expect(zipFile.existsSync(), isTrue);
    });

    test('isInstalled rejects malicious modelId', () async {
      final repo = RemotePackageRepo();
      for (final badId in ['../x', 'a/b', 'C:evil']) {
        expect(
          () => repo.isInstalled(badId),
          throwsA(isA<FileSystemException>()),
          reason: 'modelId "$badId" must be rejected',
        );
      }
    });
  });

  group('RemotePackageRepo.deletePackage', () {
    late Directory tmpBase;

    setUp(() {
      tmpBase = Directory.systemTemp.createTempSync('remote_repo_delete_test_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (MethodCall call) async {
              if (call.method == 'getApplicationSupportDirectory') {
                return tmpBase.path;
              }
              return null;
            },
          );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      if (tmpBase.existsSync()) tmpBase.deleteSync(recursive: true);
    });

    /// Create a fake installed package directory under `models/`.
    void seedInstalled(
      String packageId, {
      Map<String, String> files = const {},
    }) {
      final dir = Directory('${tmpBase.path}/live2d-viewer/models/$packageId');
      dir.createSync(recursive: true);
      for (final e in files.entries) {
        // `createSync(recursive: true)` on the File ensures any
        // intermediate subdirectories (e.g. `textures/` for
        // `textures/a.png`) exist before the write. Without this,
        // Windows test runs fail with PathNotFoundException.
        File('${dir.path}/${e.key}').createSync(recursive: true);
        File('${dir.path}/${e.key}').writeAsStringSync(e.value);
      }
    }

    test('returns true and removes an installed package', () async {
      seedInstalled('model_a', files: {'manifest.json': '{}'});
      final repo = RemotePackageRepo();

      final removed = await repo.deletePackage('model_a');

      expect(removed, isTrue);
      expect(
        Directory('${tmpBase.path}/live2d-viewer/models/model_a').existsSync(),
        isFalse,
      );
    });

    test('returns false when the package is not installed', () async {
      // models dir exists but no model_a inside it.
      Directory(
        '${tmpBase.path}/live2d-viewer/models',
      ).createSync(recursive: true);
      final repo = RemotePackageRepo();

      final removed = await repo.deletePackage('model_a');

      expect(removed, isFalse);
    });

    test('recursively deletes all files inside the package dir', () async {
      seedInstalled(
        'model_a',
        files: {
          'manifest.json': '{}',
          'textures/a.png': 'x',
          'motions/idle.motion3.json': 'y',
        },
      );
      final repo = RemotePackageRepo();

      final removed = await repo.deletePackage('model_a');

      expect(removed, isTrue);
      expect(
        Directory('${tmpBase.path}/live2d-viewer/models/model_a').existsSync(),
        isFalse,
      );
    });

    test('rejects empty / whitespace packageId', () async {
      final repo = RemotePackageRepo();
      expect(() => repo.deletePackage(''), throwsA(isA<FileSystemException>()));
      expect(
        () => repo.deletePackage('   '),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('rejects packageId containing path separators', () async {
      final repo = RemotePackageRepo();
      expect(
        () => repo.deletePackage('a/b'),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        () => repo.deletePackage(r'a\b'),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('rejects packageId with parent-dir reference', () async {
      final repo = RemotePackageRepo();
      expect(
        () => repo.deletePackage('..'),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        () => repo.deletePackage('.'),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('rejects packageId with NUL byte / control chars', () async {
      final repo = RemotePackageRepo();
      expect(
        () => repo.deletePackage('a\x00b'),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        () => repo.deletePackage('a\nb'),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('rejects packageId starting with a Windows drive letter', () async {
      final repo = RemotePackageRepo();
      expect(
        () => repo.deletePackage('C:foo'),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        () => repo.deletePackage('d:bar'),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('refuses to delete a non-directory at models/<id>', () async {
      // Seed a *file* at models/model_a (corrupted install). On
      // Windows we cannot replace an existing directory with a file in
      // a single step, so the helper only creates the file path here
      // and skips the directory seeding.
      final file = File('${tmpBase.path}/live2d-viewer/models/model_a');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('not a dir');
      final repo = RemotePackageRepo();

      expect(
        () => repo.deletePackage('model_a'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('DownloadProgress', () {
    test('fraction computes correctly', () {
      const p = DownloadProgress(received: 50, total: 200);
      expect(p.fraction, 0.25);
    });

    test('fraction is 0 when total is 0', () {
      const p = DownloadProgress(received: 10, total: 0);
      expect(p.fraction, 0.0);
    });
  });
}
