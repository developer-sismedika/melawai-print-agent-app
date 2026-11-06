import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:melawai_print_agent_app/agent/agent_client.dart';
import 'package:melawai_print_agent_app/core/settings.dart';
import 'package:melawai_print_agent_app/core/uuid.dart';
import 'package:melawai_print_agent_app/jobs/job.dart';
import 'package:melawai_print_agent_app/jobs/job_ledger.dart';
import 'package:melawai_print_agent_app/jobs/job_service.dart';

/// Real-agent integration (Phase 1 acceptance, test plan §Harness).
///
/// Skipped unless CPA_AGENT_URL points at a running agent, e.g. the
/// README quick-start config with the mock printer:
///
///   CPA_AGENT_URL=http://127.0.0.1:9876 flutter test \
///     test/real_agent_integration_test.dart
void main() {
  final agentUrl = Platform.environment['CPA_AGENT_URL'];
  final token =
      Platform.environment['CPA_AGENT_TOKEN'] ?? 'dev-token-at-least-16-chars';
  final printerId =
      Platform.environment['CPA_PRINTER_ID'] ?? 'mock-receipt';
  final skip = agentUrl == null ? 'CPA_AGENT_URL not set' : false;

  // In-process prefs: the shared_preferences platform channel does not
  // exist under `flutter test`.
  Future<SettingsStore> newStore() async {
    SharedPreferences.setMockInitialValues({});
    return SettingsStore.load(
      prefs: await SharedPreferences.getInstance(),
      secrets: InMemorySecretStore(),
    );
  }

  test('S1+S2+S3: health, auth probe, catalogue', () async {
    final s = await newStore();
    await s.save(baseUrl: agentUrl!, token: token);
    final client = AgentClient(resolveConfig: () => s.config);

    final health = await client.health();
    expect(health.ok, isTrue);

    expect(await client.authProbe(), isTrue,
        reason: 'valid token must be accepted');

    final bad = client.withConfig(
        AgentConfig(baseUrl: agentUrl, token: 'wrong-token-abcdef'));
    expect(await bad.authProbe(), isFalse,
        reason: 'bad token must be rejected');

    final printers = await client.agentInfo();
    expect(printers, isNotEmpty);
    expect(printers.any((p) => p.id == printerId), isTrue,
        reason: 'printer $printerId must be enabled on the agent');
  }, skip: skip);

  test('S4: test print reaches a terminal state via the job service', () async {
    final s = await newStore();
    await s.save(baseUrl: agentUrl!, token: token, defaultPrinterId: printerId);
    final client = AgentClient(resolveConfig: () => s.config);
    final jobs = JobService(
      settings: s,
      client: client,
      ledger: InMemoryJobLedger(),
      pollInterval: const Duration(milliseconds: 500),
    );
    addTearDown(jobs.dispose);

    final documentId = newUuidV4();
    final outcome = await jobs.submit(
      documentId: documentId,
      format: 'text/plain',
      content: 'INTEGRATION TEST PAGE\nfrom melawai_print_agent_app\n\n\n',
      title: 'integration-test',
    );
    expect(outcome.jobId, isNotNull);

    final record = await jobs.waitForTerminal(documentId,
        timeout: const Duration(seconds: 20));
    expect(record.state, JobState.submitted,
        reason: 'mock printer must accept; got ${record.state} ${record.error}');
    expect(record.reference, isNotEmpty);
  }, skip: skip);

  test('idempotent replay: same documentId prints once', () async {
    final s = await newStore();
    await s.save(baseUrl: agentUrl!, token: token, defaultPrinterId: printerId);
    final client = AgentClient(resolveConfig: () => s.config);
    final documentId = newUuidV4();

    final first = await client.submitJob(
      printerId: printerId,
      format: 'text/plain',
      content: 'REPLAY CHECK 1\n\n\n',
      idempotencyKey: documentId,
      title: 'replay-check',
    );
    final second = await client.submitJob(
      printerId: printerId,
      format: 'text/plain',
      content: 'REPLAY CHECK 1 (changed content must be ignored)\n\n\n',
      idempotencyKey: documentId,
      title: 'replay-check',
    );
    expect(second.id, first.id,
        reason: '200 replay must return the original job');
  }, skip: skip);
}
