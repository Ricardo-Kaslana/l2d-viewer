import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:live2d_viewer/data/remote_package_repo.dart';
import 'package:live2d_viewer/models/package_index.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpRoot;

  setUp(() {
    tmpRoot = Directory.systemTemp.createTempSync('download_test_');
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

  /// Build a [PackageVersion] with the given declared size.
  PackageVersion version({
    required int size,
    String url = 'packages/test.zip',
    String sha256 = 'deadbeef',
  }) {
    return PackageVersion(
      version: '1.0.0',
      url: url,
      sha256: sha256,
      size: size,
    );
  }

  group('RemotePackageRepo.downloadPackage size guards', () {
    test('rejects download up-front when declared size exceeds cap', () async {
      // A server that would happily stream 10 GiB; the cap fires first.
      final repo = RemotePackageRepo(
        client: _StreamingClient(
          (_) async => _streamed(Uint8List(1024), contentLength: 1024),
        ),
      );

      expect(
        () => repo.downloadPackage(
          version(size: 10 * 1024 * 1024 * 1024), // 10 GiB declared
          Uri.parse('https://example.test/'),
          maxDownloadBytes: 1 * 1024 * 1024 * 1024, // 1 GiB cap
        ),
        throwsA(isA<HttpException>()),
      );
    });

    test('aborts streaming when server sends more than the cap', () async {
      // Server omits Content-Length and streams 2 GiB of zeros. The
      // streaming cap (1 GiB) must abort before disk fills.
      final huge = Uint8List(2 * 1024 * 1024 * 1024);
      final repo = RemotePackageRepo(
        client: _StreamingClient(
          (_) async => _streamed(
            huge,
            // No contentLength — force the streaming-cap path.
          ),
        ),
      );

      expect(
        () => repo.downloadPackage(
          // Declare a small size so the up-front cap passes; the
          // streaming cap is what must fire.
          version(size: 1024),
          Uri.parse('https://example.test/'),
          maxDownloadBytes: 1 * 1024 * 1024 * 1024, // 1 GiB cap
        ),
        throwsA(isA<HttpException>()),
      );
    });

    test('rejects truncated download (on-disk size < declared)', () async {
      // Server streams 512 bytes but index declares 1024.
      final repo = RemotePackageRepo(
        client: _StreamingClient(
          (_) async => _streamed(Uint8List(512), contentLength: 512),
        ),
      );

      expect(
        () => repo.downloadPackage(
          version(size: 1024), // declared 1024, server sends 512
          Uri.parse('https://example.test/'),
        ),
        throwsA(isA<HttpException>()),
      );
    });

    test('rejects bloated download (on-disk size > declared)', () async {
      // Server streams 2048 bytes but index declares 1024.
      final repo = RemotePackageRepo(
        client: _StreamingClient(
          (_) async => _streamed(Uint8List(2048), contentLength: 2048),
        ),
      );

      expect(
        () => repo.downloadPackage(
          version(size: 1024), // declared 1024, server sends 2048
          Uri.parse('https://example.test/'),
        ),
        throwsA(isA<HttpException>()),
      );
    });

    test('successful download returns temp file of declared size', () async {
      final payload = utf8.encode('hello world');
      final repo = RemotePackageRepo(
        client: _StreamingClient(
          (_) async => _streamed(
            Uint8List.fromList(payload),
            contentLength: payload.length,
          ),
        ),
      );

      final file = await repo.downloadPackage(
        version(size: payload.length, sha256: 'ignore'),
        Uri.parse('https://example.test/'),
      );

      expect(await file.length(), payload.length);
    });

    test('sanitizes traversal in percent-encoded URL filename', () async {
      // Uri.pathSegments percent-decodes, so the last segment of this URL
      // is the string `../../evil.zip`. The temp file must still land
      // inside the managed tmp dir, never outside it.
      final payload = utf8.encode('payload');
      final repo = RemotePackageRepo(
        client: _StreamingClient(
          (_) async => _streamed(
            Uint8List.fromList(payload),
            contentLength: payload.length,
          ),
        ),
      );

      final file = await repo.downloadPackage(
        version(size: payload.length, url: 'packages/..%2F..%2Fevil.zip'),
        Uri.parse('https://example.test/'),
      );

      final tmpDir = Directory('${tmpRoot.path}/live2d-viewer/tmp');
      final normalized = File(
        file.path,
      ).absolute.uri.pathSegments.where((s) => s.isNotEmpty).toList();
      final tmpSegments = Directory(
        tmpDir.path,
      ).absolute.uri.pathSegments.where((s) => s.isNotEmpty).toList();
      expect(
        normalized.length,
        tmpSegments.length + 1,
        reason: 'file must be a direct child of the tmp dir',
      );
      for (var i = 0; i < tmpSegments.length; i++) {
        expect(normalized[i], tmpSegments[i]);
      }
      // A `..` *substring* is harmless (cf. foo..bar.png); only an exact
      // `..` segment would escape the tmp dir.
      expect(normalized.last, isNot('..'));
      expect(await file.length(), payload.length);
    });
  });
}

/// A minimal [http.BaseClient] subclass whose `send` invokes [handler].
/// Used to inject streaming responses into [RemotePackageRepo].
class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

/// Build a [http.StreamedResponse] that emits [bytes] once then completes.
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
