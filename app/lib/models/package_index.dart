import 'dart:convert';

class PackageIndex {
  PackageIndex({required this.packages});
  final List<PackageEntry> packages;

  static PackageIndex fromJsonString(String raw) {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    if (j['schema'] != 'live2d-viewer.pkg-index/v1') {
      throw FormatException('unsupported pkg-index schema');
    }
    return PackageIndex(
      packages: (j['packages'] as List)
          .cast<Map<String, dynamic>>()
          .map(PackageEntry.fromJson)
          .toList(),
    );
  }
}

class PackageEntry {
  PackageEntry({
    required this.id,
    required this.name,
    required this.latest,
    required this.versions,
  });
  final String id;
  final String name;
  final String latest;
  final List<PackageVersion> versions;

  static PackageEntry fromJson(Map<String, dynamic> j) => PackageEntry(
    id: j['id'] as String,
    name: j['name'] as String,
    latest: j['latest'] as String,
    versions: (j['versions'] as List)
        .cast<Map<String, dynamic>>()
        .map(PackageVersion.fromJson)
        .toList(),
  );
}

class PackageVersion {
  PackageVersion({
    required this.version,
    required this.url,
    required this.sha256,
    required this.size,
  });
  final String version, url, sha256;
  final int size;
  static PackageVersion fromJson(Map<String, dynamic> j) => PackageVersion(
    version: j['version'] as String,
    url: j['url'] as String,
    sha256: j['sha256'] as String,
    size: (j['size'] as num).toInt(),
  );
}
