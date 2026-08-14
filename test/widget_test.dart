import 'package:castflow/app/app_controller.dart';
import 'package:castflow/main.dart';
import 'package:castflow/storage/settings_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('affiche l’identité visuelle CastFlow', (tester) async {
    final controller = AppController(SettingsRepository())..loading = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appControllerProvider.overrideWith((ref) => controller)],
        child: const CastFlowApp(initializeController: false),
      ),
    );
    await tester.pump();

    expect(find.text('CastFlow'), findsOneWidget);
    expect(find.text('Connexion'), findsWidgets);
    expect(find.text('Transferts'), findsWidgets);
  });
}
