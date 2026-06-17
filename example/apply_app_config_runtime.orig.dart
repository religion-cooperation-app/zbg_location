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

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as path_helper;
import 'package:sqflite/sqflite.dart';

import '/custom_code/geo_bootstrap.dart';
import '/custom_code/geo_diagnostics_http.dart';

// SQLite key that stores the last successful refresh timestamp.
const _cooldownKey = 'app_config_runtime_last_refresh_ms';
const _cooldownDuration = Duration(hours: 1);

/// Reads appConfig/runtime from Firestore and pushes fresh values to two
/// subsystems:
///
///  1. GeoBootstrap FBG engine (heartbeat rates, stop timeout, distance
///     filters, geofence-only mode, etc.) — replaces the unreliable
///     _configSub listener as a forced-refresh path on every homepage open.
///
///  2. GeoDiagnosticsHttp intervals (fetch/heartbeat/daily-snapshot cadence)
///     — patches the SQLite config so headless background tasks pick them up
///     without a network call.
///
/// A 1-hour SQLite cooldown prevents repeated Firestore reads on rapid
/// homepage visits. Returns a result string for logging:
///   'applied:geo=ok:diag=ok'       — both subsystems updated
///   'skipped:cooldown'             — within the 1-hour window
///   'skipped:doc_missing'          — appConfig/runtime doc absent
///   'skipped:web'                  — web platform, no-op
///   'error:<ExceptionType>'        — unexpected failure
Future<String> applyAppConfigRuntime() async {
  if (kIsWeb) return 'skipped:web';

  try {
    final db = await _openKvDb();

    // --- cooldown check ---
    final rows = await db.query(
      'kv_store',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_cooldownKey],
      limit: 1,
    );
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (rows.isNotEmpty) {
      final lastMs = int.tryParse(rows.first['value'] as String? ?? '') ?? 0;
      if (nowMs - lastMs < _cooldownDuration.inMilliseconds) {
        await db.close();
        return 'skipped:cooldown';
      }
    }

    // --- fetch appConfig/runtime (single read, shared below) ---
    final snap =
        await FirebaseFirestore.instance.doc('appConfig/runtime').get();
    if (!snap.exists) {
      await db.close();
      return 'skipped:doc_missing';
    }
    final data = snap.data()!;

    // --- 1) apply to FBG engine via GeoBootstrap ---
    final geoResult = await _applyGeoEngine(data);

    // --- 2) patch diagnostic intervals in SQLite ---
    final diagResult = await _applyDiagIntervals(data);

    // --- stamp cooldown ---
    await db.insert(
      'kv_store',
      {'key': _cooldownKey, 'value': nowMs.toString()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.close();

    return 'applied:geo=$geoResult:diag=$diagResult';
  } catch (e) {
    return 'error:${e.runtimeType}';
  }
}

// PRE-CHANGE-I original — gated on isRunning, calls refreshConfigFromMap.
// Replaced by refreshConfigFromMapForced in batch 3+6 commit.
Future<String> _applyGeoEngine(Map<String, dynamic> data) async {
  if (!GeoBootstrap.instance.isRunning) return 'not_running';
  try {
    await GeoBootstrap.instance.refreshConfigFromMap(data);
    return 'ok';
  } catch (e) {
    return 'error:${e.runtimeType}';
  }
}

Future<String> _applyDiagIntervals(Map<String, dynamic> data) async {
  final diag = data['diagnostics'];
  if (diag is! Map) return 'skipped:fields_absent';
  final fetchMin = diag['fetch_interval_minutes'];
  final hbHours = diag['heartbeat_interval_hours'];
  final snapHours = diag['daily_snapshot_hours'];
  if (fetchMin == null || hbHours == null || snapHours == null) {
    return 'skipped:fields_absent';
  }
  try {
    await GeoDiagnosticsHttp.updateIntervals(
      fetchIntervalMinutes: (fetchMin as num).toInt(),
      heartbeatIntervalHours: (hbHours as num).toInt(),
      dailySnapshotHours: (snapHours as num).toInt(),
    );
    return 'ok';
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

// Set your action name, define your arguments and return parameter,
// and then add the boilerplate code using the green button on the right!
