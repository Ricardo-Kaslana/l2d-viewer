import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/package_index.dart';

/// Sidecar file written next to an installed model's content recording
/// when and from where it was installed.
const installMetaFileName = '.l2dv-install.json';

/// Content schema marker inside [installMetaFileName].
const installMetaSchema = 'live2d-viewer.install-meta/v1';

class DownloadProgress {
  const DownloadProgress({required this.received, required this.total});
  final int received;
  final int total;

  double get fraction => total > 0 ? received / total : 0.0;
}

class RemotePackageRepo {
  RemotePackageRepo({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  /// Timeout for the index fetch round-trip. A hung server must not
  /// leave the Remote page in a permanent loading state.
  static const indexTimeout = Duration(seconds: 15);

  /// Idle timeout between download chunks. Bounds how long a stalled
  /// connection can hold the download (and its temp file) open.
  static const downloadIdleTimeout = Duration(seconds: 30);

  Future<PackageIndex> fetchIndex(Uri url) async {
    final r = await _client
        .get(url)
        .timeout(
          indexTimeout,
          onTimeout: () =>
              throw HttpException('pkg-index fetch timed out: $url'),
        );
    if (r.statusCode != 200) {
      throw HttpException('pkg-index fetch failed: ${r.statusCode}');
    }
    return PackageIndex.fromJsonString(utf8.decode(r.bodyBytes));
  }

  /// Download a package zip, yielding progress events. Returns the temp file.
  ///
  /// Safety guards:
  ///   * Rejects the download up-front if [version.size] exceeds
  ///     [maxDownloadBytes] (default 2 GiB). This stops a malicious or
  ///     misconfigured server from streaming an unbounded body into the
  ///     app's temp directory before the SHA-256 check can reject it.
  ///   * Streams the body to a temp file, so memory usage is bounded by
  ///     the chunk size, not the total download.
  ///   * After the stream closes, verifies the on-disk file size matches
  ///     the announced [version.size] (the index's declared size). A
  ///     mismatch means the server lied or the connection was truncated;
  ///     we delete the partial file and throw.
  Future<File> downloadPackage(
    PackageVersion version,
    Uri baseUrl, {
    void Function(DownloadProgress)? onProgress,
    int maxDownloadBytes = 1 << 31, // 2 GiB
  }) async {
    // Up-front size cap. This is checked against the index's declared
    // size, not the HTTP Content-Length, so it fires even when the
    // server omits Content-Length.
    if (version.size > maxDownloadBytes) {
      throw HttpException(
        'download rejected: declared size $version.size exceeds '
        'max $maxDownloadBytes bytes',
      );
    }

    final url = baseUrl.resolve(version.url);
    final request = http.Request('GET', url);
    final response = await _client
        .send(request)
        .timeout(
          indexTimeout,
          onTimeout: () =>
              throw HttpException('download request timed out: $url'),
        );

    if (response.statusCode != 200) {
      throw HttpException('download failed: HTTP ${response.statusCode}');
    }

    final tmpDir = await _tmpDir();
    final tmpFile = File('${tmpDir.path}/${_fileNameFromUrl(url)}');
    final sink = tmpFile.openWrite();

    var received = 0;
    final total = response.contentLength ?? version.size;

    try {
      // Idle timeout: a stalled stream (no chunk for downloadIdleTimeout)
      // aborts the download instead of hanging the UI forever.
      await for (final chunk in response.stream.timeout(
        downloadIdleTimeout,
        onTimeout: (eventSink) {
          eventSink.addError(
            HttpException(
              'download stalled: no data for '
              '${downloadIdleTimeout.inSeconds}s from $url',
            ),
          );
          eventSink.close();
        },
      )) {
        sink.add(chunk);
        received += chunk.length;
        // Streaming size cap: protects against a server that omits
        // Content-Length and streams more than maxDownloadBytes.
        if (received > maxDownloadBytes) {
          throw HttpException(
            'download aborted: received $received bytes exceeds '
            'max $maxDownloadBytes',
          );
        }
        onProgress?.call(DownloadProgress(received: received, total: total));
      }
    } catch (e) {
      // Ensure the partial file is cleaned up on any streaming failure.
      await sink.close();
      try {
        await tmpFile.delete();
      } catch (_) {
        // Best effort — the file may already be gone or the close
        // above may have failed. Don't mask the original error.
      }
      rethrow;
    } finally {
      await sink.close();
    }

    // Post-stream integrity: the on-disk file must match the index's
    // declared size. A truncated stream (network drop, server kills
    // connection) leaves a smaller file; a lying server leaves a
    // larger one. Either way, SHA-256 would fail downstream — but
    // we catch it here with a clearer error and clean up the temp
    // file immediately.
    final actualSize = await tmpFile.length();
    if (actualSize != version.size) {
      try {
        await tmpFile.delete();
      } catch (_) {}
      throw HttpException(
        'download size mismatch: declared ${version.size} bytes, '
        'got $actualSize bytes',
      );
    }

    return tmpFile;
  }

  /// Verify SHA-256 and extract the zip to the managed models directory.
  ///
  /// Safety guards (zip bombs / path traversal):
  ///   * Rejects entries containing `..` *segments* (not substrings),
  ///     absolute POSIX/Windows paths, drive letters (`C:\` / `C:/`),
  ///     and any NUL / control character.
  ///   * Caps the total **uncompressed** size at [maxUncompressedBytes]
  ///     (default 1 GiB) and the per-entry size at the same bound, so a
  ///     zip bomb cannot exhaust device storage. The cap is checked on
  ///     archive metadata before any file is written.
  ///   * Extracts to a temp directory first, then atomically renames to
  ///     the final destination. Partial extracts are rolled back.
  ///
  /// [expectedSha256] is verified **before** any extraction, so a tampered
  /// archive is rejected without ever touching the filesystem.
  ///
  /// A `.l2dv-install.json` sidecar (schema
  /// `live2d-viewer.install-meta/v1`) recording [installedAt],
  /// [sourceUrl] and [versionLabel] is written into the temp directory
  /// *before* the atomic rename, so metadata and model content land
  /// together or not at all.
  ///
  /// The hash + extraction body runs in a background isolate via
  /// [Isolate.run] — hashing and decompressing a multi-hundred-MB zip
  /// on the main isolate froze the UI for seconds. Id validation and
  /// directory resolution (platform channels) stay on the main isolate.
  Future<Directory> verifyAndExtract(
    File zipFile,
    String expectedSha256,
    String modelId, {
    int maxUncompressedBytes = 1 << 30, // 1 GiB
    String? sourceUrl,
    String? versionLabel,
    DateTime? installedAt,
  }) async {
    // modelId comes from the remote index (attacker-controllable). It is
    // interpolated into the destination and temp-extract paths below, so
    // it must pass the same five-rule validation as deletePackage —
    // otherwise `destDir.delete(recursive: true)` + rename becomes an
    // arbitrary directory delete/write primitive.
    _validatePackageId(modelId);

    final modelsDir = await _modelsDir();
    final tmpDir = await _tmpDir();
    final args = _ExtractArgs(
      zipPath: zipFile.path,
      expectedSha256: expectedSha256,
      modelId: modelId,
      maxUncompressedBytes: maxUncompressedBytes,
      modelsDirPath: modelsDir.path,
      tmpDirPath: tmpDir.path,
      sourceUrl: sourceUrl,
      versionLabel: versionLabel,
      installedAtIso: (installedAt ?? DateTime.now()).toIso8601String(),
    );
    final destPath = await Isolate.run(() => _verifyAndExtractWorker(args));
    return Directory(destPath);
  }

  /// Validate a single zip entry name against traversal / absolute path
  /// / control-character attacks. Throws [UnsafeArchiveException] on the
  /// first violation.
  ///
  /// Rules (checked in order):
  ///   1. Reject NUL and other C0 control characters (escape hatch for
  ///      signed/unsigned confusion bugs in some decoders).
  ///   2. Reject Windows drive-letter prefixes `C:\` / `C:/`.
  ///   3. Reject any path that is absolute under POSIX (`/a`) or Windows
  ///      (`\a`, `\\server\share`).
  ///   4. Reject any path component equal to `..` (the parent-dir
  ///      reference). A *substring* match would false-positive on
  ///      legitimate names like `my..texture.png`, so we split on both
  ///      slashes and compare segments.
  static void _validateEntryName(String name) {
    // 1. Control characters (NUL, tab, newline, …).
    for (final ch in name.codeUnits) {
      if (ch < 0x20) {
        throw UnsafeArchiveException(
          'zip entry contains control character: $name',
        );
      }
    }

    // 2. Windows drive letter: `C:\` or `C:/` (case-insensitive).
    if (name.length >= 3) {
      final drive = name[0];
      final sep = name[1];
      final third = name[2];
      final isDriveLetter =
          (drive.codeUnitAt(0) >= 0x41 && drive.codeUnitAt(0) <= 0x5A) ||
          (drive.codeUnitAt(0) >= 0x61 && drive.codeUnitAt(0) <= 0x7A);
      final isSep = sep == ':' && (third == '\\' || third == '/');
      if (isDriveLetter && isSep) {
        throw UnsafeArchiveException(
          'zip entry uses Windows absolute path: $name',
        );
      }
    }

    // 3. Absolute paths (POSIX `/a`, Windows `\a` or UNC `\\a`).
    if (name.startsWith('/') || name.startsWith('\\')) {
      throw UnsafeArchiveException('zip entry uses absolute path: $name');
    }

    // 4. `..` *segment* (not substring — avoids false positives on
    //    `foo..bar.png`).
    final segments = name.split(RegExp(r'[/\\]'));
    for (final seg in segments) {
      if (seg == '..') {
        throw UnsafeArchiveException(
          'zip entry contains parent-dir reference: $name',
        );
      }
    }
  }

  /// Check if a model id is already installed in the managed models dir.
  Future<bool> isInstalled(String modelId) async {
    _validatePackageId(modelId);
    final modelsDir = await _modelsDir();
    return Directory('${modelsDir.path}/$modelId').exists();
  }

  /// Delete a previously-installed model directory by id.
  ///
  /// Returns `true` if a directory was removed, `false` if the id was not
  /// installed. Throws [FileSystemException] for invalid input (bad id)
  /// or filesystem failures during deletion.
  ///
  /// Safety guards (mirrors the four-rule `_validateEntryName` discipline):
  ///   1. Reject empty / whitespace-only ids.
  ///   2. Reject any id containing a path separator (`/` or `\`), a
  ///      NUL byte, or any other C0 control character. Also rejects
  ///      Windows drive-letter prefixes (`C:foo`).
  ///   3. Reject `.` and `..` (would target the models dir itself or
  ///      its parent — never a real model id).
  ///   4. Resolve the target under the managed models dir and verify
  ///      the canonical path is contained within it (defense against
  ///      symlink escapes or platform-specific separator quirks).
  ///   5. Require the target to be a directory — refuse to delete an
  ///      arbitrary file at that path.
  Future<bool> deletePackage(String packageId) async {
    _validatePackageId(packageId);

    final modelsDir = await _modelsDir();
    final modelsRoot = Directory(modelsDir.path).absolute;
    final target = Directory('${modelsRoot.path}/$packageId').absolute;

    // Containment check: the resolved target must be a direct child of
    // the models dir. We compare `Uri.pathSegments` rather than string
    // prefixes — `Uri.directory(...)` adds a trailing slash, so naive
    // `startsWith('${rootUri.path}/')` checks become `${rootUri.path}//`
    // (double slash) on Windows because `rootUri.path` already ends in
    // `/`, which never matches any real path. Comparing segments is
    // slash-agnostic and platform-normalized.
    //
    // `Uri.directory` on Windows may yield a leading empty segment when
    // the path is rendered as a directory URI (e.g. `/C:/...`); strip
    // any leading empties from both sides so the comparison is purely
    // structural.
    final rootUri = Uri.directory(modelsRoot.path);
    final targetUri = Uri.directory(target.path);
    final rootSegments = rootUri.pathSegments
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    final targetSegments = targetUri.pathSegments
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (targetSegments.length != rootSegments.length + 1) {
      throw FileSystemException(
        'packageId did not resolve to a direct child of models dir',
        '${rootUri.path} -> ${targetUri.path}',
      );
    }
    for (var i = 0; i < rootSegments.length; i++) {
      if (rootSegments[i] != targetSegments[i]) {
        throw FileSystemException(
          'resolved target escapes models dir',
          '${rootUri.path} -> ${targetUri.path}',
        );
      }
    }

    // Use `stat` rather than `target.exists()` first. `Directory
    // .exists()` returns `false` if the path exists but is a regular
    // file, which would silently treat a corrupted install (e.g. a
    // half-extract left a file instead of a directory) as a no-op
    // success instead of raising the "refusing to delete non-
    // directory" guard. `stat` works for both files and directories.
    final stat = await target.stat();
    if (stat.type == FileSystemEntityType.notFound) {
      return false;
    }
    if (stat.type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'refusing to delete non-directory at models/<id>',
        target.path,
      );
    }

    try {
      await target.delete(recursive: true);
      return true;
    } on FileSystemException catch (e) {
      // Pass `''` (not the absolute path) so the FileSystemException's
      // `path` field stays blank when surfaced to UI; the catch site
      // in RemoteNotifier only logs the full exception anyway.
      throw FileSystemException(
        'failed to delete package $packageId: ${e.message}',
        '',
      );
    }
  }

  /// Validate a package id before filesystem operations. Throws
  /// [FileSystemException] on the first violation. Mirrors the same
  /// discipline as `_validateEntryName` for zip entry names.
  static void _validatePackageId(String id) {
    if (id.isEmpty || id.trim().isEmpty) {
      throw FileSystemException('packageId must not be empty', id);
    }

    for (final ch in id.codeUnits) {
      if (ch < 0x20) {
        throw FileSystemException('packageId contains control character', id);
      }
    }

    if (id.contains('/') || id.contains('\\')) {
      throw FileSystemException(
        'packageId must not contain path separators',
        id,
      );
    }

    // Windows drive-letter prefix like `C:foo` would resolve to the
    // current drive root + `foo`, escaping the models dir. The
    // _modelsDir test runs on all platforms; reject unconditionally.
    if (id.length >= 2 && id[1] == ':') {
      final first = id.codeUnitAt(0);
      final isAlpha =
          (first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A);
      if (isAlpha) {
        throw FileSystemException(
          'packageId must not start with a drive letter',
          id,
        );
      }
    }

    if (id == '.' || id == '..') {
      throw FileSystemException('packageId must not be . or ..', id);
    }

    // Windows strips trailing `.` and ` ` (space) silently when
    // creating files/directories, so `evil.` and `evil` end up as the
    // same path on disk even though the strings differ. Reject these
    // so the caller cannot smuggle in a name that maps to a sibling
    // install they did not intend to remove / re-install.
    final lastChar = id.codeUnitAt(id.length - 1);
    if (lastChar == 0x2E /* `.` */ || lastChar == 0x20 /* ` ` */ ) {
      throw FileSystemException(
        'packageId must not end with . or space (Windows trims these silently)',
        id,
      );
    }
  }

  Future<Directory> _modelsDir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/live2d-viewer/models');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<Directory> _tmpDir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/live2d-viewer/tmp');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Derive a safe temp-file name from a download URL.
  ///
  /// `Uri.pathSegments` percent-decodes each segment, so a URL like
  /// `packages/..%2F..%2Fevil.zip` yields a last segment of
  /// `../../evil.zip` — using it verbatim would write outside the tmp
  /// dir before the SHA-256 check ever runs. Sanitize to a strict
  /// whitelist and fall back to a fixed name when nothing safe remains.
  static String _fileNameFromUrl(Uri url) {
    final segments = url.pathSegments.where((s) => s.isNotEmpty);
    final raw = segments.isEmpty ? '' : segments.last;
    final sanitized = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (sanitized.isEmpty || RegExp(r'^\.+$').hasMatch(sanitized)) {
      return 'download.zip';
    }
    return sanitized;
  }
}

/// Pure-data arguments for [_verifyAndExtractWorker]; everything is a
/// String/int so the object crosses the isolate boundary cheaply.
class _ExtractArgs {
  const _ExtractArgs({
    required this.zipPath,
    required this.expectedSha256,
    required this.modelId,
    required this.maxUncompressedBytes,
    required this.modelsDirPath,
    required this.tmpDirPath,
    required this.sourceUrl,
    required this.versionLabel,
    required this.installedAtIso,
  });

  final String zipPath;
  final String expectedSha256;
  final String modelId;
  final int maxUncompressedBytes;
  final String modelsDirPath;
  final String tmpDirPath;
  final String? sourceUrl;
  final String? versionLabel;
  final String installedAtIso;
}

/// Isolate worker for [RemotePackageRepo.verifyAndExtract]. Body moved
/// verbatim from the pre-isolate implementation: streaming SHA-256,
/// four-rule entry validation, dual zip-bomb guard, sidecar-before-rename
/// and `.old` rollback semantics are unchanged. Returns the destination
/// directory path.
Future<String> _verifyAndExtractWorker(_ExtractArgs a) async {
  final zipFile = File(a.zipPath);
  final modelId = a.modelId;
  final maxUncompressedBytes = a.maxUncompressedBytes;

  // Streaming SHA-256: hash the file in chunks instead of reading the
  // whole zip (up to 2 GiB) into the Dart heap — an OOM risk on
  // Android devices.
  final actualSha = (await sha256.bind(zipFile.openRead()).first).toString();
  // `toString()` yields lowercase hex; normalise the index-declared side
  // so an uppercase-hex index does not reject a byte-identical archive.
  if (actualSha != a.expectedSha256.toLowerCase()) {
    throw ChecksumException(
      // Do not include the absolute path of `$modelId`'s install
      // destination here — callers funnel this message into UI
      // banners that surface the user's filesystem layout. The full
      // sha256 + id is logged separately when this is caught.
      'SHA-256 mismatch (package id=$modelId)',
    );
  }

  // File-backed decode: entry contents are decompressed lazily one
  // entry at a time during extraction, not all at once in memory.
  final zipStream = InputFileStream(zipFile.path);
  late final Archive archive;
  try {
    archive = ZipDecoder().decodeStream(zipStream);
  } catch (e) {
    await zipStream.close();
    rethrow;
  }

  // Zip-bomb guard, first pass: sum *declared* uncompressed sizes
  // before writing anything. Cheap, catches honest-but-huge archives.
  var totalUncompressed = 0;
  for (final entry in archive) {
    totalUncompressed += entry.size;
    if (totalUncompressed > maxUncompressedBytes) {
      await zipStream.close();
      throw UnsafeArchiveException(
        'zip uncompressed size exceeds $maxUncompressedBytes bytes '
        '(zip bomb guard) for $modelId',
      );
    }
  }

  for (final entry in archive) {
    try {
      RemotePackageRepo._validateEntryName(entry.name);
    } catch (_) {
      await zipStream.close();
      rethrow;
    }
  }

  final destDir = Directory('${a.modelsDirPath}/$modelId');

  final tmpExtractDir = Directory('${a.tmpDirPath}/extract_$modelId');
  if (await tmpExtractDir.exists()) {
    await tmpExtractDir.delete(recursive: true);
  }
  await tmpExtractDir.create(recursive: true);

  try {
    // Zip-bomb guard, second pass: the header sizes checked above are
    // *declared* values a malicious archive can understate. Re-check
    // the actual decompressed length of every entry, per entry and
    // accumulated, before writing it to disk.
    var actualTotal = 0;
    for (final entry in archive) {
      final outPath = '${tmpExtractDir.path}/${entry.name}';
      if (entry.isFile) {
        final data = entry.content as List<int>;
        actualTotal += data.length;
        if (data.length > maxUncompressedBytes ||
            actualTotal > maxUncompressedBytes) {
          throw UnsafeArchiveException(
            'zip actual decompressed size exceeds $maxUncompressedBytes '
            'bytes (zip bomb guard, lied header) for $modelId',
          );
        }
        final outFile = File(outPath);
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(data);
      } else {
        await Directory(outPath).create(recursive: true);
      }
    }

    final meta = <String, dynamic>{
      'schema': installMetaSchema,
      'packageId': modelId,
      'installedAt': a.installedAtIso,
    };
    if (a.sourceUrl != null) meta['sourceUrl'] = a.sourceUrl;
    if (a.versionLabel != null) meta['version'] = a.versionLabel;
    await File(
      '${tmpExtractDir.path}/$installMetaFileName',
    ).writeAsString(jsonEncode(meta));

    // Reinstall must not lose the existing install on failure:
    // delete-then-rename has a window where the old version is gone
    // and the new one is not yet in place. Instead, park the old
    // directory at `.old`, rename the new one in, then drop `.old`.
    // If the final rename fails, restore the old directory.
    final oldDir = Directory('${destDir.path}.old');
    if (await oldDir.exists()) {
      await oldDir.delete(recursive: true);
    }
    var movedOldAside = false;
    if (await destDir.exists()) {
      await destDir.rename(oldDir.path);
      movedOldAside = true;
    }
    try {
      await tmpExtractDir.rename(destDir.path);
    } catch (e) {
      if (movedOldAside) {
        try {
          await oldDir.rename(destDir.path);
        } catch (_) {
          // Rollback failed too — surface the original error below;
          // the old content still exists at `.old`.
        }
      }
      rethrow;
    }
    if (movedOldAside && await oldDir.exists()) {
      await oldDir.delete(recursive: true);
    }
  } catch (e) {
    if (await tmpExtractDir.exists()) {
      await tmpExtractDir.delete(recursive: true);
    }
    rethrow;
  } finally {
    await zipStream.close();
    if (await zipFile.exists()) {
      await zipFile.delete();
    }
  }

  return destDir.path;
}

class HttpException implements Exception {
  HttpException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ChecksumException implements Exception {
  ChecksumException(this.message);
  final String message;
  @override
  String toString() => message;
}

class UnsafeArchiveException implements Exception {
  UnsafeArchiveException(this.message);
  final String message;
  @override
  String toString() => message;
}
