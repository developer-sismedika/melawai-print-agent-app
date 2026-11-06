import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:melawai_print_agent_app/agent/agent_client.dart';
import 'package:melawai_print_agent_app/core/settings.dart';
import 'package:melawai_print_agent_app/features/settings/settings_screen.dart';
import 'package:melawai_print_agent_app/jobs/job_ledger.dart';
import 'package:melawai_print_agent_app/jobs/job_service.dart';

/// Smoke tests: the settings screen builds inside the provider graph;
/// agent URL and token are optional (empty save succeeds without HTTP),
/// while a malformed URL is still rejected client-side before any call.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Widget> wrap() async {
    SharedPreferences.setMockInitialValues({});
    final settings = await SettingsStore.load(
      prefs: await SharedPreferences.getInstance(),
      secrets: InMemorySecretStore(),
    );
    final client = AgentClient(resolveConfig: () => settings.config);
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsStore>.value(value: settings),
        Provider<AgentClient>.value(value: client),
        ChangeNotifierProvider<JobService>(
          create: (_) => JobService(
            settings: settings,
            client: client,
            ledger: InMemoryJobLedger(),
          ),
        ),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    );
  }

  testWidgets('settings screen renders and validates empty fields',
      (tester) async {
    await tester.pumpWidget(await wrap());
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Validate & Save'), findsOneWidget);

    await tester.tap(find.text('Validate & Save'));
    await tester.pumpAndSettle();
    // Empty agent config saves directly — no validation error, no HTTP.
    expect(find.text('Agent URL is required'), findsNothing);
    expect(find.text('Token is required'), findsNothing);
    expect(find.textContaining('Settings saved'), findsOneWidget);
  });

  testWidgets('orientation dropdown persists and applies immediately',
      (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    await tester.pumpWidget(await wrap());

    expect(find.text('Screen orientation'), findsOneWidget);
    await tester.tap(find.text('Auto (follow sensor)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Landscape'));
    // applyOrientationVerified settles ~1.5s before reading MediaQuery;
    // elapse it so no timer is pending at test end.
    await tester.pump(const Duration(milliseconds: 1600));
    await tester.pumpAndSettle();

    final orientationCalls = calls
        .where((c) => c.method == 'SystemChrome.setPreferredOrientations')
        .toList();
    expect(orientationCalls, hasLength(1));
    expect(
      (orientationCalls.single.arguments as List).cast<String>(),
      ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight'],
    );
  });
}
