import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Lock the app to portrait on mobile. The two-pane shell (>=720dp
  // wide) handles wide tablets / desktop; the narrow shell handles
  // phone portrait. There is no landscape phone UI.
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);
  await RustLib.init();
  runApp(const ProviderScope(child: Live2DViewerApp()));
}
