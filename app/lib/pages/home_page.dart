import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/model_provider.dart';
import '../providers/renderer_provider.dart';
import '../widgets/adaptive_layout.dart';
import '../widgets/app_logo.dart';
import '../features/remote/remote_page.dart';
import 'library_page.dart';
import 'settings_page.dart';
import 'viewer_page.dart';

/// Adaptive shell.
///
/// On wide desktop windows (>= [AdaptiveLayout.compactBreakpoint]) the
/// app renders a two-pane shell: a left [NavigationRail] selects one of
/// three functional pages (Library / Viewer / Settings) which fill the
/// remaining content area. The Viewer page itself is a left/right split
/// (functional controls on the left, model on the right).
///
/// On narrow windows (phones, small Windows windows) the shell degrades
/// to standard page-stack navigation: each page renders full-width with
/// a leading back button.
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  /// Index of the selected rail destination.
  int _selectedIndex = 0;

  /// Whether we've already kicked off the initial library scan from
  /// this page. `initState` is the only call site — Flutter guarantees
  /// it runs exactly once per State instance, so this flag is belt-
  /// and-suspenders against accidental re-entry (e.g. a future
  /// `didChangeDependencies` adding the same scan). Mirrors the
  /// dedup logic in `LibraryPage`.
  bool _initialScanScheduled = false;

  @override
  void initState() {
    super.initState();
    // Schedule the initial library scan on first mount of HomePage so
    // the narrow-shell status text ("Library ready (N models)" /
    // "Loading library…") reflects reality before the user navigates
    // into Library. Without this the status text sits at
    // "Library idle" until the user taps "选择模型", because nothing
    // else (the embedded LibraryPage in the wide shell, or a future
    // push to /library) is observable in the narrow shell on Android
    // when the app is first launched.
    if (!_initialScanScheduled) {
      _initialScanScheduled = true;
      Future.microtask(
        () => ref.read(modelProvider.notifier).loadAvailableModels(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        switch (AdaptiveLayout.modeFor(constraints)) {
          case LayoutMode.wide:
            return _wideShell(context, constraints);
          case LayoutMode.narrow:
            return _narrowShell(context);
        }
      },
    );
  }

  /// Two-pane Windows desktop shell.
  Widget _wideShell(BuildContext context, BoxConstraints constraints) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Row(
        children: [
          _navRail(context, theme),
          VerticalDivider(width: 1, color: theme.colorScheme.outlineVariant),
          Expanded(child: _pageForIndex(_selectedIndex)),
        ],
      ),
    );
  }

  /// Phone-size shell: keep the existing navigator flow but show a
  /// friendlier home card with buttons that push the named routes.
  Widget _narrowShell(BuildContext context) {
    final model = ref.watch(modelProvider);
    final renderer = ref.watch(rendererProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Live2D Viewer')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppLogo(size: 72, color: theme.colorScheme.primary),
                const SizedBox(height: 24),
                Text(
                  _statusLine(model, renderer),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 32),
                FilledButton.icon(
                  icon: const Icon(Icons.collections),
                  label: const Text('Choose model'),
                  onPressed: () => Navigator.of(context).pushNamed('/library'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.cloud_download_outlined),
                  label: const Text('Remote models'),
                  onPressed: () => Navigator.of(context).pushNamed('/remote'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('Settings'),
                  onPressed: () => Navigator.of(context).pushNamed('/settings'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _navRail(BuildContext context, ThemeData theme) {
    return Container(
      width: AdaptiveLayout.navRailWidth,
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                AppLogo(color: theme.colorScheme.primary, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Live2D Viewer',
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _railItem(
            context,
            index: 0,
            icon: Icons.collections_bookmark_outlined,
            selectedIcon: Icons.collections_bookmark,
            label: 'Library',
          ),
          _railItem(
            context,
            index: 1,
            icon: Icons.view_in_ar_outlined,
            selectedIcon: Icons.view_in_ar,
            label: 'Viewer',
          ),
          _railItem(
            context,
            index: 2,
            icon: Icons.settings_outlined,
            selectedIcon: Icons.settings,
            label: 'Settings',
          ),
          _railItem(
            context,
            index: 3,
            icon: Icons.cloud_download_outlined,
            selectedIcon: Icons.cloud_download,
            label: 'Remote',
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _statusChip(theme),
          ),
        ],
      ),
    );
  }

  Widget _railItem(
    BuildContext context, {
    required int index,
    required IconData icon,
    required IconData selectedIcon,
    required String label,
  }) {
    final theme = Theme.of(context);
    final selected = _selectedIndex == index;
    return Material(
      key: Key('rail-item-$label'),
      color: Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _selectedIndex = index),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                width: 3,
                color: selected
                    ? theme.colorScheme.primary
                    : Colors.transparent,
              ),
            ),
            color: selected
                ? theme.colorScheme.primaryContainer.withValues(alpha: 0.45)
                : Colors.transparent,
          ),
          child: Row(
            children: [
              Icon(
                selected ? selectedIcon : icon,
                size: 22,
                color: selected
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: selected ? FontWeight.w600 : null,
                    color: selected
                        ? theme.colorScheme.onPrimaryContainer
                        : theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pageForIndex(int index) {
    switch (index) {
      case 0:
        return const LibraryPage(embedded: true);
      case 1:
        return const ViewerPage(embedded: true);
      case 2:
        return const SettingsPage(embedded: true);
      case 3:
        return const RemotePage(embedded: true);
      default:
        return const LibraryPage(embedded: true);
    }
  }

  Widget _statusChip(ThemeData theme) {
    final model = ref.watch(modelProvider);
    final renderer = ref.watch(rendererProvider);
    final dot = switch (renderer.status) {
      RendererStatus.ready => Colors.green,
      RendererStatus.loading => Colors.amber,
      RendererStatus.error => Colors.red,
      RendererStatus.idle => Colors.grey,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _shortStatus(model, renderer),
              style: theme.textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  String _statusLine(ModelState model, RendererState renderer) {
    final parts = <String>[];
    switch (model.status) {
      case ModelSelectionStatus.loading:
        parts.add('Loading library…');
        break;
      case ModelSelectionStatus.error:
        parts.add('Library error: ${model.errorMessage ?? "unknown"}');
        break;
      case ModelSelectionStatus.ready:
        final count = model.availableModels.length;
        parts.add(
          count == 0
              ? 'No models yet — add a local folder or download a remote model.'
              : 'Library ready ($count model${count == 1 ? "" : "s"})',
        );
        break;
      case ModelSelectionStatus.idle:
        parts.add('Library idle');
        break;
    }
    switch (renderer.status) {
      case RendererStatus.loading:
        parts.add('renderer initializing…');
        break;
      case RendererStatus.error:
        parts.add('renderer error: ${renderer.errorMessage ?? "unknown"}');
        break;
      case RendererStatus.ready:
        parts.add('renderer ready');
        break;
      case RendererStatus.idle:
        parts.add('renderer idle');
        break;
    }
    return parts.join(' · ');
  }

  String _shortStatus(ModelState model, RendererState renderer) {
    final m = switch (model.status) {
      ModelSelectionStatus.loading => 'lib…',
      ModelSelectionStatus.error => 'lib err',
      ModelSelectionStatus.ready => 'lib ${model.availableModels.length}',
      ModelSelectionStatus.idle => 'lib idle',
    };
    final r = switch (renderer.status) {
      RendererStatus.loading => 'init',
      RendererStatus.error => 'err',
      RendererStatus.ready => 'ready',
      RendererStatus.idle => 'idle',
    };
    return '$m · $r';
  }
}
