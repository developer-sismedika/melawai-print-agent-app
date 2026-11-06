import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:melawai_print_agent_app/agent/agent_client.dart';
import 'package:melawai_print_agent_app/core/settings.dart';

const _cfg = AgentConfig(baseUrl: 'http://agent.lan:9876', token: 'tok-123');

AgentClient _client(MockClient http, {AgentConfig config = _cfg}) =>
    AgentClient(
      resolveConfig: () => config,
      httpClient: http,
      timeout: const Duration(milliseconds: 400),
    );

String _jobJson({
  String id = 'job-1',
  String state = 'queued',
  String printerId = 'mock-receipt',
  String error = '',
  String reference = '',
}) =>
    jsonEncode({
      'ID': id,
      'PrinterID': printerId,
      'Format': 'text/plain',
      'Content': '',
      'Title': 't',
      'State': state,
      'Error': error,
      'Reference': reference,
      'Encoding': 'utf8',
      'IdemKey': 'doc-1',
      'Attempts': 1,
      'CreatedAt': '2026-09-30T00:00:00Z',
      'UpdatedAt': '2026-09-30T00:00:01Z',
    });

http.Response _err(int status, String code, String message) =>
    http.Response(jsonEncode({'error': {'code': code, 'message': message}}), status);

void main() {
  group('health (A1)', () {
    test('ok returns latency', () async {
      final c = _client(MockClient((r) async {
        expect(r.url.path, '/health');
        return http.Response('{"status":"ok"}', 200);
      }));
      final h = await c.health();
      expect(h.ok, isTrue);
      expect(h.latencyMs, greaterThanOrEqualTo(0));
    });

    test('network error -> E_AGENT_UNREACHABLE', () async {
      final c = _client(MockClient((r) async {
        throw http.ClientException('connection refused');
      }));
      expect(
        () => c.health(),
        throwsA(isA<AgentException>()
            .having((e) => e.code, 'code', 'E_AGENT_UNREACHABLE')),
      );
    });

    test('slow response -> timeout is E_AGENT_UNREACHABLE (A15)', () async {
      final c = _client(MockClient((r) async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        return http.Response('{"status":"ok"}', 200);
      }));
      await expectLater(
        c.health(),
        throwsA(isA<AgentException>()
            .having((e) => e.code, 'code', 'E_AGENT_UNREACHABLE')),
      );
    });
  });

  group('agent-info (A2/A7)', () {
    test('parses printers, tolerates unknown fields', () async {
      final c = _client(MockClient((r) async {
        expect(r.url.path, '/agent-info');
        return http.Response(
          jsonEncode({
            'agent': 'clinic-print-agent',
            'api_version': 'v1',
            'future_field': {'x': 1},
            'printers': [
              {
                'id': 'mock-receipt',
                'formats': ['text/plain'],
                'paper': 'continuous',
                'future_printer_field': true,
              },
            ],
          }),
          200,
        );
      }));
      final printers = await c.agentInfo();
      expect(printers, hasLength(1));
      expect(printers.first.id, 'mock-receipt');
      expect(printers.first.formats, ['text/plain']);
      expect(printers.first.paper, 'continuous');
    });
  });

  group('submit (A3/A4/A5/A6/A8)', () {
    test('202 accepted; outbound body has exactly the contract fields (A8)',
        () async {
      late http.Request captured;
      final c = _client(MockClient((r) async {
        captured = r;
        return http.Response(_jobJson(state: 'queued'), 202);
      }));
      final job = await c.submitJob(
        printerId: 'mock-receipt',
        format: 'text/plain',
        content: 'LINE1\n',
        title: 'receipt-1',
        idempotencyKey: 'doc-abc',
      );
      expect(job.id, 'job-1');
      expect(job.state, 'queued');
      expect(
        captured.headers['authorization'] ?? captured.headers['Authorization'],
        'Bearer tok-123',
      );
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(
        body.keys.toSet(),
        {'printer_id', 'format', 'content', 'title', 'idempotency_key'},
      );
      expect(body['idempotency_key'], 'doc-abc');
    });

    test('200 idempotent replay is acceptance (A4)', () async {
      final c = _client(MockClient((r) async {
        return http.Response(_jobJson(id: 'job-original'), 200);
      }));
      final job = await c.submitJob(
        printerId: 'mock-receipt',
        format: 'text/plain',
        content: 'x',
        idempotencyKey: 'doc-abc',
      );
      expect(job.id, 'job-original');
    });

    test('401 -> E_AUTH with agent code (A5)', () async {
      final c = _client(
          MockClient((r) async => _err(401, 'unauthorized', 'bad token')));
      await expectLater(
        c.submitJob(
          printerId: 'p',
          format: 'text/plain',
          content: 'x',
          idempotencyKey: 'k',
        ),
        throwsA(isA<AgentException>()
            .having((e) => e.code, 'code', 'E_AUTH')
            .having((e) => e.statusCode, 'status', 401)
            .having((e) => e.agentCode, 'agentCode', 'unauthorized')),
      );
    });

    test('422 -> E_VALIDATION with agent code (A6)', () async {
      final c = _client(MockClient(
          (r) async => _err(422, 'printer_unavailable', 'printer is not enabled')));
      await expectLater(
        c.submitJob(
          printerId: 'p',
          format: 'text/plain',
          content: 'x',
          idempotencyKey: 'k',
        ),
        throwsA(isA<AgentException>()
            .having((e) => e.code, 'code', 'E_VALIDATION')
            .having((e) => e.agentCode, 'agentCode', 'printer_unavailable')),
      );
    });

    test('connection refused -> E_AGENT_UNREACHABLE (A9 leg)', () async {
      final c = _client(MockClient((r) async {
        throw http.ClientException('Connection closed');
      }));
      await expectLater(
        c.submitJob(
          printerId: 'p',
          format: 'text/plain',
          content: 'x',
          idempotencyKey: 'k',
        ),
        throwsA(isA<AgentException>()
            .having((e) => e.code, 'code', 'E_AGENT_UNREACHABLE')),
      );
    });
  });

  group('not configured (A14)', () {
    test('missing base URL -> E_NOT_CONFIGURED, no HTTP', () async {
      var called = false;
      final c = _client(
        MockClient((r) async {
          called = true;
          return http.Response('{}', 200);
        }),
        config: const AgentConfig(baseUrl: '', token: ''),
      );
      await expectLater(
        c.health(),
        throwsA(isA<AgentException>()
            .having((e) => e.code, 'code', 'E_NOT_CONFIGURED')),
      );
      expect(called, isFalse);
    });

    test('missing token on authenticated route -> E_NOT_CONFIGURED', () async {
      var called = false;
      final c = _client(
        MockClient((r) async {
          called = true;
          return http.Response('{}', 200);
        }),
        config: const AgentConfig(baseUrl: 'http://agent.lan:9876', token: ''),
      );
      await expectLater(
        c.submitJob(
          printerId: 'p',
          format: 'text/plain',
          content: 'x',
          idempotencyKey: 'k',
        ),
        throwsA(isA<AgentException>()
            .having((e) => e.code, 'code', 'E_NOT_CONFIGURED')),
      );
      expect(called, isFalse);
    });
  });

  group('auth probe (S2)', () {
    test('404 means token accepted', () async {
      final c = _client(MockClient((r) async => _err(404, 'not_found', 'job not found')));
      expect(await c.authProbe(), isTrue);
    });

    test('401 means token rejected', () async {
      final c = _client(
          MockClient((r) async => _err(401, 'unauthorized', 'bad token')));
      expect(await c.authProbe(), isFalse);
    });
  });

  group('job tracking', () {
    test('getJob parses state lifecycle fields', () async {
      final c = _client(MockClient((r) async =>
          http.Response(_jobJson(state: 'submitted', reference: 'CUPS-7'), 200)));
      final job = await c.getJob('job-1');
      expect(job.state, 'submitted');
      expect(job.reference, 'CUPS-7');
    });

    test('cancel 409 -> E_JOB (not cancellable)', () async {
      final c = _client(MockClient(
          (r) async => _err(409, 'not_cancellable', 'job is processing')));
      await expectLater(
        c.cancelJob('job-1'),
        throwsA(isA<AgentException>().having((e) => e.code, 'code', 'E_JOB')),
      );
    });
  });
}
