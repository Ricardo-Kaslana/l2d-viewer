import 'package:flutter/material.dart';

/// Inline error banner with optional retry and dismiss actions.
///
/// Unlike [MaterialBanner], this widget renders correctly when placed directly
/// in a [Column] or similar layout — it does not rely on [ScaffoldMessenger]
/// to be shown or hidden.
class ErrorBanner extends StatelessWidget {
  const ErrorBanner({
    super.key,
    required this.message,
    this.onRetry,
    this.onDismiss,
  });

  final String message;
  final VoidCallback? onRetry;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: theme.colorScheme.errorContainer,
      child: Row(
        children: [
          Icon(Icons.error, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              child: Text(
                'Retry',
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
          if (onDismiss != null)
            TextButton(
              onPressed: onDismiss,
              child: Text(
                'Dismiss',
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
        ],
      ),
    );
  }
}
