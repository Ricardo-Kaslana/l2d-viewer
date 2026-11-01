import '../providers/model_provider.dart';

/// Fields the Library list can be sorted by.
///
/// The string values are the on-disk persistence form used by
/// `SettingsRepo.librarySortField`. Adding a new option means:
/// extending this enum, updating the allow-list in `SettingsRepo.load`,
/// and adding a row in the Library sort menu.
enum LibrarySortField {
  name('name'),
  addedAt('addedAt'),
  source('source');

  const LibrarySortField(this.persistedKey);

  final String persistedKey;

  static LibrarySortField? fromPersistedKey(String? key) {
    if (key == null) return null;
    for (final v in LibrarySortField.values) {
      if (v.persistedKey == key) return v;
    }
    return null;
  }
}

/// Sort direction.
enum LibrarySortDirection { asc, desc }

/// A complete Library sort specification.
///
/// Equality is structural so two `LibrarySort` values compare equal iff
/// their field and direction match — required for the
/// "current selection gets the check mark" menu logic.
class LibrarySort {
  const LibrarySort({required this.field, required this.direction});

  /// Default ordering: alphabetical by name, ascending. Matches the
  /// historical behaviour baked into `LocalModelRepository.listModels`.
  static const LibrarySort defaultSort = LibrarySort(
    field: LibrarySortField.name,
    direction: LibrarySortDirection.asc,
  );

  final LibrarySortField field;
  final LibrarySortDirection direction;

  bool get isDescending => direction == LibrarySortDirection.desc;

  LibrarySort copyWith({
    LibrarySortField? field,
    LibrarySortDirection? direction,
  }) {
    return LibrarySort(
      field: field ?? this.field,
      direction: direction ?? this.direction,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is LibrarySort &&
        other.field == field &&
        other.direction == direction;
  }

  @override
  int get hashCode => Object.hash(field, direction);

  @override
  String toString() => 'LibrarySort(field: $field, direction: $direction)';
}

/// Sort [entries] according to [sort].
///
/// Returns a new list; the input is untouched. Ordering rules:
///
/// * **name** — case-insensitive `name` lexicographic.
/// * **addedAt** — by `addedAt` ascending chronologically. `null`
///   `addedAt` is treated as the earliest possible time so models
///   without a recorded timestamp sort first in asc / last in desc.
/// * **source** — by an explicit rank (`remote < custom`), then by name.
///
/// A secondary **name** tiebreak is always applied (ascending, even
/// when the primary sort is descending) so equal-key entries produce a
/// stable, user-friendly order rather than the scan order.
List<ManifestEntry> sortLibraryEntries(
  List<ManifestEntry> entries,
  LibrarySort sort,
) {
  final sorted = List<ManifestEntry>.of(entries);
  final descending = sort.isDescending;
  sorted.sort((a, b) {
    var cmp = _compareByField(a, b, sort.field);
    if (descending && cmp != 0) cmp = -cmp;
    if (cmp != 0) return cmp;
    // Secondary tiebreaks always ascending.
    final nameCmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    if (nameCmp != 0) return nameCmp;
    return a.directoryPath.compareTo(b.directoryPath);
  });
  return sorted;
}

int _compareByField(ManifestEntry a, ManifestEntry b, LibrarySortField field) {
  switch (field) {
    case LibrarySortField.name:
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    case LibrarySortField.addedAt:
      // Null addedAt sorts earliest.
      final at = a.addedAt;
      final bt = b.addedAt;
      if (at == null && bt == null) return 0;
      if (at == null) return -1;
      if (bt == null) return 1;
      return at.compareTo(bt);
    case LibrarySortField.source:
      // Primary: explicit source rank only. The name tiebreak is
      // intentionally NOT done here so that the caller's `descending`
      // negation doesn't accidentally invert the within-group name
      // order. The "always ascending" secondary tiebreak in the caller
      // handles same-source ordering.
      return _sourceRank(a.source).compareTo(_sourceRank(b.source));
  }
}

int _sourceRank(ModelSource source) => switch (source) {
  ModelSource.remote => 0,
  ModelSource.custom => 1,
};
