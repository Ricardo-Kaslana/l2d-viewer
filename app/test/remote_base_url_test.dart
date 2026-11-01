import 'package:flutter_test/flutter_test.dart';

import 'package:live2d_viewer/providers/remote_provider.dart';

void main() {
  group('packageBaseUrl', () {
    test('appends a trailing slash without dropping path segments', () {
      final base = packageBaseUrl(Uri.parse('https://host/foo/bar'));
      expect(base.toString(), 'https://host/foo/bar/');
      expect(
        base.resolve('index.json').toString(),
        'https://host/foo/bar/index.json',
      );
      expect(base.resolve('m.zip').toString(), 'https://host/foo/bar/m.zip');
    });

    test('keeps an already-normalised directory URL unchanged', () {
      final base = packageBaseUrl(Uri.parse('https://host/foo/bar/'));
      expect(base.toString(), 'https://host/foo/bar/');
      expect(
        base.resolve('index.json').toString(),
        'https://host/foo/bar/index.json',
      );
    });

    test('handles a bare origin with no path', () {
      final base = packageBaseUrl(Uri.parse('https://host'));
      expect(base.resolve('index.json').toString(), 'https://host/index.json');
    });

    test('single path segment resolves under that segment', () {
      final base = packageBaseUrl(Uri.parse('http://192.168.1.2:8080/models'));
      expect(
        base.resolve('index.json').toString(),
        'http://192.168.1.2:8080/models/index.json',
      );
      expect(
        base.resolve('m.zip').toString(),
        'http://192.168.1.2:8080/models/m.zip',
      );
    });

    test('preserves the query-free authority (port, scheme)', () {
      final base = packageBaseUrl(Uri.parse('http://host:9000/a/b/c'));
      expect(base.toString(), 'http://host:9000/a/b/c/');
    });
  });

  group('parsePackageSource', () {
    test('accepts a directory base URL', () {
      final source = parsePackageSource('https://host/models');
      expect(source!.indexUrl.toString(), 'https://host/models/index.json');
      expect(source.baseUrl.toString(), 'https://host/models/');
    });

    test('accepts a full index.json URL without double-appending', () {
      final source = parsePackageSource('https://host/models/index.json');
      expect(source!.indexUrl.toString(), 'https://host/models/index.json');
      expect(source.baseUrl.toString(), 'https://host/models/');
    });

    test('accepts a bare origin', () {
      final source = parsePackageSource('https://host');
      expect(source!.indexUrl.toString(), 'https://host/index.json');
      expect(source.baseUrl.toString(), 'https://host');
    });

    test('rejects empty, relative and non-http(s) sources', () {
      expect(parsePackageSource(''), isNull);
      expect(parsePackageSource('not a url'), isNull);
      expect(parsePackageSource('/relative/index.json'), isNull);
      expect(parsePackageSource('ftp://host/models/'), isNull);
      expect(parsePackageSource('https://'), isNull);
    });
  });
}
