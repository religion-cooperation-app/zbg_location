// Automatic FlutterFlow imports
import '/backend/backend.dart';
import '/backend/schema/structs/index.dart';
import '/backend/schema/enums/enums.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'index.dart'; // Imports other custom actions
import '/flutter_flow/custom_functions.dart'; // Imports custom functions
import 'package:flutter/material.dart';
// Begin custom action code
// DO NOT REMOVE OR MODIFY THE CODE ABOVE!

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as path_helper;
import 'package:sqflite/sqflite.dart';

const _appliedKey = 'geo_config_last_applied_json';
const _pendingKey = 'geo_config_pending_json';

/// Promotes the pending config snapshot to the applied slot in SQLite.
///
/// Call this only after geoStartFromConfig returns a success result.
/// Pending → applied promotion means checkGeoConfigChange will return
/// 'unchanged' on the next homepage open until the Firestore doc changes again.
///
/// If there is no pending entry (called out of order), this is a safe no-op.
///
/// Return values:
///   'confirmed'           — pending promoted to applied, pending cleared
///   'skipped:no_pending'  — no pending entry found, nothing to promote
///   'skipped:web'         — web platform, no-op
///   'error:<ExceptionType>'— unexpected failure
Future<String> confirmGeoConfigApplied() async {
  if (kIsWeb) return 'skipped:web';
  if (!Platform.isAndroid && !Platform.isIOS) return 'skipped:platform';

  try {
    final db = await _openKvDb();

    final rows = await db.query(
      'kv_store',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_pendingKey],
      limit: 1,
    );

    if (rows.isEmpty) {
      await db.close();
      return 'skipped:no_pending';
    }

    final pendingJson = rows.first['value'] as String;

    await db.insert(
      'kv_store',
      {'key': _appliedKey, 'value': pendingJson},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.delete('kv_store', where: 'key = ?', whereArgs: [_pendingKey]);

    await db.close();
    return 'confirmed';
  } catch (e) {
    return 'error:${e.runtimeType}';
  }
}

Future<Database> _openKvDb() async {
  final dbPath = await getDatabasesPath();
  return openDatabase(
    path_helper.join(dbPath, 'sparrc_offline.db'),
    version: 1,
    onOpen: (db) async {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS kv_store (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      ''');
    },
  );
}
