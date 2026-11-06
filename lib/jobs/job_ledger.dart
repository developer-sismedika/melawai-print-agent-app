import 'package:sqflite/sqflite.dart';

import 'job.dart';

/// Ledger abstraction: one row per `documentId`. SQLite in the app,
/// in-memory in tests. Content is never stored.
abstract class JobLedger {
  Future<PrintJobRecord?> findByDocumentId(String documentId);
  Future<void> upsert(PrintJobRecord record);
  Future<List<PrintJobRecord>> recent({int limit = 20});
  Future<void> clear();
}

class InMemoryJobLedger implements JobLedger {
  final Map<String, PrintJobRecord> _rows = {};

  @override
  Future<PrintJobRecord?> findByDocumentId(String documentId) async =>
      _rows[documentId];

  @override
  Future<void> upsert(PrintJobRecord record) async =>
      _rows[record.documentId] = record;

  @override
  Future<List<PrintJobRecord>> recent({int limit = 20}) async {
    final rows = _rows.values.toList()
      ..sort((a, b) => (b.updatedAt ?? b.createdAt ?? DateTime(0))
          .compareTo(a.updatedAt ?? a.createdAt ?? DateTime(0)));
    return rows.take(limit).toList();
  }

  @override
  Future<void> clear() async => _rows.clear();
}

/// SQLite job ledger (phase 1 on-device persistence; restart recovery
/// hardening lands in phase 3).
class SqliteJobLedger implements JobLedger {
  SqliteJobLedger._(this._db);

  static const _table = 'print_jobs';

  final Database _db;

  static Future<JobLedger> open({String? dbPath}) async {
    final path = dbPath ??
        '${await getDatabasesPath()}/melawai_print_agent_jobs.db';
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_table (
            documentId TEXT PRIMARY KEY,
            jobId TEXT,
            printerId TEXT NOT NULL,
            title TEXT NOT NULL,
            format TEXT NOT NULL,
            state TEXT NOT NULL,
            error TEXT NOT NULL DEFAULT '',
            reference TEXT NOT NULL DEFAULT '',
            createdAt INTEGER,
            updatedAt INTEGER
          )
        ''');
      },
    );
    return SqliteJobLedger._(db);
  }

  PrintJobRecord _fromRow(Map<String, Object?> row) => PrintJobRecord(
        documentId: row['documentId']! as String,
        jobId: row['jobId'] as String?,
        printerId: row['printerId']! as String,
        title: row['title']! as String,
        format: row['format']! as String,
        state: parseJobState(row['state']! as String) ?? JobState.submitting,
        error: (row['error'] ?? '') as String,
        reference: (row['reference'] ?? '') as String,
        createdAt: row['createdAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['createdAt']! as int),
        updatedAt: row['updatedAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['updatedAt']! as int),
      );

  @override
  Future<PrintJobRecord?> findByDocumentId(String documentId) async {
    final rows = await _db.query(
      _table,
      where: 'documentId = ?',
      whereArgs: [documentId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  @override
  Future<void> upsert(PrintJobRecord record) async {
    await _db.insert(
      _table,
      {
        'documentId': record.documentId,
        'jobId': record.jobId,
        'printerId': record.printerId,
        'title': record.title,
        'format': record.format,
        'state': record.state.name,
        'error': record.error,
        'reference': record.reference,
        'createdAt': record.createdAt?.millisecondsSinceEpoch,
        'updatedAt': record.updatedAt?.millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<PrintJobRecord>> recent({int limit = 20}) async {
    final rows = await _db.query(
      _table,
      orderBy: 'updatedAt DESC',
      limit: limit,
    );
    return rows.map(_fromRow).toList();
  }

  @override
  Future<void> clear() async => _db.delete(_table);
}
