import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:live2d_viewer/data/remote_package_repo.dart';
import 'package:live2d_viewer/models/package_index.dart';

/// Error-branch coverage for the download/verify pipeline. The happy
/// paths and the archive/id safety checks live in
/// `remote_package_repo_test.dart` / `download_package_test.dart`; the
/// cases here previously had zero coverage.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpRoot;

  setUp(() {
    tmpRoot = Directory.systemTemp.createTempSync('remote_err_test_');
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
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (tmpRoot.existsSync()) tmpRoot.deleteSync(recursive: true);
  });

  group('verifyAndExtract checksum', () {
    test(
      'SHA-256 mismatch throws ChecksumException and installs nothing',
      () async {
        final archive = Archive()
          ..addFile(ArchiveFile('model.model3.json', 2, '{}'.codeUnits));
        final zipBytes = ZipEncoder().encode(archive);
        final zipFile = File('${tmpRoot.path}/tampered.zip')
          ..writeAsBytesSync(zipBytes);

        final repo = RemotePackageRepo();
        final wrongSha = sha256.convert('something else'.codeUnits).toString();

        await expectLater(
          () => repo.verifyAndExtract(zipFile, wrongSha, 'tampered_model'),
          throwsA(isA<ChecksumException>()),
        );

        // Nothing may reach the managed models directory: a tampered
        // package must fail closed before extraction, not after.
        final installDir = Directory(
          '${tmpRoot.path}/live2d-viewer/models/tampered_model',
        );
        expect(installDir.existsSync(), isFalse);
      },
    );

    test(
      'checksum comparison is case-insensitive on the expected side',
      () async {
        // Index generators may emit uppercase hex; the check must not
        // reject a byte-identical archive over hex casing.
        final archive = Archive()
          ..addFile(ArchiveFile('model.model3.json', 2, '{}'.codeUnits));
        final zipBytes = ZipEncoder().encode(archive);
        final zipFile = File('${tmpRoot.path}/cased.zip')
          ..writeAsBytesSync(zipBytes);

        final upperSha = sha256.convert(zipBytes).toString().toUpperCase();
        final repo = RemotePackageRepo();

        final dest = await repo.verifyAndExtract(
          zipFile,
          upperSha,
          'cased_model',
        );
        expect(File('${dest.path}/model.model3.json').existsSync(), isTrue);
      },
    );
  });

  group('HTTP error branches', () {
    test('fetchIndex throws HttpException on non-200', () async {
      final repo = RemotePackageRepo(
        client: _StreamingClient(
          (_) async => _streamed(Uint8List(0), statusCode: 404),
        ),
      );

      await expectLater(
        () => repo.fetchIndex(Uri.parse('https://host/pkgs/index.json')),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            contains('404'),
          ),
        ),
      );
    });

    test('downloadPackage throws HttpException on non-200', () async {
      final repo = RemotePackageRepo(
        client: _StreamingClient(
          (_) async => _streamed(Uint8List(0), statusCode: 500),
        ),
      );
      final version = PackageVersion(
        version: '1.0.0',
        url: 'packages/test.zip',
        sha256: 'deadbeef',
        size: 1024,
      );

      await expectLater(
        () => repo.downloadPackage(version, Uri.parse('https://host/pkgs/')),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            contains('500'),
          ),
        ),
      );
    });
  });
}

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

http.StreamedResponse _streamed(
  Uint8List bytes, {
  int? contentLength,
  int statusCode = 200,
}) {
  return http.StreamedResponse(
    Stream.value(bytes),
    statusCode,
    contentLength: contentLength,
  );
}
