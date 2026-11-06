import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/settings.dart';
import '../../jobs/job.dart';
import '../../jobs/job_service.dart';

/// Phase 1 shell: configuration status, recent jobs, entry points.
/// The APEM WebView lands here in phase 2 (D2).
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final jobs = context.watch<JobService>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Melawai Print'),
        actions: [
          IconButton(
            icon: const Icon(Icons.health_and_safety),
            tooltip: 'Support / health',
            onPressed: () =>
                Navigator.of(context).pushNamed('/support'),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () =>
                Navigator.of(context).pushNamed('/settings'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: Icon(
                settings.isConfigured ? Icons.check_circle : Icons.warning,
                color: settings.isConfigured ? Colors.green : Colors.orange,
              ),
              title: Text(settings.isConfigured
                  ? settings.agentBaseUrl
                  : 'Not configured'),
              subtitle: Text(settings.isConfigured
                  ? 'Default printer: ${settings.defaultPrinterId.isEmpty ? '(none)' : settings.defaultPrinterId}'
                  : 'Open Settings to configure the print agent'),
              trailing: TextButton(
                onPressed: () =>
                    Navigator.of(context).pushNamed('/settings'),
                child: const Text('Edit'),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.language),
              title: const Text('APEM web app'),
              subtitle: Text(settings.apemUrl.trim().isEmpty
                  ? 'Set the APEM URL in Settings'
                  : settings.apemUrl),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).pushNamed(
                  settings.apemUrl.trim().isEmpty ? '/settings' : '/apem'),
            ),
          ),
          const SizedBox(height: 16),
          Text('Recent print jobs',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (jobs.recent.isEmpty)
            const Text('No jobs yet.',
                style: TextStyle(color: Colors.grey))
          else
            ...jobs.recent.map((r) => _JobTile(record: r)),
        ],
      ),
    );
  }
}

class _JobTile extends StatelessWidget {
  const _JobTile({required this.record});

  final PrintJobRecord record;

  @override
  Widget build(BuildContext context) {
    final terminal = isTerminalState(record.state);
    final icon = switch (record.state) {
      JobState.submitted => Icons.check_circle,
      JobState.failed => Icons.error,
      JobState.unknown => Icons.help,
      JobState.cancelled => Icons.block,
      _ => Icons.hourglass_top,
    };
    final color = switch (record.state) {
      JobState.submitted => Colors.green,
      JobState.failed => Colors.red,
      JobState.unknown => Colors.orange,
      _ => null,
    };
    return ListTile(
      dense: true,
      leading: Icon(icon, color: color),
      title: Text(record.title.isEmpty ? record.documentId : record.title),
      subtitle: Text(
        '${record.printerId} · ${record.state.name}'
        '${record.error.isEmpty ? '' : ' · ${record.error}'}',
      ),
      trailing: terminal
          ? null
          : const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
      onLongPress: () => Clipboard.setData(
          ClipboardData(text: '${record.documentId}\n${record.jobId ?? ''}')),
    );
  }
}
