import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:melawai_print_agent_app/agent/agent_client.dart';
import 'package:melawai_print_agent_app/core/settings.dart';
import 'package:melawai_print_agent_app/features/shell/bridge_handler.dart';
import 'package:melawai_print_agent_app/jobs/job.dart';
import 'package:melawai_print_agent_app/jobs/job_ledger.dart';
import 'package:melawai_print_agent_app/jobs/job_service.dart';

/// Fixture-driven bridge contract tests: run every case in
/// `docs/examples/bridge-v1.json` (sibling repo checkout) through the
/// Dart handler. This is the half of the contract executable without a
/// real WebView; the JS shim itself is exercised by the Phase 2
/// staging acceptance on device.
///
/// Fixture paths relative to the app project root:
///   ../melawai-printing-agent/docs/examples/bridge-v1.json

class RecordingAgent {
  RecordingAgent({this.submitStatus = 202, this.submitState = 'queued'});
  int postCount = 0;
  final List<Map<String, dynamic>> submitBodies = [];
  int submitStatus;
  String submitState;
  bool unreachable = false;
  bool authRejected = false;
  bool validationRejected = false;

  http.Client client() => MockClient((r) async {
        if (unreachable) throw http.ClientException('connection refused');
        if (r.method == 'POST' && r.url.path == '/api/v1/print-jobs') {
          postCount++;
          submitBodies.add(jsonDecode(r.body) as Map<String, dynamic>);
          if (authRejected) {
            return http.Response(
                jsonEncode({'error': {'code': 'unauthorized', 'message': 'bad token'}}), 401);
          }
          if (validationRejected) {
            return http.Response(
                jsonEncode({'error': {'code': 'printer_unavailable', 'message': 'printer is not enabled'}}),
                422);
          }
          return http.Response(
            jsonEncode({
              'ID': 'job-abc-${postCount.toString().padLeft(3, '0')}',
              'PrinterID': submitBodies.last['printer_id'],
              'State': submitState,
              'Title': submitBodies.last['title'] ?? '',
              'Error': '',
              'Reference': '',
              'Attempts': 1,
            }),
            submitStatus,
          );
        }
        if (r.url.path == '/health') {
          return http.Response('{"status":"ok"}', 200);
        }
        if (r.url.path == '/agent-info') {
          return http.Response(
            jsonEncode({
              'printers': [
                {'id': 'mock-receipt', 'formats': ['text/plain'], 'paper': 'continuous'},
                {'id': 'pdf-printer', 'formats': ['application/pdf'], 'paper': 'A4'},
              ],
            }),
            200,
          );
        }
        if (r.url.path.startsWith('/api/v1/print-jobs/')) {
          return http.Response(
              jsonEncode({'ID': 'job-abc-001', 'State': 'submitted', 'Reference': 'CUPS-9'}),
              200);
        }
        if (r.url.host == 'apem.example.com') {
          return http.Response.bytes('%PDF-1.4 fake artifact'.codeUnits, 200);
        }
        return http.Response('{"error":{"code":"not_found","message":"no"}}', 404);
      });
}

late File fixtureFile;

Future<({SettingsStore settings, InMemorySecretStore secrets})> buildSettings({
  bool configured = true,
}) async {
  SharedPreferences.setMockInitialValues(configured
      ? {
          SettingsStore.kBaseUrl: 'http://agent.lan:9876',
          SettingsStore.kDefaultPrinter: 'mock-receipt',
        }
      : <String, Object>{});
  final prefs = await SharedPreferences.getInstance();
  final secrets = InMemorySecretStore();
  if (configured) await secrets.write(SettingsStore.kToken, 'tok-123');
  final settings = await SettingsStore.load(prefs: prefs, secrets: secrets);
  return (settings: settings, secrets: secrets);
}

({BridgeHandler handler, RecordingAgent agent, SettingsStore settings})
    buildHandler(RecordingAgent agent, SettingsStore settings) {
  final client = AgentClient(
    resolveConfig: () => settings.config,
    httpClient: agent.client(),
    timeout: const Duration(milliseconds: 400),
  );
  final jobs = JobService(
    settings: settings,
    client: client,
    ledger: InMemoryJobLedger(),
    pollInterval: const Duration(milliseconds: 20),
  );
  final handler = BridgeHandler(
      jobs: jobs, client: client, settings: settings, httpClient: agent.client());
  return (handler: handler, agent: agent, settings: settings);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final path = '${Directory.current.path}'
      '/../melawai-printing-agent/docs/examples/bridge-v1.json';
  fixtureFile = File(path);
  final hasFixtures = fixtureFile.existsSync();

  List<Map<String, dynamic>> cases = [];
  if (hasFixtures) {
    // Loaded synchronously: the test loop below runs at collection
    // time, before any setUpAll could fill `cases`.
    final decoded =
        jsonDecode(fixtureFile.readAsStringSync()) as Map<String, dynamic>;
    cases = (decoded['cases'] as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> runCase(
    Map<String, dynamic> c, {
    SettingsStore? settings,
    RecordingAgent? agent,
    BridgeHandler? handler,
  }) async {
    final a = agent ?? RecordingAgent();
    final s = settings ?? (await buildSettings()).settings;
    final h = handler ?? buildHandler(a, s).handler;
    var envelope = jsonEncode(c['envelope']);
    final generator = c['generator'];
    if (generator is Map<String, dynamic> && generator['type'] == 'repeat') {
      final decodedEnv = jsonDecode(envelope) as Map<String, dynamic>;
      final payload = decodedEnv['payload'] as Map<String, dynamic>;
      payload['content'] =
          List<String>.filled(generator['count'] as int, generator['char'] as String)
              .join();
      envelope = jsonEncode(decodedEnv);
    }
    final raw = await h.handle(envelope);
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  void expectError(Map<String, dynamic> resp, String code) {
    expect(resp['ok'], isFalse, reason: '$resp');
    expect((resp['error'] as Map)['code'], code, reason: '$resp');
  }

  group('bridge-v1 fixtures', () {
    test('fixture file present in sibling repo', () {
      expect(hasFixtures, isTrue,
          reason: 'expected $path — run from the app project root');
    });

    for (final c in cases.where((c) => c['name'] != null)) {
      final name = c['name'] as String;
      test(name, () async {
        final expectResp = c['expectResponse'] as Map<String, dynamic>;
        final noPost = c['expectNoHttpPost'] == true;
        final expectErr =
            expectResp['ok'] == false ? (expectResp['error'] as Map)['code'] : null;

        if (expectErr != null && noPost) {
          // Error-before-POST cases run against a fresh configured agent.
          final a = RecordingAgent();
          final s = (await buildSettings(configured: false)).settings;
          final resp = await runCase(c, settings: s, agent: a);
          expectError(resp, expectErr as String);
          expect(a.postCount, 0, reason: 'must not POST (D9/strict envelope)');
          if ((expectResp['error'] as Map)['message'] != null) {
            expect((resp['error'] as Map)['message'],
                expectResp['error']['message'],
                reason: 'error message is contract text');
          }
          return;
        }

        switch (name) {
          case 'print_text_ok':
          case 'print_pdf_base64_inline_ok':
            final a = RecordingAgent();
            final s = (await buildSettings()).settings;
            final resp = await runCase(c, settings: s, agent: a);
            expect(resp['ok'], isTrue, reason: '$resp');
            expect(resp['state'], 'queued');
            expect(resp['jobId'], isNotNull);
            expect(a.postCount, 1);
            return;

          case 'print_default_printer':
            final a = RecordingAgent();
            final s = (await buildSettings()).settings;
            final resp = await runCase(c, settings: s, agent: a);
            expect(resp['ok'], isTrue, reason: '$resp');
            expect(a.submitBodies.single['printer_id'], 'mock-receipt',
                reason: 'settings default printer substituted');
            return;

          case 'print_via_artifact_url_ok':
            final a = RecordingAgent();
            final s = (await buildSettings()).settings;
            final resp = await runCase(c, settings: s, agent: a);
            expect(resp['ok'], isTrue, reason: '$resp');
            expect(a.postCount, 1);
            final body = a.submitBodies.single;
            expect(body['content_encoding'], 'base64');
            final decoded =
                String.fromCharCodes(base64Decode(body['content'] as String));
            expect(decoded, startsWith('%PDF-'),
                reason: 'artifact fetched by Dart, not the page (D3/D9)');
            return;

          case 'print_inline_over_1mb_rejected':
            final a = RecordingAgent();
            final s = (await buildSettings()).settings;
            final resp = await runCase(c, settings: s, agent: a);
            expectError(resp, 'E_PAYLOAD_TOO_LARGE');
            expect(a.postCount, 0);
            return;

          case 'print_not_configured':
            final a = RecordingAgent();
            final s = (await buildSettings(configured: false)).settings;
            final resp = await runCase(c, settings: s, agent: a);
            expectError(resp, 'E_NOT_CONFIGURED');
            expect(a.postCount, 0);
            return;

          case 'print_agent_unreachable':
            final a = RecordingAgent()..unreachable = true;
            final s = (await buildSettings()).settings;
            final resp = await runCase(c, settings: s, agent: a);
            expectError(resp, 'E_AGENT_UNREACHABLE');
            return;

          case 'print_auth_rejected':
            final a = RecordingAgent()..authRejected = true;
            final s = (await buildSettings()).settings;
            final resp = await runCase(c, settings: s, agent: a);
            expectError(resp, 'E_AUTH');
            return;

          case 'print_validation_rejected':
            final a = RecordingAgent()..validationRejected = true;
            final s = (await buildSettings()).settings;
            final resp = await runCase(c, settings: s, agent: a);
            expectError(resp, 'E_VALIDATION');
            return;

          case 'print_concurrent_same_documentId_deduped':
            // Handler-level single-flight: both envelopes in flight, one POST.
            final a = RecordingAgent();
            final s = (await buildSettings()).settings;
            final h = buildHandler(a, s).handler;
            final f1 = runCase(c, settings: s, agent: a, handler: h);
            final f2 = runCase(c, settings: s, agent: a, handler: h);
            final rs = await Future.wait([f1, f2]);
            expect(rs[0]['ok'], isTrue, reason: '${rs[0]}');
            expect(rs[1]['jobId'], rs[0]['jobId'],
                reason: 'same envelope back for the in-flight documentId');
            expect(a.postCount, 1, reason: 'D10: no second POST');
            return;

          case 'printers_returns_cache':
            final a = RecordingAgent();
            final s = (await buildSettings()).settings;
            final resp = await runCase(c, settings: s, agent: a);
            expect(resp['ok'], isTrue, reason: '$resp');
            final printers = resp['printers'] as List;
            expect(printers.first, expectResp['printers'].first);
            expect(a.postCount, 0, reason: 'page never triggers POSTs');
            return;

          case 'health_returns_cache':
            final a = RecordingAgent();
            final s = (await buildSettings()).settings;
            final resp = await runCase(c, settings: s, agent: a);
            expect(resp['ok'], isTrue, reason: '$resp');
            expect(resp['agent'], 'ok');
            expect(resp['latencyMs'], isA<int>());
            return;

          case 'jobStatus_returns_state':
            final a = RecordingAgent();
            final s = (await buildSettings()).settings;
            final built = buildHandler(a, s);
            // Prime the ledger as if the job had completed already.
            await built.handler.jobs.ledger.upsert(PrintJobRecord(
              documentId: 'doc-1',
              jobId: 'job-abc-001',
              printerId: 'mock-receipt',
              title: 't',
              format: 'text/plain',
              state: JobState.submitted,
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ));
            final resp = await runCase(c,
                settings: s, agent: a, handler: built.handler);
            expect(resp['ok'], isTrue, reason: '$resp');
            expect(resp['state'], 'submitted');
            return;

          default:
            // Unknown-field / missing-field / malformed cases already
            // handled above; anything left runs the generic path.
            final a = RecordingAgent();
            final s = (await buildSettings()).settings;
            final resp = await runCase(c, settings: s, agent: a);
            if (expectErr != null) {
              expectError(resp, expectErr as String);
            } else {
              expect(resp['ok'], isTrue, reason: '$resp');
            }
        }
      });
    }
  });
}
