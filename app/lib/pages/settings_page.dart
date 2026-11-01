import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/settings_repo.dart';
import '../providers/renderer_provider.dart';
import '../util/log.dart';
import '../widgets/storage_access.dart';

/// Settings page.
///
/// Manages the package source URL and custom model paths, persisted to
/// disk via [SettingsRepo].
///
/// When [embedded] is `true` (Windows wide shell) the page renders
/// without its own Scaffold/AppBar so it fills the shell's content pane;
/// on phones it is pushed as a standalone route with the full Scaffold.
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final TextEditingController _urlCtrl;
  late final TextEditingController _pathCtrl;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController();
    _pathCtrl = TextEditingController();
    // Load the persisted URL into the controller once settings are ready.
    ref.read(settingsRepoProvider.future).then((settings) {
      if (!mounted) return;
      _urlCtrl.text = settings.packageSourceUrl;
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _pathCtrl.dispose();
    super.dispose();
  }

  Future<void> _addPath() async {
    final path = _pathCtrl.text.trim();
    if (path.isEmpty) return;
    if (!await StorageAccess.ensure(context)) return;
    if (!mounted) return;
    await _addPathToList(path);
  }

  Future<void> _browseDirectory() async {
    if (!await StorageAccess.ensure(context)) return;
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select model directory',
    );
    if (result != null) {
      await _addPathToList(result);
    }
  }

  Future<void> _addPathToList(String path) async {
    final settings = await ref.read(settingsRepoProvider.future);
    if (settings.customModelPaths.contains(path)) return;
    settings.customModelPaths = [...settings.customModelPaths, path];
    try {
      await settings.save();
    } catch (e) {
      _showSaveError(e);
    }
    if (!mounted) return;
    _pathCtrl.clear();
    setState(() {});
  }

  Future<void> _removePath(String path) async {
    final settings = await ref.read(settingsRepoProvider.future);
    settings.customModelPaths = settings.customModelPaths
        .where((p) => p != path)
        .toList();
    try {
      await settings.save();
    } catch (e) {
      _showSaveError(e);
    }
    if (!mounted) return;
    setState(() {});
  }

  void _showSaveError(Object e) {
    debugLog('[settings] save failed: ${e.runtimeType}');
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Failed to save settings: $e')));
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(settingsRepoProvider);
    final theme = Theme.of(context);

    if (widget.embedded) {
      return settingsAsync.when(
        loading: () => _embeddedLoading(theme),
        error: (e, _) => _embeddedError(theme, e),
        data: (settings) => _embedded(settings, theme),
      );
    }

    return settingsAsync.when(
      loading: () => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: Center(child: Text('Failed to load settings: $e')),
      ),
      data: (settings) => _standalone(settings, theme),
    );
  }

  // ── Standalone (Android phones / standalone route) ────────────────

  Widget _standalone(SettingsRepo settings, ThemeData theme) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _content(settings, theme),
    );
  }

  // ── Embedded (Windows wide shell) ─────────────────────────────────

  Widget _embeddedLoading(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _embeddedHeader(theme),
        const Expanded(child: Center(child: CircularProgressIndicator())),
      ],
    );
  }

  Widget _embeddedError(ThemeData theme, Object e) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _embeddedHeader(theme),
        Expanded(child: Center(child: Text('Failed to load settings: $e'))),
      ],
    );
  }

  Widget _embedded(SettingsRepo settings, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _embeddedHeader(theme),
        Expanded(child: _content(settings, theme)),
      ],
    );
  }

  Widget _embeddedHeader(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Text('Settings', style: theme.textTheme.titleMedium),
    );
  }

  // ── Shared content ────────────────────────────────────────────────

  Widget _content(SettingsRepo settings, ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // ── Package source URL ──────────────────────────────────
        Text('Package source URL', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        TextField(
          controller: _urlCtrl,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'https://example.com/models/',
          ),
          onChanged: (v) {
            settings.packageSourceUrl = v;
            settings.save().catchError(_showSaveError);
          },
        ),
        const SizedBox(height: 8),
        Text(
          'Use the directory that contains index.json, or paste the full '
          'index.json URL. HTTPS is recommended; HTTP is intended for local '
          'development only.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),

        // ── Custom model paths ──────────────────────────────────
        Text('Custom model paths', style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        Text(
          'Add directories that contain model subdirectories with '
          'manifest.json files, or directories that themselves are '
          'a model directory (containing manifest.json directly).',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'On Android, browsing folders outside the app sandbox may ask for '
          '"All files access". Remote and app-managed models do not require '
          'it.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _pathCtrl,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: r'C:\Models\live2d',
                  isDense: true,
                ),
                onSubmitted: (_) => _addPath(),
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: 'Browse for folder',
              child: IconButton(
                icon: const Icon(Icons.folder_open),
                onPressed: _browseDirectory,
              ),
            ),
            FilledButton.icon(
              onPressed: _addPath,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (settings.customModelPaths.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: Text(
                'No custom paths added yet.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          )
        else
          ...settings.customModelPaths.map(
            (path) => Card(
              margin: const EdgeInsets.only(bottom: 4),
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.folder_outlined, size: 20),
                title: Text(
                  path,
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  icon: Icon(
                    Icons.delete_outline,
                    size: 18,
                    color: theme.colorScheme.error,
                  ),
                  tooltip: 'Remove path',
                  onPressed: () => _removePath(path),
                ),
              ),
            ),
          ),
        const SizedBox(height: 24),

        // ── Display ─────────────────────────────────────────────
        Text('Display', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Show FPS overlay'),
          subtitle: const Text('Display real-time frame rate in the viewer'),
          value: settings.showFps,
          onChanged: (v) {
            setState(() => settings.showFps = v);
            settings.save().catchError(_showSaveError);
          },
        ),
        const SizedBox(height: 16),
        Text('Frame rate cap', style: theme.textTheme.bodyLarge),
        const SizedBox(height: 4),
        Text(
          'Higher caps look smoother but use more GPU and battery. '
          'Unlimited removes the cap entirely.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<int>(
            segments: [
              for (final fps in kFpsCapOptions)
                ButtonSegment<int>(
                  value: fps,
                  label: Text(fps == 0 ? 'Unlimited' : '$fps'),
                ),
            ],
            selected: {settings.targetFps},
            showSelectedIcon: false,
            onSelectionChanged: (selection) {
              final v = selection.first;
              setState(() => settings.targetFps = v);
              settings.save().catchError(_showSaveError);
              // Apply live to a running Viewer loop.
              ref.read(rendererProvider.notifier).setTargetFps(v);
            },
          ),
        ),
        const SizedBox(height: 24),

        // ── Persistence notice ──────────────────────────────────
        Text(
          'Settings are persisted in your app support directory.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),

        // ── About ───────────────────────────────────────────────
        Text('About', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        Text(
          'Live2D Viewer is an unofficial, independent project. It is not '
          'affiliated with, endorsed by, sponsored by, or certified by '
          'Live2D Inc. "Live2D" and "Cubism" are trademarks or registered '
          'trademarks of their respective owners.\n\n'
          'The application source is available under the MIT License. '
          'No Live2D model assets are bundled with the app.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.description_outlined, size: 18),
            label: const Text('Open source licenses'),
            onPressed: () => showLicensePage(
              context: context,
              applicationName: 'Live2D Viewer',
            ),
          ),
        ),
      ],
    );
  }
}
