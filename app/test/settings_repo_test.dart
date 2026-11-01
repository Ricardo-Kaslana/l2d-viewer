import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live2d_viewer/data/settings_repo.dart';

/// Stub `path_provider`'s `getApplicationSupportDirectory` channel to
/// return [tmpRoot] synchronously. Tests must call this inside
/// `setUp` and remove the channel in `tearDown`.
void stubPathProvider(Directory tmpRoot) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            return tmpRoot.path;
          }
          return null;
        },
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('default package source url is empty', () {
    final s = SettingsRepo.empty();
    expect(s.packageSourceUrl, '');
  });

  test('default custom model paths is empty', () {
    final s = SettingsRepo.empty();
    expect(s.customModelPaths, isEmpty);
  });

  group('save() error propagation', () {
    late Directory tmpRoot;

    setUp(() async {
      tmpRoot = await Directory.systemTemp.createTemp('settings_test_');
      stubPathProvider(tmpRoot);
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      if (await tmpRoot.exists()) {
        await tmpRoot.delete(recursive: true);
      }
    });

    test(
      'save() propagates _writeToDisk errors instead of silently completing',
      () async {
        final settings = SettingsRepo.empty();
        settings.packageSourceUrl = 'http://example.test';

        // Pre-create the settings.json path as a *directory*. The next
        // `File.writeAsString` on it throws `FileSystemException`, which
        // before the fix was swallowed by `whenComplete` — the test
        // would hang on `expect(..., throwsA)`.
        final settingsDir = Directory('${tmpRoot.path}/live2d-viewer');
        await settingsDir.create(recursive: true);
        await Directory('${settingsDir.path}/settings.json').create();

        expect(settings.save(), throwsA(isA<FileSystemException>()));
      },
    );

    test(
      'coalesced save() calls all complete after the single write',
      () async {
        final settings = SettingsRepo.empty();
        settings.packageSourceUrl = 'http://example.test';

        // Two calls inside the debounce window. Before the fix the first
        // call's future was orphaned when its timer was cancelled and the
        // await below would hang forever.
        final first = settings.save();
        final second = settings.save();

        await Future.wait([first, second]).timeout(const Duration(seconds: 5));

        final file = File('${tmpRoot.path}/live2d-viewer/settings.json');
        expect(file.existsSync(), isTrue);
      },
    );

    test('coalesced save() calls all receive the write error', () async {
      final settings = SettingsRepo.empty();

      final settingsDir = Directory('${tmpRoot.path}/live2d-viewer');
      await settingsDir.create(recursive: true);
      await Directory('${settingsDir.path}/settings.json').create();

      final first = settings.save();
      final second = settings.save();

      await expectLater(first, throwsA(isA<FileSystemException>()));
      await expectLater(second, throwsA(isA<FileSystemException>()));
    });

    test('flush() completes pending coalesced save() immediately', () async {
      final settings = SettingsRepo.empty();
      settings.packageSourceUrl = 'http://example.test';

      final pending = settings.save();
      await settings.flush();
      // The coalesced save future must already be settled by flush.
      await pending.timeout(const Duration(seconds: 1));

      final file = File('${tmpRoot.path}/live2d-viewer/settings.json');
      expect(file.existsSync(), isTrue);
    });

    test('write is atomic: temp file renamed away, JSON stays valid', () async {
      final settings = SettingsRepo.empty();
      settings.packageSourceUrl = 'http://example.test';

      await settings.flush();

      final dir = Directory('${tmpRoot.path}/live2d-viewer');
      final names = dir.listSync().map((e) => e.uri.pathSegments.last);
      // A crash mid-write must never leave a truncated settings.json:
      // the write goes to a sibling temp file first and is renamed into
      // place. After a successful flush no temp file may linger.
      expect(names, contains('settings.json'));
      expect(
        names.where((n) => n != 'settings.json'),
        isEmpty,
        reason: 'no temp/backup files may remain after flush',
      );
      final content = File('${dir.path}/settings.json').readAsStringSync();
      expect(content, contains('http://example.test'));
    });
  });

  group('Library sort persistence', () {
    late Directory tmpRoot;

    setUp(() async {
      tmpRoot = await Directory.systemTemp.createTemp('settings_sort_');
      stubPathProvider(tmpRoot);
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      if (await tmpRoot.exists()) {
        await tmpRoot.delete(recursive: true);
      }
    });

    test(
      'librarySortField / librarySortDescending round-trip through disk',
      () async {
        final settings = SettingsRepo.empty();
        settings.librarySortField = 'addedAt';
        settings.librarySortDescending = true;

        await settings.flush();

        final reloaded = await SettingsRepo.load();
        expect(reloaded.librarySortField, 'addedAt');
        expect(reloaded.librarySortDescending, isTrue);
      },
    );

    test('unknown persisted field falls back to name', () async {
      final settingsDir = Directory('${tmpRoot.path}/live2d-viewer');
      await settingsDir.create(recursive: true);
      const bogus =
          '{"librarySortField": "wat", "librarySortDescending": true}';
      await File('${settingsDir.path}/settings.json').writeAsString(bogus);

      final reloaded = await SettingsRepo.load();
      expect(reloaded.librarySortField, 'name');
      // Descending flag still loaded from disk.
      expect(reloaded.librarySortDescending, isTrue);
    });

    test('default sort is name asc', () {
      final s = SettingsRepo.empty();
      expect(s.librarySortField, 'name');
      expect(s.librarySortDescending, isFalse);
    });
  });

  group('showFps persistence', () {
    late Directory tmpRoot;

    setUp(() async {
      tmpRoot = await Directory.systemTemp.createTemp('settings_fps_');
      stubPathProvider(tmpRoot);
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      if (await tmpRoot.exists()) {
        await tmpRoot.delete(recursive: true);
      }
    });

    test('showFps round-trips through disk', () async {
      final settings = SettingsRepo.empty();
      settings.showFps = true;
      await settings.flush();

      final reloaded = await SettingsRepo.load();
      expect(reloaded.showFps, isTrue);
    });

    test('default showFps is false', () {
      expect(SettingsRepo.empty().showFps, isFalse);
    });
  });

  group('targetFps persistence', () {
    late Directory tmpRoot;

    setUp(() async {
      tmpRoot = await Directory.systemTemp.createTemp('settings_targetfps_');
      stubPathProvider(tmpRoot);
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      if (await tmpRoot.exists()) {
        await tmpRoot.delete(recursive: true);
      }
    });

    test('default targetFps is 60', () {
      expect(SettingsRepo.empty().targetFps, 60);
    });

    test('each supported cap round-trips through disk', () async {
      for (final fps in kFpsCapOptions) {
        final settings = SettingsRepo.empty();
        settings.targetFps = fps;
        await settings.flush();

        final reloaded = await SettingsRepo.load();
        expect(reloaded.targetFps, fps, reason: 'cap $fps should persist');
      }
    });

    test('unknown persisted targetFps falls back to 60', () async {
      final settingsDir = Directory('${tmpRoot.path}/live2d-viewer');
      await settingsDir.create(recursive: true);
      await File(
        '${settingsDir.path}/settings.json',
      ).writeAsString('{"targetFps": 45}');

      final reloaded = await SettingsRepo.load();
      expect(reloaded.targetFps, 60);
    });

    test('missing targetFps field falls back to 60', () async {
      final settingsDir = Directory('${tmpRoot.path}/live2d-viewer');
      await settingsDir.create(recursive: true);
      await File(
        '${settingsDir.path}/settings.json',
      ).writeAsString('{"packageSourceUrl": "http://example.test"}');

      final reloaded = await SettingsRepo.load();
      expect(reloaded.targetFps, 60);
    });
  });
}
