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

// Config change keys
const _configAppliedKey = 'geo_config_last_applied_json';
const _configPendingKey = 'geo_config_pending_json';

// Geofences staleness keys
const _geofencesAppliedKey = 'geo_geofences_applied_ts';
const _geofencesPendingKey = 'geo_geofences_pending_ts';

/// Promotes any pending config and/or geofences values to their applied slots
/// in SQLite.
///
/// Call this only after geoStartFromConfig returns a success result. A
/// successful geoStart applies both a new FBG config and fresh geofences from
/// Firestore, so both pending values (if present) are promoted together.
///
/// Each pending slot is promoted independently — if only one was written by
/// checkGeoConfigChange (because only one changed), only that one is promoted.
/// This is a safe no-op if neither pending slot exists.
///
/// Return values:
///   'confirmed:config+geofences' — both pending slots promoted
///   'confirmed:config'           — only config pending was present and promoted
///   'confirmed:geofences'        — only geofences pending was present and promoted
///   'skipped:no_pending'         — neither pending slot found, nothing to promote
///   'skipped:web'                — web platform, no-op
///   'error:<ExceptionType>'      — unexpected failure
Future<String> confirmGeoConfigApplied() async {
  if (kIsWeb) return 'skipped:web';
  if (!Platform.isAndroid && !Platform.isIOS) return 'skipped:platform';

  try {
    final db = await _openKvDb();
    final confirmed = <String>[];

    // Promote config pending → applied
    final configRows = await db.query(
      'kv_store',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_configPendingKey],
      limit: 1,
    );
    if (configRows.isNotEmpty) {
      await db.insert(
        'kv_store',
        {'key': _configAppliedKey, 'value': configRows.first['value']},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await db.delete('kv_store',
          where: 'key = ?', whereArgs: [_configPendingKey]);
      confirmed.add('config');
    }

    // Promote geofences pending → applied
    final geofenceRows = await db.query(
      'kv_store',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_geofencesPendingKey],
      limit: 1,
    );
    if (geofenceRows.isNotEmpty) {
      await db.insert(
        'kv_store',
        {'key': _geofencesAppliedKey, 'value': geofenceRows.first['value']},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await db.delete('kv_store',
          where: 'key = ?', whereArgs: [_geofencesPendingKey]);
      confirmed.add('geofences');
    }

    await db.close();

    if (confirmed.isEmpty) return 'skipped:no_pending';
    return 'confirmed:${confirmed.join('+')}';
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
