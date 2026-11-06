import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/settings.dart';

/// Bridge/transport error codes shared with `docs/wrapper-app-architecture.md`
/// (E_* names are part of contract v1).
class AgentException implements Exception {
  AgentException(this.code, this.message, {this.statusCode, this.agentCode});

  final String code;
  final String message;
  final int? statusCode;
  /// Agent-side `error.code` when the agent produced the failure
  /// (e.g. `printer_unavailable`), surfaced verbatim to operators.
  final String? agentCode;

  @override
  String toString() =>
      'AgentException($code${agentCode != null ? '/$agentCode' : ''}): $message';
}

class HealthResult {
  const HealthResult({required this.ok, required this.latencyMs});

  final bool ok;
  final int latencyMs;
}

class PrinterInfo {
  const PrinterInfo({required this.id, required this.formats, this.paper = ''});

  final String id;
  final List<String> formats;
  final String paper;

  factory PrinterInfo.fromJson(Map<String, dynamic> json) => PrinterInfo(
        id: (json['id'] ?? '') as String,
        formats:
            (json['formats'] as List<dynamic>? ?? []).map((e) => '$e').toList(),
        paper: (json['paper'] ?? '') as String,
      );
}

/// Parsed `queue.Job` view (agent default JSON field names: ID, State, ...).
class JobView {
  const JobView({
    required this.id,
    required this.state,
    this.printerId = '',
    this.format = '',
    this.title = '',
    this.error = '',
    this.reference = '',
    this.attempts = 0,
  });

  final String id;
  final String state; // raw server string; parse via JobService
  final String printerId;
  final String format;
  final String title;
  final String error;
  final String reference;
  final int attempts;

  factory JobView.fromJson(Map<String, dynamic> json) {
    final id = json['ID'];
    if (id is! String || id.isEmpty) {
      throw AgentException('E_JOB', 'response missing ID');
    }
    return JobView(
      id: id,
      state: (json['State'] ?? '') as String,
      printerId: (json['PrinterID'] ?? '') as String,
      format: (json['Format'] ?? '') as String,
      title: (json['Title'] ?? '') as String,
      error: (json['Error'] ?? '') as String,
      reference: (json['Reference'] ?? '') as String,
      attempts: (json['Attempts'] ?? 0) as int,
    );
  }
}

/// Typed client for the clinic-print-agent local API
/// (`docs/local-api.md`, `docs/client-integration.md`).
///
/// Config is resolved per call so a candidate config can be validated
/// before it is persisted. Every call is bounded by [timeout] — fail
/// fast is a decision (D6), never hang the operator UI.
class AgentClient {
  AgentClient({
    required AgentConfig Function() resolveConfig,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 5),
  })  : _resolve = resolveConfig,
        _http = httpClient ?? http.Client();

  final AgentConfig Function() _resolve;
  final http.Client _http;
  final Duration timeout;

  /// Same HTTP client, different config snapshot (validation flows).
  AgentClient withConfig(AgentConfig config) =>
      AgentClient(resolveConfig: () => config, httpClient: _http, timeout: timeout);

  AgentConfig get _config {
    final c = _resolve();
    if (!c.hasBaseUrl) {
      throw AgentException('E_NOT_CONFIGURED', 'agent URL not set');
    }
    return c;
  }

  String get _token {
    final t = _config.token;
    if (t.isEmpty) {
      throw AgentException('E_NOT_CONFIGURED', 'token not set');
    }
    return t;
  }

  Uri _uri(String path) => Uri.parse('${_config.normalizedBaseUrl}$path');

  Map<String, String> get _authHeaders => {'Authorization': 'Bearer $_token'};

  Never _mapNetworkError(Object e) {
    if (e is AgentException) throw e;
    if (e is TimeoutException) {
      throw AgentException('E_AGENT_UNREACHABLE', 'timeout after ${timeout.inMilliseconds} ms');
    }
    if (e is http.ClientException || e is SocketException) {
      throw AgentException('E_AGENT_UNREACHABLE', e.toString());
    }
    throw AgentException('E_AGENT_UNREACHABLE', e.toString());
  }

  AgentException _httpError(int status, String body) {
    String code = 'E_JOB';
    if (status == 401 || status == 403) {
      code = 'E_AUTH';
    } else if (status == 422 || status == 400) {
      code = 'E_VALIDATION';
    }
    String agentCode;
    String message = 'HTTP $status';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is Map) {
        final err = decoded['error'] as Map;
        agentCode = '${err['code'] ?? ''}';
        message = '${err['message'] ?? message}';
      } else {
        agentCode = '';
      }
    } catch (_) {
      agentCode = '';
    }
    return AgentException(
      code,
      message,
      statusCode: status,
      agentCode: agentCode.isEmpty ? null : agentCode,
    );
  }

  /// S1: `GET /health` (no auth). Throws E_AGENT_UNREACHABLE on any
  /// network failure or non-200 so the support screen can show FAIL.
  Future<HealthResult> health() async {
    final uri = _uri('/health');
    final sw = Stopwatch()..start();
    try {
      final r = await _http.get(uri).timeout(timeout);
      sw.stop();
      if (r.statusCode != 200) {
        throw AgentException('E_AGENT_UNREACHABLE',
            'HTTP ${r.statusCode}', statusCode: r.statusCode);
      }
      final body = jsonDecode(r.body);
      final ok = body is Map && body['status'] == 'ok';
      return HealthResult(ok: ok, latencyMs: sw.elapsedMilliseconds);
    } catch (e) {
      _mapNetworkError(e);
    }
  }

  /// `GET /agent-info` public catalogue (no auth). Tolerates unknown
  /// fields (forward-compatible reads, test A7).
  Future<List<PrinterInfo>> agentInfo() async {
    final uri = _uri('/agent-info');
    try {
      final r = await _http.get(uri).timeout(timeout);
      if (r.statusCode != 200) {
        throw _httpError(r.statusCode, r.body);
      }
      final body = jsonDecode(r.body);
      if (body is! Map || body['printers'] is! List) {
        throw AgentException('E_JOB', 'malformed agent-info response');
      }
      return (body['printers'] as List)
          .whereType<Map<String, dynamic>>()
          .map(PrinterInfo.fromJson)
          .toList();
    } catch (e) {
      _mapNetworkError(e);
    }
  }

  /// `POST /api/v1/print-jobs` — 202 new job, 200 idempotent replay.
  /// Outbound body carries exactly the contract fields (agent rejects
  /// unknown JSON fields with 400, test A8).
  Future<JobView> submitJob({
    required String printerId,
    required String format,
    required String content,
    required String idempotencyKey,
    String? title,
    String? contentEncoding,
  }) async {
    final uri = _uri('/api/v1/print-jobs');
    final body = <String, dynamic>{
      'printer_id': printerId,
      'format': format,
      'content': content,
      if (title != null && title.isNotEmpty) 'title': title,
      'idempotency_key': idempotencyKey,
      if (contentEncoding != null) 'content_encoding': contentEncoding,
    };
    try {
      final r = await _http
          .post(
            uri,
            headers: {
              ..._authHeaders,
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
      if (r.statusCode != 202 && r.statusCode != 200) {
        throw _httpError(r.statusCode, r.body);
      }
      final decoded = jsonDecode(r.body);
      if (decoded is! Map<String, dynamic>) {
        throw AgentException('E_JOB', 'malformed submit response');
      }
      return JobView.fromJson(decoded);
    } catch (e) {
      _mapNetworkError(e);
    }
  }

  /// `GET /api/v1/print-jobs/{id}` — lifecycle poll.
  Future<JobView> getJob(String id) async {
    final uri = _uri('/api/v1/print-jobs/$id');
    try {
      final r = await _http.get(uri, headers: _authHeaders).timeout(timeout);
      if (r.statusCode != 200) {
        throw _httpError(r.statusCode, r.body);
      }
      final decoded = jsonDecode(r.body);
      if (decoded is! Map<String, dynamic>) {
        throw AgentException('E_JOB', 'malformed job response');
      }
      return JobView.fromJson(decoded);
    } catch (e) {
      _mapNetworkError(e);
    }
  }

  /// `POST /api/v1/print-jobs/{id}/cancel` — queued only (409 otherwise).
  Future<JobView> cancelJob(String id) async {
    final uri = _uri('/api/v1/print-jobs/$id/cancel');
    try {
      final r = await _http
          .post(uri, headers: _authHeaders)
          .timeout(timeout);
      if (r.statusCode != 200) {
        throw _httpError(r.statusCode, r.body);
      }
      final decoded = jsonDecode(r.body);
      if (decoded is! Map<String, dynamic>) {
        throw AgentException('E_JOB', 'malformed cancel response');
      }
      return JobView.fromJson(decoded);
    } catch (e) {
      _mapNetworkError(e);
    }
  }

  /// S2 auth probe: an authenticated GET against a job id that does not
  /// exist. Auth middleware runs before routing, so 401/403 = token bad,
  /// 404 = token accepted. Returns true when the token is accepted.
  Future<bool> authProbe() async {
    final uri = _uri('/api/v1/print-jobs/__probe__');
    try {
      final r = await _http.get(uri, headers: _authHeaders).timeout(timeout);
      if (r.statusCode == 401 || r.statusCode == 403) return false;
      return true; // 404 (auth passed), or anything else non-network
    } catch (e) {
      _mapNetworkError(e);
    }
  }
}
