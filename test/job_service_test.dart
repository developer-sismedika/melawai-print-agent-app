import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:melawai_print_agent_app/agent/agent_client.dart';
import 'package:melawai_print_agent_app/core/settings.dart';
import 'package:melawai_print_agent_app/jobs/job.dart';
import 'package:melawai_print_agent_app/jobs/job_ledger.dart';
import 'package:melawai_print_agent_app/jobs/job_service.dart';

/// Stateful fake agent: one job document, scripted poll progression,
/// switchable failures. Counts POSTs so idempotency/dedupe assertions
/// are real (A4/A9/D10).
class FakeAgent {
  FakeAgent({
    this.pollStates = const ['queued', 'processing', 'submitted'],
    this.reference = 'CUPS-7',
  });

  final List<String> pollStates;
  final String reference;

  int submitCalls = 0;
  int pollCalls = 0;
  bool unreachable = false;
  bool loseFirstResponse = false;
  String? jobError;
  final Set<String> submittedKeys = {};

  static const jobId = 'job-1';

  http.Client client() => MockClient((r) async {
        // Count polls before the failure switch so tests can assert the
        // loop keeps polling while the agent is down (A13).
        if (r.method == 'GET' && r.url.path.startsWith('/api/v1/print-jobs/')) {
          pollCalls++;
          if (unreachable) {
            throw http.ClientException('connection refused');
          }
          final idx = pollCalls - 1;
          final state = idx < pollStates.length
              ? pollStates[idx]
              : pollStates.last;
          return http.Response(
              _jobJson(state: state, error: jobError, reference: reference),
              200);
        }
        if (unreachable) {
          throw http.ClientException('connection refused');
        }
        if (r.method == 'POST' && r.url.path == '/api/v1/print-jobs') {
          submitCalls++;
          final body = jsonDecode(r.body) as Map<String, dynamic>;
          final key = body['idempotency_key'] as String;
          final isFirst = !submittedKeys.contains(key);
          submittedKeys.add(key);
          if (loseFirstResponse && isFirst) {
            // Agent DID receive it; the response is lost on the wire.
            // On retry (same key) it replays with 200 (A4/A9).
            throw http.ClientException('response lost');
          }
          final status = isFirst ? 202 : 200;
          return http.Response(_jobJson(state: 'queued'), status);
        }
        return http.Response('{"error":{"code":"not_found","message":"no"}}', 404);
      });

  String _jobJson({required String state, String? error, String? reference}) =>
      jsonEncode({
        'ID': jobId,
        'PrinterID': 'mock-receipt',
        'Format': 'text/plain',
        'Title': 't',
        'State': state,
        'Error': error ?? '',
        'Reference': reference ?? '',
        'Attempts': 1,
      });
}

Future<({SettingsStore settings, InMemorySecretStore secrets})> _settings({
  String baseUrl = 'http://agent.lan:9876',
  String printer = 'mock-receipt',
}) async {
  SharedPreferences.setMockInitialValues({
    if (baseUrl.isNotEmpty) SettingsStore.kBaseUrl: baseUrl,
    if (printer.isNotEmpty) SettingsStore.kDefaultPrinter: printer,
  });
  final prefs = await SharedPreferences.getInstance();
  final secrets = InMemorySecretStore();
  if (baseUrl.isNotEmpty) {
    await secrets.write(SettingsStore.kToken, 'tok-123');
  }
  final settings = await SettingsStore.load(prefs: prefs, secrets: secrets);
  return (settings: settings, secrets: secrets);
}

Future<JobService> _service(FakeAgent agent, {SettingsStore? settings}) async {
  final s = settings ?? (await _settings()).settings;
  return JobService(
    settings: s,
    client: AgentClient(
      resolveConfig: () => s.config,
      httpClient: agent.client(),
      timeout: const Duration(milliseconds: 400),
    ),
    ledger: InMemoryJobLedger(),
    pollInterval: const Duration(milliseconds: 20),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('A10 submit -> poll -> submitted with reference', () async {
    final agent = FakeAgent();
    final svc = await _service(agent);
    addTearDown(svc.dispose);

    final outcome = await svc.submit(
      documentId: 'doc-1',
      format: 'text/plain',
      content: 'hello',
      title: 'receipt-1',
    );
    expect(outcome.jobId, FakeAgent.jobId);
    expect(outcome.state, JobState.queued);

    final record = await svc.waitForTerminal('doc-1');
    expect(record.state, JobState.submitted);
    expect(record.reference, 'CUPS-7');
    expect(agent.submitCalls, 1);
    // exactly one ledger row per documentId
    expect(await svc.recordOf('doc-1'), isNotNull);
  });

  test('A9 lost response then retry with SAME documentId -> one job', () async {
    final agent = FakeAgent()..loseFirstResponse = true;
    final svc = await _service(agent);
    addTearDown(svc.dispose);

    await expectLater(
      svc.submit(documentId: 'doc-9', format: 'text/plain', content: 'x'),
      throwsA(isA<AgentException>()
          .having((e) => e.code, 'code', 'E_AGENT_UNREACHABLE')),
    );
    // fail fast (D6): row exists, still unconfirmed, never a second row
    var record = await svc.recordOf('doc-9');
    expect(record, isNotNull);
    expect(record!.state, JobState.submitting);

    // operator retries: same documentId -> agent replays 200
    final outcome = await svc.submit(
        documentId: 'doc-9', format: 'text/plain', content: 'x');
    expect(outcome.jobId, FakeAgent.jobId);
    record = await svc.recordOf('doc-9');
    expect(record!.jobId, FakeAgent.jobId);

    final terminal = await svc.waitForTerminal('doc-9');
    expect(terminal.state, JobState.submitted);
    expect(agent.submitCalls, 2); // two POSTs, ONE agent-side job (replay)
    expect(agent.submittedKeys, {'doc-9'});
  });

  test('D10 concurrent submits for one documentId -> single POST', () async {
    final agent = FakeAgent();
    final svc = await _service(agent);
    addTearDown(svc.dispose);

    final f1 = svc.submit(documentId: 'doc-x', format: 'text/plain', content: 'a');
    final f2 = svc.submit(documentId: 'doc-x', format: 'text/plain', content: 'a');
    final results = await Future.wait([f1, f2]);
    expect(results[0].jobId, results[1].jobId);
    expect(agent.submitCalls, 1);
  });

  test('A11 failed state surfaces agent error', () async {
    final agent = FakeAgent(pollStates: ['queued', 'failed']);
    final svc = await _service(agent);
    addTearDown(svc.dispose);

    agent.jobError = 'paper out';
    await svc.submit(documentId: 'doc-f', format: 'text/plain', content: 'x');
    final record = await svc.waitForTerminal('doc-f');
    expect(record.state, JobState.failed);
    expect(record.error, 'paper out');
    expect(agent.submitCalls, 1); // failure never auto-resubmits
  });

  test('A12 unknown is terminal, no auto-retry, operator wording', () async {
    final agent = FakeAgent(pollStates: ['queued', 'processing', 'unknown']);
    final svc = await _service(agent);
    addTearDown(svc.dispose);

    await svc.submit(documentId: 'doc-u', format: 'text/plain', content: 'x');
    final record = await svc.waitForTerminal('doc-u');
    expect(record.state, JobState.unknown);
    expect(
      operatorMessageFor(record.state),
      contains('check the paper tray'),
    );
    // wait past several poll intervals: still no extra POST
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(agent.submitCalls, 1);
  });

  test('A13 agent dies mid-poll: state preserved, no local unknown', () async {
    final agent = FakeAgent(pollStates: ['queued']);
    final svc = await _service(agent);
    addTearDown(svc.dispose);

    await svc.submit(documentId: 'doc-d', format: 'text/plain', content: 'x');
    // let the first poll land (queued), then kill the agent
    await Future<void>.delayed(const Duration(milliseconds: 60));
    agent.unreachable = true;
    final pollsBefore = agent.pollCalls;
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final record = await svc.recordOf('doc-d');
    expect(record!.state, JobState.queued); // never regressed locally
    expect(agent.pollCalls, greaterThan(pollsBefore)); // still polling
    expect(agent.submitCalls, 1); // never auto-resubmitted
  });

  test('not configured -> E_NOT_CONFIGURED before any HTTP', () async {
    final agent = FakeAgent();
    final settings = await _settings(baseUrl: '', printer: 'mock-receipt');
    final svc = await _service(agent, settings: settings.settings);
    addTearDown(svc.dispose);

    await expectLater(
      svc.submit(documentId: 'doc-n', format: 'text/plain', content: 'x'),
      throwsA(isA<AgentException>()
          .having((e) => e.code, 'code', 'E_NOT_CONFIGURED')),
    );
    expect(agent.submitCalls, 0);
  });

  test('no default printer -> E_NOT_CONFIGURED before any HTTP', () async {
    final agent = FakeAgent();
    final settings = await _settings(baseUrl: 'http://agent.lan:9876', printer: '');
    final svc = await _service(agent, settings: settings.settings);
    addTearDown(svc.dispose);

    await expectLater(
      svc.submit(documentId: 'doc-n2', format: 'text/plain', content: 'x'),
      throwsA(isA<AgentException>()
          .having((e) => e.code, 'code', 'E_NOT_CONFIGURED')),
    );
    expect(agent.submitCalls, 0);
  });
}
