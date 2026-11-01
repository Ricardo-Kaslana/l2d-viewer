import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:live2d_viewer/models/manifest.dart';

void main() {
  test('parses minimal v1 manifest', () {
    final raw = jsonEncode({
      'schema': 'live2d-viewer.manifest/v1',
      'id': 'shizuku.v1',
      'name': 'Shizuku',
      'author': 'x',
      'license': 'CC-BY-4.0',
      'requiredEditorVersion': '5.0.0+',
      'model': {
        'moc3': 'model.moc3',
        'textures': ['model.texture.png'],
      },
      'motion': {
        'defaultIdle': 'motion/idle.motion3.json',
        'groups': [
          {
            'id': 'idle',
            'files': ['motion/idle.motion3.json'],
          },
        ],
      },
      'expression': [
        {'id': 'smile', 'file': 'expression/smile.exp3.json'},
      ],
      'physics': 'physics/physics.json',
      'hitAreas': 'hit_areas.json',
      'metadata': {
        'scale': 1.0,
        'offset': [0, 0],
      },
    });
    final m = Manifest.fromJsonString(raw);
    expect(m.id, 'shizuku.v1');
    expect(m.expressions.length, 1);
    expect(m.defaultIdle, 'motion/idle.motion3.json');
  });

  test('metadata present but missing scale defaults to 1.0', () {
    final raw = jsonEncode({
      'schema': 'live2d-viewer.manifest/v1',
      'id': 'a.v1',
      'name': 'A',
      'model': {
        'moc3': 'model.moc3',
        'textures': ['t.png'],
      },
      'motion': {
        'defaultIdle': 'motion/idle.motion3.json',
        'groups': <Object>[],
      },
      'metadata': {
        'offset': [0, 0],
      },
    });
    final m = Manifest.fromJsonString(raw);
    expect(m.scale, 1.0);
  });

  test('missing metadata defaults scale to 1.0', () {
    final raw = jsonEncode({
      'schema': 'live2d-viewer.manifest/v1',
      'id': 'a.v1',
      'name': 'A',
      'model': {
        'moc3': 'model.moc3',
        'textures': ['t.png'],
      },
      'motion': {
        'defaultIdle': 'motion/idle.motion3.json',
        'groups': <Object>[],
      },
    });
    final m = Manifest.fromJsonString(raw);
    expect(m.scale, 1.0);
    expect(m.offset, [0, 0]);
  });
}
