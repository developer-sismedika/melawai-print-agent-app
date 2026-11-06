import 'dart:async';

import 'package:flutter/foundation.dart';

import '../agent/agent_client.dart';
import '../core/settings.dart';
import 'job.dart';
import 'job_ledger.dart';

class SubmitOutcome {
  const SubmitOutcome({
    required this.documentId,
    required this.jobId,
    required this.state,
    this.deduped = false,
  });

  final String documentId;
  final String? jobId;
  final JobState? state;

  /// True when an identical `documentId` was already in flight and this
  /// call resolved against it without a second POST (D10).
  final bool deduped;
}

/// Transport-plane engine: idempotent submit (documentId =
/// idempotency_key), 1–2 s polling to a terminal state, and the
/// never-auto-retry rules for `unknown` (D6/D10, contract v1).
class JobService extends ChangeNotifier {
  JobService({
    required this.settings,
    required this.client,
    required this.ledger,
    this.pollInterval = const Duration(milliseconds: 1500),
  });

  final SettingsStore settings;
  final AgentClient client;
  final JobLedger ledger;
  final Duration pollInterval;

  final Map<String, Future<SubmitOutcome>> _inFlight = {};
  Timer? _pollTimer;
  int _pollFailures = 0;

  List<PrintJobRecord> recent = [];

  Future<SubmitOutcome> submit({
    required String documentId,
    required String format,
    required String content,
    String? printerId,
    String title = '',
    String? contentEncoding,
  }) {
    // D10 single-flight: a concurrent submit for the same document
    // resolves against the in-flight one — no second POST.
    final existing = _inFlight[documentId];
    if (existing != null) return existing;

    final future = _submit(
      documentId: documentId,
      format: format,
      content: content,
      printerId: printerId,
      title: title,
      contentEncoding: contentEncoding,
    );
    _inFlight[documentId] = future;
    return future.whenComplete(() => _inFlight.remove(documentId));
  }

  Future<SubmitOutcome> _submit({
    required String documentId,
    required String format,
    required String content,
    String? printerId,
    required String title,
    String? contentEncoding,
  }) async {
    // Contract order: configuration first (bridge-v1 fixture text),
    // then printer selection.
    if (!settings.isConfigured) {
      throw AgentException('E_NOT_CONFIGURED', 'agent URL or token not set');
    }
    final pid = (printerId == null || printerId.isEmpty)
        ? settings.defaultPrinterId
        : printerId;
    if (pid.isEmpty) {
      throw AgentException('E_NOT_CONFIGURED', 'no printer selected');
    }

    final now = DateTime.now();
    final existing = await ledger.findByDocumentId(documentId);
    // One ledger row per documentId, kept across retries (A9): a retry
    // after a lost response updates the same row, never forks a second.
    var record = existing ??
        PrintJobRecord(
          documentId: documentId,
          printerId: pid,
          title: title,
          format: format,
          state: JobState.submitting,
          createdAt: now,
        );
    record = record.copyWith(
      printerId: pid,
      title: title,
      state: JobState.submitting,
      error: '',
      updatedAt: now,
    );
    await ledger.upsert(record);
    await _refreshRecent();
    notifyListeners();

    try {
      final job = await client.submitJob(
        printerId: pid,
        format: format,
        content: content,
        idempotencyKey: documentId, // D5: documentId IS the key
        title: title,
        contentEncoding: contentEncoding,
      );
      final state = parseJobState(job.state) ?? JobState.queued;
      record = record.copyWith(
        jobId: job.id,
        state: state,
        error: job.error,
        reference: job.reference,
        updatedAt: DateTime.now(),
      );
      await ledger.upsert(record);
      await _refreshRecent();
      notifyListeners();
      if (!isTerminalState(state)) {
        _startPolling(record);
      }
      return SubmitOutcome(
        documentId: documentId,
        jobId: job.id,
        state: state,
      );
    } on AgentException catch (e) {
      // Fail fast (D6): surface. A retry reuses the same documentId, so
      // if the lost POST did reach the agent, the replay returns 200.
      record = record.copyWith(
        error: '${e.code}: ${e.message}',
        updatedAt: DateTime.now(),
      );
      await ledger.upsert(record);
      await _refreshRecent();
      notifyListeners();
      rethrow;
    }
  }

  void _startPolling(PrintJobRecord record) {
    if (record.jobId == null) return;
    _pollTimer?.cancel();
    _pollFailures = 0;
    final documentId = record.documentId;
    final jobId = record.jobId!;
    _pollTimer =
        Timer.periodic(pollInterval, (_) => _pollOnce(documentId, jobId));
  }

  Future<void> _pollOnce(String documentId, String jobId) async {
    try {
      final job = await client.getJob(jobId);
      _pollFailures = 0;
      final state = parseJobState(job.state);
      if (state == null) return; // unrecognized: keep previous state
      final existing = await ledger.findByDocumentId(documentId);
      if (existing == null) return;
      final updated = existing.copyWith(
        state: state,
        error: job.error,
        reference: job.reference,
        updatedAt: DateTime.now(),
      );
      await ledger.upsert(updated);
      await _refreshRecent();
      notifyListeners();
      if (isTerminalState(state)) {
        _pollTimer?.cancel();
        _pollTimer = null;
      }
    } on AgentException catch (e) {
      if (e.code == 'E_AUTH') {
        // Token died mid-shift: stop polling, keep last known state,
        // operator is routed to Settings by the UI.
        _pollTimer?.cancel();
        _pollTimer = null;
        final existing = await ledger.findByDocumentId(documentId);
        if (existing != null) {
          await ledger.upsert(existing.copyWith(
            error: '${e.code}: token expired or invalid',
            updatedAt: DateTime.now(),
          ));
          await _refreshRecent();
          notifyListeners();
        }
        return;
      }
      // Unreachable / transient: keep last known state forever (A13 —
      // never regress queued->unknown locally, never auto-retry). Once
      // the agent is back it reports the truth, including `unknown`
      // after its own restart recovery.
      _pollFailures++;
      if (_pollFailures > 100) {
        // Keep the timer alive but slow down implicitly by no-oping
        // faster failures; bounded failure count only avoids log spam.
        _pollFailures = 100;
      }
    }
  }

  Future<void> _refreshRecent() async {
    recent = await ledger.recent(limit: 20);
  }

  Future<PrintJobRecord?> recordOf(String documentId) =>
      ledger.findByDocumentId(documentId);

  /// Bridge `jobStatus` lookup: ledger is keyed by documentId, so scan
  /// recent rows for the agent job id.
  Future<PrintJobRecord?> findByJobId(String jobId) async {
    final rows = await ledger.recent(limit: 200);
    for (final r in rows) {
      if (r.jobId == jobId) return r;
    }
    return null;
  }

  /// Test/UX helper: wait until the job reaches a terminal state.
  Future<PrintJobRecord> waitForTerminal(
    String documentId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final r = await ledger.findByDocumentId(documentId);
      if (r != null && isTerminalState(r.state)) return r;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final r = await ledger.findByDocumentId(documentId);
    throw StateError(
        'job $documentId did not reach a terminal state (last: ${r?.state})');
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }
}
