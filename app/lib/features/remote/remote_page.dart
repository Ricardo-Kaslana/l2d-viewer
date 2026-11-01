import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/package_index.dart';
import '../../providers/remote_provider.dart';

class RemotePage extends ConsumerStatefulWidget {
  const RemotePage({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends ConsumerState<RemotePage> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.toLowerCase());
    });
    Future.microtask(() => ref.read(remoteProvider.notifier).fetchIndex());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remote = ref.watch(remoteProvider);

    if (widget.embedded) {
      return _body(context, remote);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Remote Packages')),
      body: _body(context, remote),
    );
  }

  Widget _body(BuildContext context, RemoteState remote) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.embedded) const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search models...',
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              isDense: true,
            ),
          ),
        ),
        Expanded(child: _content(context, remote)),
      ],
    );
  }

  Widget _content(BuildContext context, RemoteState remote) {
    switch (remote.status) {
      case RemoteStatus.idle:
      case RemoteStatus.loading:
        return const Center(child: CircularProgressIndicator());

      case RemoteStatus.error:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.cloud_off,
                  size: 48,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 12),
                Text(
                  remote.errorMessage ?? 'Failed to load remote index',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                  onPressed: () =>
                      ref.read(remoteProvider.notifier).fetchIndex(),
                ),
              ],
            ),
          ),
        );

      case RemoteStatus.ready:
        final filtered = _query.isEmpty
            ? remote.packages
            : remote.packages
                  .where(
                    (p) =>
                        p.name.toLowerCase().contains(_query) ||
                        p.id.toLowerCase().contains(_query),
                  )
                  .toList();

        if (filtered.isEmpty) {
          return Center(
            child: Text(
              _query.isEmpty ? 'No packages available' : 'No matches',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: filtered.length,
          itemBuilder: (context, i) =>
              _packageTile(context, filtered[i], remote),
        );
    }
  }

  Widget _packageTile(
    BuildContext context,
    PackageEntry entry,
    RemoteState remote,
  ) {
    final installed = remote.installedIds.contains(entry.id);
    final download = remote.downloads[entry.id];
    final downloading = download != null && !download.failed;

    // A schema-valid index may still carry a package with an empty
    // `versions` list; `versions.first` would throw StateError and take
    // down the whole list build. Render such a tile degraded instead.
    final version = entry.versions.isEmpty
        ? null
        : entry.versions.firstWhere(
            (v) => v.version == entry.latest,
            orElse: () => entry.versions.first,
          );
    final sizeMb = version == null
        ? null
        : (version.size / (1024 * 1024)).toStringAsFixed(1);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Icon(
          installed ? Icons.check_circle : Icons.view_in_ar_outlined,
          color: installed
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        title: Text(entry.name),
        subtitle: downloading
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  LinearProgressIndicator(value: download.progress),
                  const SizedBox(height: 2),
                  Text(
                    download.extracting
                        ? 'Extracting...'
                        : '${(download.progress * 100).toInt()}%',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              )
            : Text(sizeMb == null ? 'No downloadable version' : '$sizeMb MB'),
        trailing: version == null && !installed
            ? null
            : _trailing(context, entry, installed, download),
      ),
    );
  }

  Widget? _trailing(
    BuildContext context,
    PackageEntry entry,
    bool installed,
    DownloadState? download,
  ) {
    if (installed) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.check_circle,
            color: Theme.of(context).colorScheme.primary,
            semanticLabel: 'Installed',
          ),
          // Delete is hidden while a download is in flight for this id
          // so the user cannot race the in-flight extract.
          if (download == null || download.failed)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete installed package',
              onPressed: () => _confirmAndDelete(context, entry),
            ),
        ],
      );
    }
    if (download != null && !download.failed) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (download != null && download.failed) {
      return IconButton(
        icon: Icon(
          Icons.error_outline,
          color: Theme.of(context).colorScheme.error,
        ),
        tooltip: download.error,
        onPressed: () =>
            ref.read(remoteProvider.notifier).downloadAndInstall(entry),
      );
    }
    return IconButton(
      icon: const Icon(Icons.download),
      onPressed: () =>
          ref.read(remoteProvider.notifier).downloadAndInstall(entry),
    );
  }

  /// Show a confirm dialog and, on confirm, call
  /// [RemoteNotifier.deletePackage]. The dialog is the last guard
  /// against accidental data loss — even though the optimistic UI
  /// update is reversible, deleting a multi-MB model directory is
  /// not something to do on a misclick.
  Future<void> _confirmAndDelete(
    BuildContext context,
    PackageEntry entry,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete installed package?'),
        content: Text(
          'This will permanently delete the local copy of '
          '"${entry.name}" from your device. You can re-download it '
          'from this list later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await ref.read(remoteProvider.notifier).deletePackage(entry);
  }
}
