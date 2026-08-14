import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app_controller.dart';
import 'ui/home_shell.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: CastFlowApp()));
}

class CastFlowApp extends ConsumerStatefulWidget {
  const CastFlowApp({super.key, this.initializeController = true});

  final bool initializeController;

  @override
  ConsumerState<CastFlowApp> createState() => _CastFlowAppState();
}

class _CastFlowAppState extends ConsumerState<CastFlowApp> {
  @override
  void initState() {
    super.initState();
    if (widget.initializeController) {
      Future.microtask(() => ref.read(appControllerProvider).initialize());
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CastFlow',
      debugShowCheckedModeBanner: false,
      theme: buildCastFlowTheme(),
      home: const HomeShell(),
    );
  }
}
