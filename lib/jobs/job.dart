import 'package:flutter/foundation.dart';

/// Agent job lifecycle (`docs/client-integration.md`) plus the local
/// pre-acceptance state. `unknown` is terminal and NEVER auto-retried.
enum JobState {
  submitting, // local: POST in flight / unconfirmed
  queued,
  processing,
  submitted,
  failed,
  cancelled,
  unknown,
}

bool isTerminalState(JobState s) =>
    s == JobState.submitted ||
    s == JobState.failed ||
    s == JobState.cancelled ||
    s == JobState.unknown;

/// Parse a server state string; null when unrecognized (caller keeps
/// the previous state instead of guessing — never invent `unknown`).
JobState? parseJobState(String raw) {
  for (final s in JobState.values) {
    if (s.name == raw) return s;
  }
  return null;
}

/// Operator-facing wording (architecture doc §Agent interaction model).
String operatorMessageFor(JobState state, {String? error}) {
  switch (state) {
    case JobState.submitting:
      return 'Sending to agent...';
    case JobState.queued:
      return 'Queued for printer...';
    case JobState.processing:
      return 'Printing...';
    case JobState.submitted:
      return 'Printed — check the paper output.';
    case JobState.failed:
      return 'Failed: ${error ?? 'unknown error'}. Fix the cause, then reprint.';
    case JobState.cancelled:
      return 'Cancelled.';
    case JobState.unknown:
      return 'Status unclear — check the paper tray before printing again.';
  }
}

/// Ledger row: one per `documentId` (the agent `idempotency_key`).
/// No print content is ever persisted — payload stays transient.
@immutable
class PrintJobRecord {
  const PrintJobRecord({
    required this.documentId,
    required this.printerId,
    required this.title,
    required this.format,
    required this.state,
    this.jobId,
    this.error = '',
    this.reference = '',
    this.createdAt,
    this.updatedAt,
  });

  final String documentId;
  final String? jobId;
  final String printerId;
  final String title;
  final String format;
  final JobState state;
  final String error;
  final String reference;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  PrintJobRecord copyWith({
    String? jobId,
    String? printerId,
    String? title,
    JobState? state,
    String? error,
    String? reference,
    DateTime? updatedAt,
  }) =>
      PrintJobRecord(
        documentId: documentId,
        jobId: jobId ?? this.jobId,
        printerId: printerId ?? this.printerId,
        title: title ?? this.title,
        format: format,
        state: state ?? this.state,
        error: error ?? this.error,
        reference: reference ?? this.reference,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}
