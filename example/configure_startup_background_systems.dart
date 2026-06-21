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

import 'package:background_fetch/background_fetch.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as path_helper;
import 'package:sqflite/sqflite.dart';

import '/custom_code/geo_diagnostics_http.dart';
import '/custom_code/lean_background_maintenance_scheduler.dart';

bool _startupBackgroundSystemsConfigured = false;

Future<String> configureStartupBackgroundSystems(
  String endpointUrl,
  String apiKey,
) async {
  final status = <String, dynamic>{
    'geoDiagnosticsHttp': 'skipped',
    'leanBackgroundFlush': 'skipped',
    'regionId': '',
  };

  try {
    final regionId = await _readStoredInviteGeolocationRegion();
    status['regionId'] = regionId;

    if (regionId.isNotEmpty) {
      await GeoDiagnosticsHttp.configure(
        regionId: regionId,
        endpointUrl: endpointUrl,
        apiKey: apiKey,
      );
      status['geoDiagnosticsHttp'] = 'success';
    } else {
      status['geoDiagnosticsHttp'] = 'skipped:no_region';
    }
  } catch (e) {
    status['geoDiagnosticsHttp'] = 'error:${e.runtimeType}';
  }

  if (kIsWeb) {
    status['leanBackgroundFlush'] = 'unsupported_web';
    return jsonEncode(status);
  }

  if (!Platform.isAndroid) {
    status['leanBackgroundFlush'] = 'unsupported_platform';
    return jsonEncode(status);
  }

  if (_startupBackgroundSystemsConfigured) {
    status['leanBackgroundFlush'] = 'success:already_configured';
    return jsonEncode(status);
  }

  try {
    await BackgroundFetch.configure(
      BackgroundFetchConfig(
        minimumFetchInterval: 15,
        stopOnTerminate: false,
        enableHeadless: true,
        startOnBoot: true,
        requiredNetworkType: NetworkType.ANY,
      ),
      (String taskId) async {
        try {
          await LeanBackgroundMaintenanceScheduler.run(
            source: 'background_fetch',
          );
        } finally {
          BackgroundFetch.finish(taskId);
        }
      },
      (String taskId) async {
        BackgroundFetch.finish(taskId);
      },
    );

    await BackgroundFetch.registerHeadlessTask(
      startupBackgroundSystemsHeadlessTask,
    );

    _startupBackgroundSystemsConfigured = true;
    status['leanBackgroundFlush'] = 'success';
  } catch (e) {
    status['leanBackgroundFlush'] = 'error:${e.runtimeType}';
  }

  return jsonEncode(status);
}

@pragma('vm:entry-point')
void startupBackgroundSystemsHeadlessTask(HeadlessTask task) async {
  final taskId = task.taskId;
  final timeout = task.timeout;

  if (timeout) {
    BackgroundFetch.finish(taskId);
    return;
  }

  try {
    await LeanBackgroundMaintenanceScheduler.run(
      source: 'background_fetch_headless',
    );
  } finally {
    BackgroundFetch.finish(taskId);
  }
}

Future<String> _readStoredInviteGeolocationRegion() async {
  if (kIsWeb) return _firstAppStateRegion();

  try {
    final dbPath = await getDatabasesPath();
    final fullPath = path_helper.join(dbPath, 'sparrc_offline.db');
    final db = await openDatabase(
      fullPath,
      version: 1,
      onOpen: (db) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS kv_store (
            key TEXT PRIMARY KEY, value TEXT NOT NULL
          )
        ''');
      },
    );

    final rows = await db.query(
      'kv_store',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['invite_geolocation_region'],
      limit: 1,
    );
    await db.close();

    if (rows.isNotEmpty) {
      final value = (rows.first['value'] as String? ?? '').trim();
      if (value.isNotEmpty) return value;
    }
  } catch (_) {}

  return _firstAppStateRegion();
}

String _firstAppStateRegion() {
  for (final item in FFAppState().inviteGeolocationRegion) {
    final trimmed = item.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return '';
}

// Set your action name, define your arguments and return parameter,
// and then add the boilerplate code using the green button on the right!
