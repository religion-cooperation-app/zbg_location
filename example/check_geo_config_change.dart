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

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as fbg;
import 'package:path/path.dart' as path_helper;
import 'package:sqflite/sqflite.dart';

const _appliedKey = 'geo_config_last_applied_json';
const _pendingKey = 'geo_config_pending_json';

/// Checks whether the FBG-relevant fields of appConfig/runtime have changed
/// since the last successful geoStartFromConfig run.
///
/// If changed: writes the new stable-encoded config to SQLite as a pending
/// entry and returns 'changed'. The caller should then run geoStartFromConfig
/// and, on success, call confirmGeoConfigApplied to promote pending → applied.
///
/// If unchanged: returns 'unchanged'. No SQLite write, no geoStart needed.
///
/// Return values:
///   'changed'              — config differs, pending written, run geoStart
///   'unchanged'            — no relevant change since last applied
///   'deferred:is_moving'   — device is currently moving, skip geoStart to avoid disrupting active session
///   'skipped:web'          — web platform, no-op
///   'skipped:doc_missing'  — appConfig/runtime doc absent in Firestore
///   'error:<ExceptionType>'— unexpected failure
Future<String> checkGeoConfigChange() async {
  if (kIsWeb) return 'skipped:web';
  if (!Platform.isAndroid && !Platform.isIOS) return 'skipped:platform';

  try {
    // Guard: if the device is currently moving, do not trigger geoStart.
    // Reconfiguring FBG mid-walk risks tearing down the native session
    // (pre-flight stop in startFromFirestore when _uid == null after termination).
    // The pending hash is not written so this retries on the next homepage open.
    try {
      final state = await fbg.BackgroundGeolocation.state;
      if (state.isMoving == true) return 'deferred:is_moving';
    } catch (_) {
      // FBG not yet initialised — safe to proceed.
    }
    final snap =
        await FirebaseFirestore.instance.doc('appConfig/runtime').get();
    if (!snap.exists) return 'skipped:doc_missing';
    final data = snap.data()!;

    final currentJson = _stableEncodeRelevant(data);

    final db = await _openKvDb();
    final rows = await db.query(
      'kv_store',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_appliedKey],
      limit: 1,
    );
    final appliedJson =
        rows.isNotEmpty ? (rows.first['value'] as String?) : null;

    if (currentJson == appliedJson) {
      await db.close();
      return 'unchanged';
    }

    // Config changed — write pending so confirmGeoConfigApplied can promote it.
    await db.insert(
      'kv_store',
      {'key': _pendingKey, 'value': currentJson},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.close();
    return 'changed';
  } catch (e) {
    return 'error:${e.runtimeType}';
  }
}

/// Encodes only the fields that affect FBG behaviour into a deterministic
/// string suitable for equality comparison.
///
/// Excluded: meta, privacy, queue, regionGate, version,
///           geofenceDetect.geofences_updated_at (handled by geo_refresh_geofences),
///           platform.active_geo_schedule (not used by FBG engine).
String _stableEncodeRelevant(Map<String, dynamic> data) {
  final platform =
      Map<String, dynamic>.from((data['platform'] as Map?) ?? {});
  platform.remove('active_geo_schedule');

  final geofenceDetect =
      Map<String, dynamic>.from((data['geofenceDetect'] as Map?) ?? {});
  geofenceDetect.remove('geofences_updated_at');

  final relevant = <String, dynamic>{
    'breadcrumbs': data['breadcrumbs'],
    'geofenceDetect': geofenceDetect,
    'ingest_api_key': data['ingest_api_key'],
    'platform': platform,
  };
  return _stableEncode(relevant);
}

/// Recursively encodes a value with sorted map keys for a deterministic
/// string that is stable across isolate restarts (unlike hashCode).
String _stableEncode(dynamic value) {
  if (value is Map) {
    final entries = value.entries.toList()
      ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
    final parts =
        entries.map((e) => '"${e.key}":${_stableEncode(e.value)}').join(',');
    return '{$parts}';
  }
  if (value is List) {
    return '[${value.map(_stableEncode).join(',')}]';
  }
  // Firestore Timestamp — use epoch ms so it serialises deterministically.
  if (value is Timestamp) {
    return value.millisecondsSinceEpoch.toString();
  }
  try {
    return jsonEncode(value);
  } catch (_) {
    return '"${value.toString()}"';
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
