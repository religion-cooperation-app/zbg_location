import 'dart:convert';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as path_helper;
import 'package:sqflite/sqflite.dart';

class GeoDiagnosticsWriter {
  static const _dbName = 'sparrc_offline.db';
  static const _kvTable = 'kv_store';
  static const _identityKey = 'geo_diag_identity';
  static const _runtimeConfigKey = 'geo_runtime_config_raw';

  static Future<void> storeIdentity({
    required String uid,
    required String regionId,
  }) async {
    if (kIsWeb) return;
    if (uid.isEmpty || regionId.isEmpty) return;

    try {
      await _writeString(
        _identityKey,
        jsonEncode({
          'uid': uid,
          'region_id': regionId,
          'client_updated_at_iso': DateTime.now().toUtc().toIso8601String(),
        }),
      );
    } catch (e, st) {
      await _recordNonFatal(e, st, 'zbg_geo_diag_store_identity_failed');
    }
  }

  static Future<GeoDiagnosticsIdentity?> readIdentity() async {
    if (kIsWeb) return null;

    try {
      final raw = await _readString(_identityKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final uid = decoded['uid'] as String?;
      final regionId = decoded['region_id'] as String?;
      if (uid == null || uid.isEmpty) return null;
      return GeoDiagnosticsIdentity(uid: uid, regionId: regionId);
    } catch (e, st) {
      await _recordNonFatal(e, st, 'zbg_geo_diag_read_identity_failed');
      return null;
    }
  }

  static Future<void> storeRawRuntimeConfig(
      Map<String, dynamic> rawData) async {
    if (kIsWeb) return;
    try {
      await _writeString(_runtimeConfigKey, jsonEncode(rawData));
    } catch (e, st) {
      await _recordNonFatal(e, st, 'zbg_geo_diag_store_runtime_config_failed');
    }
  }

  static Future<Map<String, dynamic>?> readRawRuntimeConfig() async {
    if (kIsWeb) return null;
    try {
      final raw = await _readString(_runtimeConfigKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return decoded;
    } catch (e, st) {
      await _recordNonFatal(e, st, 'zbg_geo_diag_read_runtime_config_failed');
      return null;
    }
  }

  static Future<Database> _openDb() async {
    final dbPath = await getDatabasesPath();
    final fullPath = path_helper.join(dbPath, _dbName);
    return openDatabase(
      fullPath,
      version: 1,
      onOpen: (db) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS $_kvTable (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
      },
    );
  }

  static Future<String?> _readString(String key) async {
    final db = await _openDb();
    try {
      final rows = await db.query(
        _kvTable,
        columns: ['value'],
        where: 'key = ?',
        whereArgs: [key],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return rows.first['value'] as String?;
    } finally {
      await db.close();
    }
  }

  static Future<void> _writeString(String key, String value) async {
    final db = await _openDb();
    try {
      await db.insert(
        _kvTable,
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } finally {
      await db.close();
    }
  }

  static Future<void> _recordNonFatal(
    Object error,
    StackTrace stack,
    String reason,
  ) async {
    try {
      await FirebaseCrashlytics.instance.recordError(
        error,
        stack,
        fatal: false,
        reason: reason,
      );
    } catch (_) {
      // Diagnostics must not affect location tracking.
    }
  }

  static Future<void> _log(String message) async {
    try {
      FirebaseCrashlytics.instance.log(message);
    } catch (_) {
      // Diagnostics must not affect location tracking.
    }
  }
}

class GeoDiagnosticsIdentity {
  const GeoDiagnosticsIdentity({
    required this.uid,
    required this.regionId,
  });

  final String uid;
  final String? regionId;
}
