import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:live2d_viewer/data/local_model_repo.dart';

void main() {
  group('LocalModelRepo.readInstallMeta', () {
    late Directory tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('local_model_repo_test_');
    });

    tearDown(() {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    });

    test('parses a valid sidecar', () async {
      File('${tmpDir.path}/.l2dv-install.json').writeAsStringSync(
        '{"schema":"live2d-viewer.install-meta/v1",'
        '"packageId":"haru",'
        '"installedAt":"2026-07-25T12:30:00.000Z",'
        '"sourceUrl":"https://example.com/haru.zip",'
        '"version":"1.2.0"}',
      );

      final meta = await LocalModelRepo().readInstallMeta(tmpDir);

      expect(meta, isNotNull);
      expect(meta!.installedAt, DateTime.utc(2026, 7, 25, 12, 30));
      expect(meta.sourceUrl, 'https://example.com/haru.zip');
      expect(meta.version, '1.2.0');
    });

    test('returns null when the sidecar is missing', () async {
      final meta = await LocalModelRepo().readInstallMeta(tmpDir);
      expect(meta, isNull);
    });

    test('returns null for corrupt JSON', () async {
      File(
        '${tmpDir.path}/.l2dv-install.json',
      ).writeAsStringSync('{not valid json');

      final meta = await LocalModelRepo().readInstallMeta(tmpDir);
      expect(meta, isNull);
    });

    test('tolerates missing optional fields', () async {
      File('${tmpDir.path}/.l2dv-install.json').writeAsStringSync(
        '{"schema":"live2d-viewer.install-meta/v1","packageId":"haru"}',
      );

      final meta = await LocalModelRepo().readInstallMeta(tmpDir);

      expect(meta, isNotNull);
      expect(meta!.installedAt, isNull);
      expect(meta.sourceUrl, isNull);
      expect(meta.version, isNull);
    });
  });

  group('LocalModelRepo.listInstalledModels', () {
    late Directory tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('local_model_repo_scan_');
    });

    tearDown(() {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    });

    Directory seedModelDir(String name) {
      final dir = Directory('${tmpDir.path}/$name')..createSync();
      File('${dir.path}/$name.model3.json').writeAsStringSync('{}');
      return dir;
    }

    test('deduplicates the same custom path listed twice', () async {
      seedModelDir('m1');

      // `Set<Directory>` deduplicates by identity (Directory does not
      // override ==), so the same path scanned twice used to yield two
      // entries. Dedup must be by normalized path string.
      final dirs = await LocalModelRepo().listInstalledModels(
        customPaths: [tmpDir.path, tmpDir.path],
      );

      expect(dirs, hasLength(1));
    });

    test(
      'deduplicates a model dir reachable via parent scan and directly',
      () async {
        final m1 = seedModelDir('m1');

        final dirs = await LocalModelRepo().listInstalledModels(
          customPaths: [tmpDir.path, m1.path],
        );

        expect(dirs, hasLength(1));
      },
    );

    test('deduplicates paths differing only by a trailing separator', () async {
      final m1 = seedModelDir('m1');

      final dirs = await LocalModelRepo().listInstalledModels(
        customPaths: [m1.path, '${m1.path}${Platform.pathSeparator}'],
      );

      expect(dirs, hasLength(1));
    });
  });
}
