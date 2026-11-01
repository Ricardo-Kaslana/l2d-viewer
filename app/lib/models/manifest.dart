import 'dart:convert';

class Manifest {
  Manifest({
    required this.id,
    required this.name,
    required this.moc3,
    required this.textures,
    required this.defaultIdle,
    required this.motionGroups,
    required this.expressions,
    this.physics,
    this.hitAreas,
    this.scale = 1.0,
    this.offset = const [0, 0],
  });

  final String id;
  final String name;
  final String moc3;
  final List<String> textures;
  final String defaultIdle;
  final List<MotionGroup> motionGroups;
  final List<ExpressionEntry> expressions;
  final String? physics;
  final String? hitAreas;
  final double scale;
  final List<int> offset;

  static Manifest fromJsonString(String raw) {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    if (j['schema'] != 'live2d-viewer.manifest/v1') {
      throw FormatException('unsupported manifest schema: ${j['schema']}');
    }
    final model = j['model'] as Map<String, dynamic>;
    final motion = j['motion'] as Map<String, dynamic>;
    final meta = (j['metadata'] as Map<String, dynamic>?) ?? const {};
    return Manifest(
      id: j['id'] as String,
      name: j['name'] as String,
      moc3: model['moc3'] as String,
      textures: (model['textures'] as List).cast<String>(),
      defaultIdle: motion['defaultIdle'] as String,
      motionGroups: (motion['groups'] as List)
          .cast<Map<String, dynamic>>()
          .map(
            (g) => MotionGroup(
              id: g['id'] as String,
              files: (g['files'] as List).cast<String>(),
            ),
          )
          .toList(),
      expressions: ((j['expression'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(
            (e) => ExpressionEntry(
              id: e['id'] as String,
              file: e['file'] as String,
            ),
          )
          .toList(),
      physics: j['physics'] as String?,
      hitAreas: j['hitAreas'] as String?,
      scale: (meta['scale'] as num?)?.toDouble() ?? 1.0,
      offset: (meta['offset'] as List?)?.cast<int>() ?? const [0, 0],
    );
  }
}

class MotionGroup {
  MotionGroup({required this.id, required this.files});
  final String id;
  final List<String> files;
}

class ExpressionEntry {
  ExpressionEntry({required this.id, required this.file});
  final String id;
  final String file;
}
