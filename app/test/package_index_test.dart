import 'package:flutter_test/flutter_test.dart';
import 'package:live2d_viewer/models/package_index.dart';

void main() {
  test('parses pkg-index v1', () {
    final raw =
        '{"schema":"live2d-viewer.pkg-index/v1","packages":['
        '{"id":"x.v1","name":"X","latest":"1.0.0","versions":['
        '{"version":"1.0.0","url":"https://e/x.zip","sha256":"abc","size":100}]}]}';
    final idx = PackageIndex.fromJsonString(raw);
    expect(idx.packages.first.id, 'x.v1');
    expect(idx.packages.first.latest, '1.0.0');
  });
}
