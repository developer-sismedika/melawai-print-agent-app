import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../agent/agent_client.dart';
import '../../core/settings.dart';
import '../../jobs/job.dart';
import '../../jobs/job_service.dart';
import '../../core/uuid.dart';

/// Support / health screen (S1–S5): the screen support staff walk an
/// operator through by phone. Read-only checks + one test print.
class SupportScreen extends StatefulWidget {
  const SupportScreen({super.key});

  @override
  State<SupportScreen> createState() => _SupportScreenState();
}

class CheckResult {
  const CheckResult(this.name, this.pass, this.detail);

  final String name;
  final bool pass;
  final String detail;
}

class _SupportScreenState extends State<SupportScreen> {
  final List<CheckResult> _results = [];
  bool _busy = false;
  bool _testingPrint = false;
  String? _testPrintOutcome;

  Future<void> _runChecks() async {
    setState(() {
      _busy = true;
      _results.clear();
      _testPrintOutcome = null;
    });
    final client = context.read<AgentClient>();
    final results = <CheckResult>[];

    // S1 reachability + latency
    try {
      final h = await client.health();
      results.add(CheckResult(
        'S1 agent reachable',
        h.ok,
        h.ok ? 'status ok — ${h.latencyMs} ms' : 'unexpected health payload',
      ));
    } on AgentException catch (e) {
      results.add(CheckResult('S1 agent reachable', false,
          '${e.code}: ${e.message} — is the agent on? check the IP in Settings'));
      _finish(results);
      return; // everything else depends on reachability
    }

    // S2 auth
    try {
      final ok = await client.authProbe();
      results.add(CheckResult(
        'S2 token accepted',
        ok,
        ok ? 'Bearer token accepted by the agent' : '401/403 — token expired or invalid',
      ));
    } on AgentException catch (e) {
      results.add(CheckResult('S2 token accepted', false, '${e.code}: ${e.message}'));
      _finish(results);
      return;
    }

    // S3 printer catalogue
    try {
      final printers = await client.agentInfo();
      results.add(CheckResult(
        'S3 printer catalogue',
        printers.isNotEmpty,
        printers.isEmpty
            ? 'no enabled printers — add one on the agent /maintain page'
            : printers
                .map((p) => '${p.id} [${p.formats.join(', ')}] ${p.paper}')
                .join(' | '),
      ));
    } on AgentException catch (e) {
      results.add(CheckResult('S3 printer catalogue', false, '${e.code}: ${e.message}'));
    }

    _finish(results);
  }

  void _finish(List<CheckResult> results) {
    if (!mounted) return;
    setState(() {
      _results
        ..clear()
        ..addAll(results);
      _busy = false;
    });
  }

  Future<void> _testPrint() async {
    setState(() {
      _testingPrint = true;
      _testPrintOutcome = null;
    });
    final jobs = context.read<JobService>();
    final settings = context.read<SettingsStore>();
    final documentId = newUuidV4();
    try {
      final outcome = await jobs.submit(
        documentId: documentId,
        format: 'text/plain',
        content: 'MELAIWAI AGENT TEST PAGE\napp: melawai_print_agent_app 0.1.0\n\n\n',
        printerId: settings.defaultPrinterId,
        title: 'app-test-print',
      );
      final record = await jobs.waitForTerminal(documentId,
          timeout: const Duration(seconds: 15));
      if (!mounted) return;
      setState(() {
        _testPrintOutcome =
            '${record.state.name}: ${operatorMessageFor(record.state, error: record.error)}'
            '${record.reference.isEmpty ? '' : ' (ref ${record.reference})'}'
            '${outcome.jobId == null ? '' : ''}';
      });
    } on AgentException catch (e) {
      if (!mounted) return;
      setState(() => _testPrintOutcome = '${e.code}: ${e.message}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _testPrintOutcome = '$e');
    } finally {
      if (mounted) setState(() => _testingPrint = false);
    }
  }

  String _diagnostics() {
    final settings = context.read<SettingsStore>();
    final buf = StringBuffer()
      ..writeln('melawai_print_agent_app 0.1.0')
      ..writeln('platform: ${DateTime.now().toIso8601String()}')
      ..writeln('agent: ${settings.agentBaseUrl.isEmpty ? '(not set)' : settings.agentBaseUrl}')
      ..writeln('configured: ${settings.isConfigured ? 'yes' : 'no'}')
      ..writeln('default printer: ${settings.defaultPrinterId.isEmpty ? '(none)' : settings.defaultPrinterId}');
    for (final r in _results) {
      buf.writeln('${r.name}: ${r.pass ? 'PASS' : 'FAIL'} — ${r.detail}');
    }
    if (_testPrintOutcome != null) {
      buf.writeln('test print: $_testPrintOutcome');
    }
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Support / health')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : _runChecks,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.favorite),
                label: const Text('Run checks'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: (_busy || _testingPrint) ? null : _testPrint,
                icon: _testingPrint
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.print),
                label: const Text('Test print'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ..._results.map((r) => ListTile(
                dense: true,
                leading: Icon(
                  r.pass ? Icons.check_circle : Icons.cancel,
                  color: r.pass ? Colors.green : Colors.red,
                ),
                title: Text(r.name),
                subtitle: Text(r.detail),
              )),
          if (_testPrintOutcome != null)
            ListTile(
              dense: true,
              leading: const Icon(Icons.receipt_long),
              title: const Text('S4 test print'),
              subtitle: Text(_testPrintOutcome!),
            ),
          const SizedBox(height: 16),
          if (_results.isNotEmpty || _testPrintOutcome != null) ...[
            Text('Diagnostics', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _diagnostics(),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _diagnostics()));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Diagnostics copied')));
                }
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy diagnostics'),
            ),
          ],
        ],
      ),
    );
  }
}
