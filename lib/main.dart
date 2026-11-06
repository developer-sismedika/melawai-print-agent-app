import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'agent/agent_client.dart';
import 'core/orientation.dart';
import 'core/settings.dart';
import 'features/home/home_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/shell/webview_shell.dart';
import 'features/support/support_screen.dart';
import 'jobs/job_ledger.dart';
import 'jobs/job_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await SettingsStore.load();
  // Honor the saved orientation at boot: 'portrait'/'landscape' pin the
  // axis (overriding the system auto-rotate lock); 'auto' follows the
  // sensor. Must run before the first frame so the shell never renders
  // in the wrong axis first.
  await applyOrientation(settings.orientationMode);
  final client = AgentClient(resolveConfig: () => settings.config);

  // SQLite ledger in the app; fall back to memory if the platform
  // plugin is unavailable (e.g. desktop run) so the shell still works.
  JobLedger ledger;
  try {
    ledger = await SqliteJobLedger.open();
  } catch (_) {
    ledger = InMemoryJobLedger();
  }

  runApp(MelawaiPrintApp(settings: settings, client: client, ledger: ledger));
}

class MelawaiPrintApp extends StatelessWidget {
  const MelawaiPrintApp({
    super.key,
    required this.settings,
    required this.client,
    required this.ledger,
  });

  final SettingsStore settings;
  final AgentClient client;
  final JobLedger ledger;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsStore>.value(value: settings),
        Provider<AgentClient>.value(value: client),
        Provider<JobLedger>.value(value: ledger),
        ChangeNotifierProvider<JobService>(
          create: (_) => JobService(
            settings: settings,
            client: client,
            ledger: ledger,
          ),
        ),
      ],
      child: MaterialApp(
        title: 'Melawai Print',
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF1565C0),
          useMaterial3: true,
        ),
        // Kiosk: land straight in the APEM shell once configured;
        // Home (settings/support launcher) is the fallback.
        home: settings.apemUrl.trim().isEmpty
            ? const HomeScreen()
            : const WebViewShell(),
        routes: {
          '/apem': (_) => const WebViewShell(),
          '/settings': (_) => const SettingsScreen(),
          '/support': (_) => const SupportScreen(),
        },
      ),
    );
  }
}
