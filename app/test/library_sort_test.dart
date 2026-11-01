import 'package:flutter_test/flutter_test.dart';

import 'package:live2d_viewer/data/library_sort.dart';
import 'package:live2d_viewer/providers/model_provider.dart';

ManifestEntry _entry({
  required String name,
  required String dir,
  DateTime? addedAt,
  ModelSource source = ModelSource.custom,
}) {
  return ManifestEntry(
    id: name,
    name: name,
    directoryPath: dir,
    source: source,
    addedAt: addedAt,
  );
}

void main() {
  group('LibrarySort', () {
    test('default sort is name asc', () {
      expect(
        LibrarySort.defaultSort,
        const LibrarySort(
          field: LibrarySortField.name,
          direction: LibrarySortDirection.asc,
        ),
      );
      expect(LibrarySort.defaultSort.isDescending, isFalse);
    });

    test('copyWith preserves unspecified fields', () {
      const sort = LibrarySort(
        field: LibrarySortField.name,
        direction: LibrarySortDirection.asc,
      );
      expect(
        sort.copyWith(direction: LibrarySortDirection.desc),
        const LibrarySort(
          field: LibrarySortField.name,
          direction: LibrarySortDirection.desc,
        ),
      );
      expect(
        sort.copyWith(field: LibrarySortField.source),
        const LibrarySort(
          field: LibrarySortField.source,
          direction: LibrarySortDirection.asc,
        ),
      );
    });

    test('equality is structural', () {
      expect(
        const LibrarySort(
          field: LibrarySortField.addedAt,
          direction: LibrarySortDirection.desc,
        ),
        const LibrarySort(
          field: LibrarySortField.addedAt,
          direction: LibrarySortDirection.desc,
        ),
      );
      expect(
        const LibrarySort(
              field: LibrarySortField.addedAt,
              direction: LibrarySortDirection.asc,
            ) ==
            const LibrarySort(
              field: LibrarySortField.addedAt,
              direction: LibrarySortDirection.desc,
            ),
        isFalse,
      );
    });
  });

  group('LibrarySortField.fromPersistedKey', () {
    test('maps valid keys', () {
      expect(LibrarySortField.fromPersistedKey('name'), LibrarySortField.name);
      expect(
        LibrarySortField.fromPersistedKey('addedAt'),
        LibrarySortField.addedAt,
      );
      expect(
        LibrarySortField.fromPersistedKey('source'),
        LibrarySortField.source,
      );
    });

    test('returns null for unknown / missing keys', () {
      expect(LibrarySortField.fromPersistedKey('bogus'), isNull);
      expect(LibrarySortField.fromPersistedKey(null), isNull);
    });
  });

  group('sortLibraryEntries', () {
    final entries = <ManifestEntry>[
      _entry(
        name: 'Haru',
        dir: '/managed/haru',
        addedAt: DateTime(2026, 7, 25),
        source: ModelSource.remote,
      ),
      _entry(
        name: 'Airi',
        dir: '/managed/airi',
        addedAt: DateTime(2026, 7, 22),
        source: ModelSource.remote,
      ),
      _entry(
        name: 'Zeta',
        dir: '/custom/zeta',
        addedAt: DateTime(2026, 7, 26),
        source: ModelSource.custom,
      ),
      _entry(
        name: 'Boa',
        dir: '/managed/boa',
        addedAt: DateTime(2026, 7, 20),
        source: ModelSource.remote,
      ),
    ];

    test('name asc sorts case-insensitively', () {
      const sort = LibrarySort(
        field: LibrarySortField.name,
        direction: LibrarySortDirection.asc,
      );
      final sorted = sortLibraryEntries(entries, sort);
      expect(sorted.map((e) => e.name).toList(), [
        'Airi',
        'Boa',
        'Haru',
        'Zeta',
      ]);
    });

    test('name desc reverses primary, keeps name asc as tiebreak', () {
      const sort = LibrarySort(
        field: LibrarySortField.name,
        direction: LibrarySortDirection.desc,
      );
      final sorted = sortLibraryEntries(entries, sort);
      expect(sorted.map((e) => e.name).toList(), [
        'Zeta',
        'Haru',
        'Boa',
        'Airi',
      ]);
    });

    test('addedAt asc puts earliest first; null addedAt sorts first', () {
      const sort = LibrarySort(
        field: LibrarySortField.addedAt,
        direction: LibrarySortDirection.asc,
      );
      final sorted = sortLibraryEntries(entries, sort);
      expect(sorted.map((e) => e.name).toList(), [
        'Boa',
        'Airi',
        'Haru',
        'Zeta',
      ]);

      // Entries with null addedAt sort before any dated entry.
      final withNull = List<ManifestEntry>.of(entries)
        ..add(_entry(name: 'NullTime', dir: '/x/null'));
      final sortedNull = sortLibraryEntries(withNull, sort);
      expect(sortedNull.first.name, 'NullTime');
    });

    test('addedAt desc reverses primary; null addedAt goes last', () {
      const sort = LibrarySort(
        field: LibrarySortField.addedAt,
        direction: LibrarySortDirection.desc,
      );
      final sorted = sortLibraryEntries(entries, sort);
      expect(sorted.map((e) => e.name).toList(), [
        'Zeta',
        'Haru',
        'Airi',
        'Boa',
      ]);

      final withNull = List<ManifestEntry>.of(entries)
        ..add(_entry(name: 'NullTime', dir: '/x/null'));
      final sortedNull = sortLibraryEntries(withNull, sort);
      expect(sortedNull.last.name, 'NullTime');
    });

    test('source asc groups by source rank then by name', () {
      const sort = LibrarySort(
        field: LibrarySortField.source,
        direction: LibrarySortDirection.asc,
      );
      final sorted = sortLibraryEntries(entries, sort);
      // remote (Airi, Boa, Haru) < custom (Zeta)
      expect(sorted.map((e) => e.name).toList(), [
        'Airi',
        'Boa',
        'Haru',
        'Zeta',
      ]);
    });

    test('source desc reverses primary group, name tiebreak still asc', () {
      const sort = LibrarySort(
        field: LibrarySortField.source,
        direction: LibrarySortDirection.desc,
      );
      final sorted = sortLibraryEntries(entries, sort);
      // custom (Zeta) > remote (Airi, Boa, Haru)
      expect(sorted.map((e) => e.name).toList(), [
        'Zeta',
        'Airi',
        'Boa',
        'Haru',
      ]);
    });

    test('returns a new list; input untouched', () {
      const sort = LibrarySort(
        field: LibrarySortField.name,
        direction: LibrarySortDirection.asc,
      );
      final inputOrder = entries.map((e) => e.name).toList();
      sortLibraryEntries(entries, sort);
      expect(entries.map((e) => e.name).toList(), inputOrder);
    });

    test('two models with same name but different dir are stable', () {
      final dupes = <ManifestEntry>[
        _entry(name: 'Same', dir: '/a'),
        _entry(name: 'Same', dir: '/b'),
      ];
      const sort = LibrarySort(
        field: LibrarySortField.name,
        direction: LibrarySortDirection.asc,
      );
      final sorted = sortLibraryEntries(dupes, sort);
      expect(sorted.map((e) => e.directoryPath).toList(), ['/a', '/b']);
    });
  });
}
