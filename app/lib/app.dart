import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/remote/remote_page.dart';
import 'pages/home_page.dart';
import 'pages/library_page.dart';
import 'pages/settings_page.dart';
import 'pages/viewer_page.dart';

final routeObserver = RouteObserver<ModalRoute<void>>();

class Live2DViewerApp extends ConsumerWidget {
  const Live2DViewerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'Live2D Viewer',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      initialRoute: '/',
      navigatorObservers: [routeObserver],
      routes: {
        '/': (context) => const HomePage(),
        '/library': (context) => const LibraryPage(),
        '/viewer': (context) => const ViewerPage(),
        '/settings': (context) => const SettingsPage(),
        '/remote': (context) => const RemotePage(),
      },
    );
  }
}
