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

// Config change keys
const _configAppliedKey = 'geo_config_last_applied_json';
const _configPendingKey = 'geo_config_pending_json';

// Geofences staleness keys
const _geofencesAppliedKey = 'geo_geofences_applied_ts';
const _geofencesPendingKey = 'geo_geofences_pending_ts';

/// Checks whether the FBG-relevant config fields OR the geofence definitions
/// have changed since the last successful geoStartFromConfig run.
///
/// Reads appConfig/runtime once and performs two independent checks:
///   1. Config hash: stable-encodes relevant FBG fields and compares to the
///      last applied hash in SQLite.
///   2. Geofences timestamp: compares geofenceDetect.geofences_updated_at
///      against the last applied epoch-ms value in SQLite.
///
/// If either check detects a change, writes the appropriate pending value(s)
/// to SQLite and returns 'changed'. The caller should run geoStartFromConfig
/// (which re-fetches both config and geofences from Firestore) and then call
/// confirmGeoConfigApplied to promote all pending → applied.
///
/// Return values:
///   'changed'              — config or geofences differ from last applied, run geoStart
///   'unchanged'            — neither has changed since last geoStart
///   'deferred:is_moving'   — device is currently moving, skip to avoid disrupting session
///   'skipped:web'          — web platform, no-op
///   'skipped:doc_missing'  — appConfig/runtime absent in Firestore
///   'error:<ExceptionType>'— unexpected failure
Future<String> checkGeoConfigChange() async {
  if (kIsWeb) return 'skipped:web';
  if (!Platform.isAndroid && !Platform.isIOS) return 'skipped:platform';

  try {
    // Guard: if the device is currently moving, do not trigger geoStart.
    // Reconfiguring FBG mid-walk risks tearing down the native session.
    // The pending values are not written so this retries on the next homepage open.
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

    final db = await _openKvDb();
    var changed = false;

    // --- Check 1: FBG config fields ---
    final currentConfigJson = _stableEncodeRelevant(data);
    final configRows = await db.query(
      'kv_store',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_configAppliedKey],
      limit: 1,
    );
    final appliedConfigJson =
        configRows.isNotEmpty ? (configRows.first['value'] as String?) : null;

    if (currentConfigJson != appliedConfigJson) {
      await db.insert(
        'kv_store',
        {'key': _configPendingKey, 'value': currentConfigJson},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      changed = true;
    }

    // --- Check 2: geofences_updated_at timestamp ---
    final geofenceDetect =
        data['geofenceDetect'] as Map<String, dynamic>?;
    final updatedAtRaw = geofenceDetect?['geofences_updated_at'];
    if (updatedAtRaw != null) {
      final updatedAtMs = updatedAtRaw is Timestamp
          ? updatedAtRaw.millisecondsSinceEpoch
          : (updatedAtRaw as int);

      final geofenceRows = await db.query(
        'kv_store',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: [_geofencesAppliedKey],
        limit: 1,
      );
      final appliedMs = geofenceRows.isNotEmpty
          ? int.tryParse(geofenceRows.first['value'] as String? ?? '')
          : null;

      if (appliedMs == null || updatedAtMs > appliedMs) {
        await db.insert(
          'kv_store',
          {'key': _geofencesPendingKey, 'value': updatedAtMs.toString()},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        changed = true;
      }
    }

    await db.close();
    return changed ? 'changed' : 'unchanged';
  } catch (e) {
    return 'error:${e.runtimeType}';
  }
}

/// Encodes only the fields that affect FBG behaviour into a deterministic
/// string suitable for equality comparison.
///
/// Excluded: meta, privacy, queue, regionGate, version,
///           geofenceDetect.geofences_updated_at (handled by geofences check above),
///           platform.active_geo_schedule (not used by FBG engine).
String _stableEncodeRelevant(Map<String, dynamic> data) {
  final platform = Map<String, dynamic>.from((data['platform'] as Map?) ?? {});
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
