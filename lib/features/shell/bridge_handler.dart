import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../agent/agent_client.dart';
import '../../core/settings.dart';
import '../../jobs/job_service.dart';

/// Dart side of bridge contract v1: receives the envelope JSON from the
/// shim's `printAgent` script handler, re-validates (defense in depth),
/// and dispatches. The page NEVER performs network I/O (D3) — this
/// handler owns every agent call, including the optional artifactUrl
/// fetch (D9).
class BridgeHandler {
  BridgeHandler({
    required this.jobs,
    required this.client,
    required this.settings,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final JobService jobs;
  final AgentClient client;
  final SettingsStore settings;
  final http.Client _http;

  /// D9: max envelope JSON size for inline content.
  static const int maxInlineBytes = 1024 * 1024;
  static const int maxArtifactBytes = 5 * 1024 * 1024;

  static const Set<String> _printFields = {
    'documentId',
    'printerId',
    'title',
    'format',
    'contentEncoding',
    'content',
    'artifactUrl',
  };

  List<PrinterInfo>? _printersCache;
  DateTime _printersCachedAt = DateTime.fromMillisecondsSinceEpoch(0);

  Map<String, dynamic> _err(String code, String message, {String? agentCode}) => {
        'v': 1,
        'ok': false,
        'error': {'code': code, 'message': message},
        if (agentCode != null) 'agentCode': agentCode,
      };

  /// Entry point for the script message handler. Always returns an
  /// envelope JSON string — failures are values, never thrown to the page.
  Future<String> handle(String raw) async {
    Map<String, dynamic> response;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        response = _err('E_BAD_PAYLOAD', 'malformed envelope');
      } else {
        response = await _dispatch(decoded);
      }
    } on FormatException {
      response = _err('E_BAD_PAYLOAD', 'malformed envelope');
    } catch (e) {
      response = _err('E_JOB', 'unexpected bridge failure: $e');
    }
    return jsonEncode(response);
  }

  Future<Map<String, dynamic>> _dispatch(Map<String, dynamic> env) async {
    for (final k in env.keys) {
      if (k != 'v' && k != 'action' && k != 'payload') {
        return _err('E_BAD_PAYLOAD', 'unknown field: $k');
      }
    }
    if (env['v'] != 1) {
      return _err('E_BAD_PAYLOAD', 'unsupported contract version');
    }
    final payload = env['payload'];
    if (payload != null && payload is! Map<String, dynamic>) {
      return _err('E_BAD_PAYLOAD', 'payload must be an object');
    }
    final p = payload as Map<String, dynamic>? ?? <String, dynamic>{};

    switch (env['action']) {
      case 'print':
        return _print(p);
      case 'printers':
        return _printers();
      case 'health':
        return _health();
      case 'jobStatus':
        return _jobStatus(p);
      default:
        return _err('E_BAD_PAYLOAD', 'unknown action: ${env['action']}');
    }
  }

  Future<Map<String, dynamic>> _print(Map<String, dynamic> p) async {
    for (final k in p.keys) {
      if (!_printFields.contains(k)) {
        return _err('E_BAD_PAYLOAD', 'unknown field: $k');
      }
    }
    final documentId = p['documentId'];
    if (documentId is! String || documentId.isEmpty) {
      return _err('E_BAD_PAYLOAD', 'missing required field: documentId');
    }
    final format = p['format'];
    if (format is! String || format.isEmpty) {
      return _err('E_BAD_PAYLOAD', 'missing required field: format');
    }
    final content = p['content'];
    final artifactUrl = p['artifactUrl'];
    if ((content == null || content == '') && (artifactUrl == null || artifactUrl == '')) {
      return _err('E_BAD_PAYLOAD', 'missing required field: content');
    }
    if (content != null && content is! String) {
      return _err('E_BAD_PAYLOAD', 'content must be a string');
    }

    // D9 size cap on the envelope exactly as the shim measures it.
    final envelopeSize =
        jsonEncode({'v': 1, 'action': 'print', 'payload': p}).length;
    if (envelopeSize > maxInlineBytes) {
      return _err('E_PAYLOAD_TOO_LARGE',
          'inline content exceeds 1 MB bridge cap; use artifactUrl');
    }

    var body = content as String? ?? '';
    String? encoding = p['contentEncoding'] as String?;
    if ((body.isEmpty) && artifactUrl is String && artifactUrl.isNotEmpty) {
      try {
        final bytes = await _fetchArtifact(artifactUrl);
        body = base64Encode(bytes);
        encoding = 'base64';
      } on AgentException catch (e) {
        return _err(e.code, e.message);
      }
    }

    try {
      final outcome = await jobs.submit(
        documentId: documentId,
        format: format,
        content: body,
        printerId: p['printerId'] is String ? p['printerId'] as String : null,
        title: p['title'] is String ? p['title'] as String : '',
        contentEncoding: encoding,
      );
      return {
        'v': 1,
        'ok': true,
        'jobId': outcome.jobId,
        'state': outcome.state?.name ?? 'queued',
        if (outcome.deduped) 'deduped': true,
      };
    } on AgentException catch (e) {
      return _err(e.code, e.message, agentCode: e.agentCode);
    }
  }

  Future<List<int>> _fetchArtifact(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw AgentException('E_BAD_PAYLOAD', 'invalid artifactUrl');
    }
    final r = await _http.get(uri).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      throw AgentException('E_JOB', 'artifact fetch HTTP ${r.statusCode}');
    }
    if (r.bodyBytes.length > maxArtifactBytes) {
      throw AgentException(
          'E_PAYLOAD_TOO_LARGE', 'artifact exceeds $maxArtifactBytes bytes');
    }
    return r.bodyBytes;
  }

  Future<Map<String, dynamic>> _printers() async {
    final fresh = _printersCache != null &&
        DateTime.now().difference(_printersCachedAt) < const Duration(seconds: 60);
    try {
      final printers = fresh ? _printersCache! : await client.agentInfo();
      _printersCache = printers;
      _printersCachedAt = DateTime.now();
      return {
        'v': 1,
        'ok': true,
        'printers': printers
            .map((p) => {'id': p.id, 'formats': p.formats, 'paper': p.paper})
            .toList(),
      };
    } on AgentException catch (e) {
      return _err(e.code, e.message, agentCode: e.agentCode);
    }
  }

  Future<Map<String, dynamic>> _health() async {
    try {
      final h = await client.health();
      return {
        'v': 1,
        'ok': h.ok,
        'agent': h.ok ? 'ok' : 'down',
        'latencyMs': h.latencyMs,
      };
    } on AgentException catch (e) {
      return _err(e.code, e.message, agentCode: e.agentCode);
    }
  }

  Future<Map<String, dynamic>> _jobStatus(Map<String, dynamic> p) async {
    final jobId = p['jobId'];
    if (jobId is! String || jobId.isEmpty) {
      return _err('E_BAD_PAYLOAD', 'missing required field: jobId');
    }
    final record = await jobs.findByJobId(jobId);
    if (record == null) {
      return _err('E_JOB', 'job not found');
    }
    return {'v': 1, 'ok': true, 'jobId': jobId, 'state': record.state.name};
  }
}
